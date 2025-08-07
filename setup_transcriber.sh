#!/bin/bash
set -euo pipefail

# === CONFIGURATION ===
PYTHON_VERSION="3.10.14"
OPENSSL_VERSION="1.1.1l" # Correctly defined here
INSTALL_PREFIX="/opt"
OPENSSL_PREFIX="$INSTALL_PREFIX/openssl-$OPENSSL_VERSION"
PYTHON_PREFIX="$INSTALL_PREFIX/python-$PYTHON_VERSION"
SRC_DIR="/usr/local/src"
WHISPER_ENV="/opt/whisper_env"
LOG_FILE="/var/log/setupdiagnostic.log" # New log file

# === LOGGING SETUP ===
# Redirect all stdout and stderr to the log file
exec > >(tee -a "$LOG_FILE") 2>&1
echo "--- Starting Whisper Installation and Service Setup ---"
echo "Log file: $LOG_FILE"
echo "Started at: $(date)"

# Function to check if Python is functional (can import ssl)
check_python_functional() {
    if [ -x "$PYTHON_PREFIX/bin/python3.10" ]; then
        # Test if the Python binary can import ssl and certifi
        if "$PYTHON_PREFIX/bin/python3.10" -c 'import ssl; import certifi; print("Python functional.");' &>/dev/null; then
            return 0 # Functional
        fi
    fi
    return 1 # Not functional or not found
}


# === PREREQUISITES AND DEPENDENCY INSTALLATION ===
echo "Checking for Python $PYTHON_VERSION installation..."
if check_python_functional; then
    echo "Python $PYTHON_VERSION already installed and functional at $PYTHON_PREFIX. Skipping build."
else
    echo "Python $PYTHON_VERSION not found or not functional. Proceeding with installation."

    # Install development tools and libraries required for building Python and OpenSSL
    echo "Installing system dependencies..."
    yum groupinstall -y "Development Tools" || { echo "Error: Failed to install Development Tools. Check $LOG_FILE for details."; exit 1; }
    yum install -y gcc zlib-devel wget make openssl-devel libffi-devel bzip2-devel xz-devel || { echo "Error: Failed to install system dependencies. Check $LOG_FILE for details."; exit 1; }
fi

mkdir -p "$SRC_DIR"
cd "$SRC_DIR" || { echo "Error: Failed to change to source directory $SRC_DIR. Check $LOG_FILE for details."; exit 1; }


# === Check and Install inotify-tools ===
echo "Checking for inotify-tools..."
if ! rpm -q inotify-tools &>/dev/null; then
    echo "inotify-tools not found. Installing..."
    yum install -y inotify-tools || { echo "Error: Failed to install inotify-tools. Check $LOG_FILE for details."; exit 1; }
    echo "inotify-tools installed successfully."
else
    echo "inotify-tools already installed. Skipping installation."
fi

# === OPENSSL INSTALLATION (Custom Build) ===
echo "Checking for OpenSSL $OPENSSL_VERSION installation..."
if [ ! -d "$OPENSSL_PREFIX" ]; then
    echo "OpenSSL $OPENSSL_VERSION not found. Downloading and building."
    # Clean up source directory for OpenSSL before extracting
    rm -rf "openssl-$OPENSSL_VERSION"
    wget -q "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz" || { echo "Error: Failed to download OpenSSL source. Check $LOG_FILE for details."; exit 1; }
    tar -xf "openssl-$OPENSSL_VERSION.tar.gz" || { echo "Error: Failed to extract OpenSSL source. Check $LOG_FILE for details."; exit 1; }
    # FIX: Corrected variable name from OPENSL_VERSION to OPENSSL_VERSION
    cd "openssl-$OPENSSL_VERSION" || { echo "Error: Failed to change to OpenSSL source directory. Check $LOG_FILE for details."; exit 1; }

    ./config --prefix="$OPENSSL_PREFIX" --openssldir="$OPENSSL_PREFIX" shared zlib || { echo "Error: OpenSSL config failed. Check $LOG_FILE for details."; exit 1; }
    make -j"$(nproc)" || { echo "Error: OpenSSL make failed. Check $LOG_FILE for details."; exit 1; }
    make install || { echo "Error: OpenSSL make install failed. Check $LOG_FILE for details."; exit 1; }
    cd ..
    echo "OpenSSL $OPENSSL_VERSION installed to $OPENSSL_PREFIX."
