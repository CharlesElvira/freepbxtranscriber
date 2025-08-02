#!/bin/bash
set -euo pipefail

# === CONFIGURATION ===
PYTHON_VERSION=3.10.14
OPENSSL_VERSION=1.1.1l
INSTALL_PREFIX="/opt"
OPENSSL_PREFIX="$INSTALL_PREFIX/openssl-$OPENSSL_VERSION"
PYTHON_PREFIX="$INSTALL_PREFIX/python-$PYTHON_VERSION"
SRC_DIR="/usr/local/src"
WHISPER_ENV="/opt/whisper_env"

# === PRE-CHECK: Skip if Python already works ===
if [ -x "$PYTHON_PREFIX/bin/python3.10" ]; then
    if "$PYTHON_PREFIX/bin/python3.10" -c 'import runpy; import ssl; print("Python functional.")'; then
        echo "Python $PYTHON_VERSION already working — skipping build."
    else
        echo "Python exists but broken — continuing rebuild."
    fi
else
    echo "Python $PYTHON_VERSION not found — installing dependencies."
    # === PREREQUISITES ===
    yum groupinstall -y "Development Tools"
    yum install -y gcc zlib-devel wget make openssl-devel libffi-devel bzip2-devel xz-devel

    mkdir -p "$SRC_DIR"
    cd "$SRC_DIR"

    # === OPENSSL INSTALLATION ===
    if [ ! -d "$OPENSSL_PREFIX" ]; then
        wget -q https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz
        tar -xf openssl-$OPENSSL_VERSION.tar.gz
        cd openssl-$OPENSSL_VERSION
        ./config --prefix="$OPENSSL_PREFIX" --openssldir="$OPENSSL_PREFIX" shared zlib
        make -j"$(nproc)"
        make install
        cd ..
    fi

    # === SET ENVIRONMENT FOR BUILDING PYTHON ===
    export LD_LIBRARY_PATH="$OPENSSL_PREFIX/lib"
    export CPPFLAGS="-I$OPENSSL_PREFIX/include"
    export LDFLAGS="-L$OPENSSL_PREFIX/lib"

    # === PYTHON INSTALLATION ===
    if [ ! -f "Python-$PYTHON_VERSION.tgz" ]; then
        wget -q https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tgz
    fi

    tar -xf Python-$PYTHON_VERSION.tgz
    cd Python-$PYTHON_VERSION
    ./configure --prefix="$PYTHON_PREFIX" --with-openssl="$OPENSSL_PREFIX" --enable-optimizations
    make clean
    make -j"$(nproc)"
    make altinstall
fi

# === CREATE PYTHON VIRTUAL ENVIRONMENT FOR WHISPER ===
if [ ! -d "$WHISPER_ENV" ]; then
    echo "Creating Whisper virtual environment..."
    "$PYTHON_PREFIX/bin/python3.10" -m venv "$WHISPER_ENV"
fi

# === INSTALL WHISPER ===
echo "Activating virtual environment and installing Whisper..."
source "$WHISPER_ENV/bin/activate"
pip install --upgrade pip setuptools wheel
pip install git+https://github.com/openai/whisper.git
echo "Whisper installed successfully at $WHISPER_ENV"
# === SERVICE SETUP ===
SERVICE_NAME="transcriber"
WATCHER_SCRIPT_URL="https://github.com/technetnew/freepbxtranscriber/blob/main/transcribe_watcher.sh"
INSTALL_DIR="/var/transcripts"
SCRIPT_PATH="$INSTALL_DIR/transcribe_watcher.sh"
PYTHON_BIN="/opt/whisper_env/bin/python3"
WHISPER_BIN="/opt/whisper_env/bin/whisper"

# Ensure transcript directory exists
mkdir -p "$INSTALL_DIR"

# Verify Python is working before proceeding
if ! "$PYTHON_BIN" --version >/dev/null 2>&1; then
    echo "Python not found at $PYTHON_BIN"
    exit 1
fi

# Verify Whisper is working before proceeding
if ! "$WHISPER_BIN" --help >/dev/null 2>&1; then
    echo "Whisper not found at $WHISPER_BIN"
    exit 1
fi

# Download the watcher script
echo "Downloading watcher script..."
curl -fsSL "$WATCHER_SCRIPT_URL" -o "$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"

# Create the systemd service unit
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

echo "Creating systemd service file..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Whisper Transcriber Watcher
After=network.target

[Service]
Type=simple
ExecStart=$PYTHON_BIN $SCRIPT_PATH
WorkingDirectory=$INSTALL_DIR
Restart=always
Environment=PATH=/opt/whisper_env/bin:/usr/bin:/bin
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable and start the service
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

echo "Service installed and started: $SERVICE_NAME"
systemctl status "$SERVICE_NAME" --no-pager
