#!/bin/bash

WATCH_DIR="/var/spool/asterisk/monitor"
DEST_DIR="/var/transcripts"
WHISPER="/usr/local/bin/whisper"
MODEL="base"
EMAIL_TO_ARCHIVE="archive@technetne.com"
LOG_FILE="/var/transcripts/email_debug.log"

get_email_for_extension() {
    local ext="$1"
    mysql -N -u root asterisk -e "SELECT email FROM userman_users WHERE usernam$
}

send_email() {
    local extension="$1"
    local transcript="$2"
    local basefile
    basefile=$(basename "$transcript")

    local user_email
    user_email=$(get_email_for_extension "$extension")

    if [[ -z "$user_email" ]]; then
        user_email="$EMAIL_TO_ARCHIVE"
    fi

    echo "[$(date)]   Sending email to: $user_email,$EMAIL_TO_ARCHIVE for $base$

    mailx -s "Transcript – Ext $extension – $basefile" \
        -r "transcripts@technetne.com" \
        -S smtp=localhost \
        "$user_email,$EMAIL_TO_ARCHIVE" < "$transcript"
}

inotifywait -m -r "$WATCH_DIR" -e close_write --format '%w%f' |
grep --line-buffered '\.wav$' |
while read -r wavfile; do
    # Skip small/empty files
    [[ "$(stat -c%s "$wavfile")" -lt 10240 ]] && {
        echo "[$(date)] Skipping small file: $wavfile" >> "$LOG_FILE"
        continue
    }

    doneflag="${wavfile}.done"
    basefile=$(basename "${wavfile%.wav}")
    txtfile="$DEST_DIR/$basefile.txt"

    [[ -f "$doneflag" ]] && {
        echo "[$(date)] Already processed: $wavfile" >> "$LOG_FILE"
        continue
    }

    echo "[$(date)]   Transcribing: $wavfile" >> "$LOG_FILE"
    "$WHISPER" "$wavfile" --language en --model "$MODEL"

    if [[ -f "$txtfile" ]]; then
        extension=$(basename "$wavfile" | cut -d'-' -f3)
        send_email "$extension" "$txtfile"
        touch "$doneflag"
        echo "[$(date)]   Finished and emailed: $txtfile" >> "$LOG_FILE"
    else
else
        echo "[$(date)]   Transcript not found: $txtfile" >> "$LOG_FILE"
    fi
done