else
    echo "OpenSSL $OPENSSL_VERSION already found at $OPENSSL_PREFIX."
fi

# === SET ENVIRONMENT FOR BUILDING PYTHON ===
# These exports are crucial for Python to find and link against the custom OpenSSL build
export LD_LIBRARY_PATH="$OPENSSL_PREFIX/lib"
export CPPFLAGS="-I$OPENSSL_PREFIX/include"
export LDFLAGS="-L$OPENSSL_PREFIX/lib"
echo "Environment variables set for Python build (LD_LIBRARY_PATH, CPPFLAGS, LDFLAGS)."

# === PYTHON INSTALLATION (Custom Build) ===
echo "Checking for Python $PYTHON_VERSION installation at $PYTHON_PREFIX..."
if check_python_functional; then
    echo "Python $PYTHON_VERSION already installed and functional at $PYTHON_PREFIX. Skipping build."
else
    echo "Python $PYTHON_VERSION not found or not functional. Building Python."
    echo "Checking for Python $PYTHON_VERSION source archive..."
    if [ ! -f "Python-$PYTHON_VERSION.tgz" ]; then
        echo "Python $PYTHON_VERSION source not found. Downloading."
        wget -q "https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tgz" || { echo "Error: Failed to download Python source. Check $LOG_FILE for details."; exit 1; }
    fi

    echo "Building Python $PYTHON_VERSION..."
    # Clean up source directory for Python before extracting
    rm -rf "Python-$PYTHON_VERSION"
    tar -xf "Python-$PYTHON_VERSION.tgz" || { echo "Error: Failed to extract Python source. Check $LOG_FILE for details."; exit 1; }
    cd "Python-$PYTHON_VERSION" || { echo "Error: Failed to change to Python source directory. Check $LOG_FILE for details."; exit 1; }

    # Configure Python to use the custom OpenSSL build and enable shared libraries.
    # LD_RUN_PATH embeds runtime library paths directly into the executables.
    # LDFLAGS and CPPFLAGS are passed directly to configure to ensure they are used.
    LDFLAGS="-Wl,-rpath=${OPENSSL_PREFIX}/lib -Wl,-rpath=${PYTHON_PREFIX}/lib ${LDFLAGS}" \
    CPPFLAGS="${CPPFLAGS}" \
    ./configure --prefix="$PYTHON_PREFIX" \
                --with-openssl="$OPENSSL_PREFIX" \
                --enable-shared \
                --enable-loadable-sqlite-extensions \
                LD_RUN_PATH="${OPENSSL_PREFIX}/lib:${PYTHON_PREFIX}/lib" || { echo "Error: Python configure failed. Check $LOG_FILE for details."; exit 1; }
    make clean

    # Explicitly set LD_LIBRARY_PATH and PYTHONPATH for the 'make' command itself.
    # This ensures the newly built python executable can find its shared libraries and
    # standard library modules during internal tests (like sysconfig).
    echo "Running make with explicit LD_LIBRARY_PATH and PYTHONPATH..."
    LD_LIBRARY_PATH="$PWD:${OPENSSL_PREFIX}/lib:${LD_LIBRARY_PATH}" \
    PYTHONPATH="$SRC_DIR/Python-$PYTHON_VERSION/Lib" \
    make -j"$(nproc)" || { echo "Error: Python make failed. Check $LOG_FILE for details."; exit 1; }

    echo "Running make altinstall..."
    make altinstall || { echo "Error: Python make altinstall failed. Check $LOG_FILE for details."; exit 1; }
    echo "Python $PYTHON_VERSION installed to $PYTHON_PREFIX."
    cd .. # Return to $SRC_DIR
fi

# === CREATE PYTHON VIRTUAL ENVIRONMENT FOR WHISPER ===
echo "Checking for Whisper virtual environment..."
if [ ! -d "$WHISPER_ENV" ]; then
    echo "Creating Whisper virtual environment at $WHISPER_ENV."
    "$PYTHON_PREFIX/bin/python3.10" -m venv "$WHISPER_ENV" || { echo "Error: Failed to create virtual environment. Check $LOG_FILE for details."; exit 1; }
else
    echo "Whisper virtual environment already exists at $WHISPER_ENV."
fi

# === INSTALL WHISPER AND DEPENDENCIES ===
echo "Activating virtual environment and installing Whisper and its dependencies..."
source "$WHISPER_ENV/bin/activate" || { echo "Error: Failed to activate virtual environment. Check $LOG_FILE for details."; exit 1; }

