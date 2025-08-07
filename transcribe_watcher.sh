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
