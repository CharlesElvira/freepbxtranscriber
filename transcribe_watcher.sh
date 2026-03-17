#!/bin/bash
# Monitors FreePBX voicemail directory for new messages,
# transcribes them using OpenAI Whisper, and emails the transcription
# with the original WAV file attached.
#
# DEPLOY PATH (if not using setup_transcriber.sh):
#   sudo cp transcribe_watcher.sh /var/transcripts/transcribe_watcher.sh
#   sudo sed -i 's/\r//' /var/transcripts/transcribe_watcher.sh
#   sudo sed -i 's/FALLBACK_EMAIL_PLACEHOLDER/your@email.com/' /var/transcripts/transcribe_watcher.sh
#   sudo chmod +x /var/transcripts/transcribe_watcher.sh
#   sudo systemctl restart transcriber

# --- Configuration ---
VOICEMAIL_DIR="/var/spool/asterisk/voicemail/default"
VOICEMAIL_CONF="/etc/asterisk/voicemail.conf"
TRANSCRIPT_DIR="/var/transcripts"
WHISPER_BIN="/opt/whisper_env/bin/whisper"
PHP_MAILER="/usr/local/bin/send_voicemail_email.php"
LOG_FILE="/var/log/transcriber_watcher.log"
MIN_FILE_SIZE_KB=5

# Fallback email if the extension has no email in voicemail.conf
FALLBACK_EMAIL="FALLBACK_EMAIL_PLACEHOLDER"

# --- Logging setup ---
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[$(date)] Voicemail transcriber watcher started."

mkdir -p "$TRANSCRIPT_DIR"

# --- Sanity checks ---
if [ ! -x "$WHISPER_BIN" ]; then
    echo "[$(date)] ERROR: Whisper not found at $WHISPER_BIN. Exiting."
    exit 1
fi

if [ ! -f "$PHP_MAILER" ]; then
    echo "[$(date)] ERROR: PHP mailer not found at $PHP_MAILER. Exiting."
    exit 1
fi

echo "[$(date)] Monitoring $VOICEMAIL_DIR for new voicemail WAV files..."

inotifywait -m -r "$VOICEMAIL_DIR" -e close_write -e moved_to --format '%w%f' \
  | grep --line-buffered '/msg[0-9]\+\.wav$' \
  | grep --line-buffered -v '/tmp/' \
  | while read -r WAV_FILE; do

    echo "[$(date)] New WAV file detected: $WAV_FILE"

    # Wait for the file size to stabilize (Asterisk may still be writing)
    PREV_SIZE=-1
    STABLE_CHECKS=0
    for i in $(seq 1 20); do
        FILE_SIZE_KB=$(du -k "$WAV_FILE" 2>/dev/null | awk '{print $1}')
        FILE_SIZE_KB=${FILE_SIZE_KB:-0}
        if (( FILE_SIZE_KB == PREV_SIZE )); then
            (( STABLE_CHECKS++ ))
            (( STABLE_CHECKS >= 3 )) && break
        else
            STABLE_CHECKS=0
        fi
        PREV_SIZE=$FILE_SIZE_KB
        sleep 1
    done

    # Skip very small files (silence, corrupt recordings)
    if (( FILE_SIZE_KB < MIN_FILE_SIZE_KB )); then
        echo "[$(date)] Skipping small file (${FILE_SIZE_KB}KB < ${MIN_FILE_SIZE_KB}KB): $WAV_FILE"
        continue
    fi

    FILENAME=$(basename "$WAV_FILE" .wav)
    TXT_FILE="${WAV_FILE%.wav}.txt"

    # --- Parse voicemail metadata ---
    CALLER_ID="Unknown"
    ORIG_DATE="Unknown"
    DURATION="0"
    MAILBOX="Unknown"

    if [ -f "$TXT_FILE" ]; then
        CALLER_ID=$(grep '^callerid='   "$TXT_FILE" | cut -d'=' -f2-)
        ORIG_DATE=$(grep '^origdate='   "$TXT_FILE" | cut -d'=' -f2-)
        DURATION=$( grep '^duration='   "$TXT_FILE" | cut -d'=' -f2-)
        MAILBOX=$(  grep '^origmailbox=' "$TXT_FILE" | cut -d'=' -f2-)
    else
        echo "[$(date)] WARNING: No companion .txt found at $TXT_FILE"
    fi

    # Extract extension from path:  .../default/207/Old/msg0001.wav -> 207
    EXTENSION=$(echo "$WAV_FILE" | sed "s|${VOICEMAIL_DIR}/||" | cut -d'/' -f1)

    # --- Look up recipient email from voicemail.conf ---
    # Format:  207 => password,Full Name,email@example.com,...
    TO_EMAIL=$(grep -m1 "^${EXTENSION}=" "$VOICEMAIL_CONF" 2>/dev/null \
               | cut -d',' -f3 \
               | tr -d '[:space:]')

    if [ -z "$TO_EMAIL" ]; then
        echo "[$(date)] No email for ext $EXTENSION in voicemail.conf. Using fallback: $FALLBACK_EMAIL"
        TO_EMAIL="$FALLBACK_EMAIL"
    fi

    echo "[$(date)] Transcribing for ext $EXTENSION (to: $TO_EMAIL) caller: $CALLER_ID"

    # --- Run Whisper transcription ---
    TEMP_WHISPER_LOG="/tmp/whisper_${FILENAME}.log"
    TRANSCRIPT_TXT="$TRANSCRIPT_DIR/${FILENAME}.txt"

    if "$WHISPER_BIN" "$WAV_FILE" \
        --model base \
        --language en \
        --output_dir "$TRANSCRIPT_DIR" \
        --output_format txt \
        --verbose False > "$TEMP_WHISPER_LOG" 2>&1; then

        if [ -f "$TRANSCRIPT_TXT" ]; then
            echo "[$(date)] Transcription succeeded: $TRANSCRIPT_TXT"
        else
            echo "[$(date)] WARNING: Whisper ran but transcript not found at $TRANSCRIPT_TXT"
            echo "Transcription file not produced by Whisper." > "$TRANSCRIPT_TXT"
        fi
    else
        echo "[$(date)] ERROR: Whisper failed for $WAV_FILE. See $TEMP_WHISPER_LOG"
        echo "Transcription failed. Please check server logs." > "$TRANSCRIPT_TXT"
    fi

    cat "$TEMP_WHISPER_LOG" >> "$LOG_FILE" 2>/dev/null
    rm -f "$TEMP_WHISPER_LOG"

    # --- Send email via PHP mailer ---
    php "$PHP_MAILER" \
        --to="$TO_EMAIL" \
        --extension="$EXTENSION" \
        --callerid="$CALLER_ID" \
        --date="$ORIG_DATE" \
        --duration="$DURATION" \
        --wav="$WAV_FILE" \
        --transcript-file="$TRANSCRIPT_TXT" \
    && echo "[$(date)] Email sent to $TO_EMAIL for ext $EXTENSION" \
    || echo "[$(date)] ERROR: PHP mailer failed for $WAV_FILE"

done