# Upgrade pip and related tools
pip install --upgrade pip setuptools wheel || { echo "Error: Failed to upgrade pip tools. Check $LOG_FILE for details."; exit 1; }

# Install certifi explicitly to ensure it's available for SSL_CERT_FILE
echo "Installing/ensuring certifi is present in virtual environment..."
pip install certifi || { echo "Error: Failed to install certifi. Check $LOG_FILE for details."; exit 1; }

# Install Whisper from GitHub
echo "Installing OpenAI Whisper..."
pip install git+https://github.com/openai/whisper.git || { echo "Error: Failed to install Whisper. Check $LOG_FILE for details."; exit 1; }

deactivate # Deactivate the virtual environment
echo "Whisper and its dependencies installed successfully."

# === SERVICE SETUP ===
echo "--- Setting up Systemd Service for Transcriber ---"

# Enable debugging for this section to trace variable issues
set -x

# Define service-specific variables here, closer to their usage
SERVICE_NAME="transcriber"
INSTALL_DIR="/var/transcripts" # Directory for output transcripts and watcher script
SCRIPT_PATH="$INSTALL_DIR/transcribe_watcher.sh" # Watcher script path
PYTHON_BIN="$WHISPER_ENV/bin/python3" # Python executable within the virtual environment
WHISPER_BIN="$WHISPER_ENV/bin/whisper" # Whisper executable within the virtual environment
MONITOR_DIR="/var/spool/asterisk/monitor" # Directory to monitor for WAV files

# Ensure transcript directory exists
mkdir -p "$INSTALL_DIR" || { echo "Error: Failed to create install directory $INSTALL_DIR. Check $LOG_FILE for details."; exit 1; }

# Verify Python executable path for the service
if ! [ -x "$PYTHON_BIN" ]; then
    echo "Error: Python executable not found or not executable at $PYTHON_BIN. Check $LOG_FILE for details."
    exit 1
fi

# Verify Whisper executable path for the service
if ! [ -x "$WHISPER_BIN" ]; then
    echo "Error: Whisper executable not found or not executable at $WHISPER_BIN. Check $LOG_FILE for details."
    exit 1
fi

# --- START: Generate transcribe_watcher.sh directly ---
echo "Generating transcribe_watcher.sh script..."
cat > "$SCRIPT_PATH" <<'EOF'
#!/bin/bash
# This script monitors the Asterisk monitor directory for new WAV files,
# transcribes them using Whisper, and saves all output formats.

# --- Configuration ---
MONITOR_DIR="/var/spool/asterisk/monitor"
TRANSCRIPT_DIR="/var/transcripts"
WHISPER_BIN="/opt/whisper_env/bin/whisper" # Absolute path to Whisper executable
LOG_FILE="/var/log/transcriber_watcher.log" # Dedicated log for the watcher script
MIN_FILE_SIZE_KB=5 # Minimum file size in KB to process (e.g., 5KB to avoid empty recordings)

# Ensure log file exists and is writable
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Watcher script started at $(date)"

# Ensure output directory exists
mkdir -p "$TRANSCRIPT_DIR"

# --- Main Logic ---
echo "Monitoring $MONITOR_DIR for new WAV files..."

# Use inotifywait to monitor for new WAV files (close_write event)
# Process files as they are written
inotifywait -m -r "$MONITOR_DIR" -e close_write --format '%w%f' | grep --line-buffered '\.wav$' | while read -r WAV_FILE; do
    echo "[$(date)] Detected new WAV file: $WAV_FILE"

    # Get file size in KB
    FILE_SIZE_KB=$(du -k "$WAV_FILE" | awk '{print $1}')

    if (( FILE_SIZE_KB < MIN_FILE_SIZE_KB )); then
        echo "[$(date)] Skipping small file (less than ${MIN_FILE_SIZE_KB}KB): $WAV_FILE"
        continue
    fi

    # Extract filename without extension for output
    FILENAME=$(basename "$WAV_FILE" .wav)

    # Define output base path
    OUTPUT_BASE_PATH="$TRANSCRIPT_DIR/$FILENAME"

    echo "[$(date)] Transcribing: $WAV_FILE"

    # Run Whisper. Use --output_format all to get srt, txt, json, tsv, vtt
    # Redirect Whisper's output to a temporary file to prevent cluttering stdout/log directly
    # and to capture any specific Whisper errors.
    TEMP_WHISPER_LOG="/tmp/whisper_output_${FILENAME}.log"
    if "$WHISPER_BIN" "$WAV_FILE" \
        --model base \
        --language en \
        --output_dir "$TRANSCRIPT_DIR" \
        --output_format all \
        --verbose False > "$TEMP_WHISPER_LOG" 2>&1; then
        echo "[$(date)] Transcription successful for $WAV_FILE. Outputs in $TRANSCRIPT_DIR."
        # Verify if expected files exist
        if [ -f "${OUTPUT_BASE_PATH}.srt" ] && [ -f "${OUTPUT_BASE_PATH}.txt" ]; then
            echo "[$(date)] SRT and TXT files confirmed for $FILENAME."
            # Optionally, move the processed WAV file to an archive or delete it
            # For now, we will leave the original WAV file as requested by "keep all the files"
            # If you want to move it: mv "$WAV_FILE" "$TRANSCRIPT_DIR/processed_wavs/"
            # If you want to delete it: rm "$WAV_FILE"
        else
            echo "[$(date)] WARNING: Expected transcript files (.srt, .txt) not found for $FILENAME. Check $TEMP_WHISPER_LOG for Whisper output."
        fi
    else
        echo "[$(date)] ERROR: Transcription failed for $WAV_FILE. Check $TEMP_WHISPER_LOG for Whisper output."
    fi
    # Clean up the temporary whisper log
    rm -f "$TEMP_WHISPER_LOG"

done
EOF
echo "transcribe_watcher.sh generated and made executable at $SCRIPT_PATH."
chmod +x "$SCRIPT_PATH" || { echo "Error: Failed to make watcher script executable after generation. Check $LOG_FILE for details."; exit 1; }
# --- END: Generate transcribe_watcher.sh directly ---

# Determine the certifi CA bundle path within the virtual environment
# This path will be used to set SSL_CERT_FILE for the systemd service
echo "Determining certifi CA bundle path for SSL_CERT_FILE..."
# Use the Python executable from the virtual environment to find certifi
CERTIFI_CA_BUNDLE_PATH="$("$WHISPER_ENV/bin/python3" -c 'import certifi; print(certifi.where())')"
if [ -z "$CERTIFI_CA_BUNDLE_PATH" ]; then
    echo "Error: Could not determine certifi CA bundle path. SSL_CERT_FILE might not be set correctly. Check $LOG_FILE for details."
    # Optionally, you could exit here or try a fallback if absolutely necessary
else
    echo "Certifi CA bundle path: $CERTIFI_CA_BUNDLE_PATH"
fi

# Create the systemd service unit file
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
echo "Creating systemd service file: $SERVICE_FILE"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Real-time Call Transcriber (Whisper)
After=network.target

[Service]
Type=simple
# Corrected ExecStart to use bash to run the watcher script
ExecStart=/bin/bash $SCRIPT_PATH
WorkingDirectory=$INSTALL_DIR
Restart=always
# Ensure the virtual environment's bin directory is in PATH
Environment=PATH=$WHISPER_ENV/bin:/usr/bin:/bin
# Set SSL_CERT_FILE to the certifi bundle for secure connections
Environment=SSL_CERT_FILE=$CERTIFI_CA_BUNDLE_PATH
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF
echo "Systemd service file created."

# Reload systemd daemon, enable, and start the service
echo "Reloading systemd daemon, enabling and starting service..."
systemctl daemon-reload || { echo "Error: systemctl daemon-reload failed. Check $LOG_FILE for details."; exit 1; }
systemctl stop "$SERVICE_NAME" || { echo "Warning: Failed to stop existing service, proceeding with start. Check $LOG_FILE for details."; } # Stop before starting for clean restart
systemctl reset-failed "$SERVICE_NAME" || { echo "Warning: Failed to reset failed state for service. Check $LOG_FILE for details."; } # Clear start-limit
sleep 1 # Give systemd a moment
systemctl start "$SERVICE_NAME" || { echo "Error: systemctl start failed. Check $LOG_FILE for details."; exit 1; }

echo "Service installed and started: $SERVICE_NAME"
systemctl status "$SERVICE_NAME" --no-pager || { echo "Error: Failed to get service status. Check $LOG_FILE for details."; exit 1; }

# Disable debugging
set +x

echo "--- Whisper Installation and Service Setup Complete ---"
echo "Finished at: $(date)"
