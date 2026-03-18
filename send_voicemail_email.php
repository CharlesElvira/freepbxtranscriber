#!/usr/bin/php
<?php
/**
 * send_voicemail_email.php
 * Sends a voicemail transcription email with the WAV file attached.
 * Inspired by https://github.com/simontelephonics/transcribe-with-azure
 *
 * DEPLOY PATH (if not using setup_transcriber.sh):
 *   sudo cp send_voicemail_email.php /usr/local/bin/send_voicemail_email.php
 *   sudo sed -i 's/\r//' /usr/local/bin/send_voicemail_email.php
 *   sudo chmod +x /usr/local/bin/send_voicemail_email.php
 *   sudo systemctl restart transcriber
 *
 * Usage:
 *   php send_voicemail_email.php \
 *     --to=user@example.com \
 *     --extension=207 \
 *     --callerid="John Doe <5551234567>" \
 *     --date="Wed Sep 17 05:05:05 PM UTC 2025" \
 *     --duration=65 \
 *     --wav=/var/spool/asterisk/voicemail/default/207/Old/msg0001.wav \
 *     --transcript-file=/var/transcripts/msg0001.txt
 */

$opts = getopt('', [
    'to:',
    'extension:',
    'callerid:',
    'date:',
    'duration:',
    'wav:',
    'transcript-file:',
]);

$to              = $opts['to']              ?? 'root@localhost';
$extension       = $opts['extension']       ?? 'Unknown';
$callerid        = $opts['callerid']        ?? 'Unknown';
$orig_date       = $opts['date']            ?? date('r');
$duration_secs   = (int)($opts['duration'] ?? 0);
$wav_file        = $opts['wav']             ?? '';
$transcript_file = $opts['transcript-file'] ?? '';

// Read transcription text
$transcript = 'Transcription unavailable.';
if ($transcript_file && is_readable($transcript_file)) {
    $text = trim(file_get_contents($transcript_file));
    if ($text !== '') {
        $transcript = $text;
    }
}

// Format duration as mm:ss
$duration_fmt = sprintf('%d:%02d', intdiv($duration_secs, 60), $duration_secs % 60);

$hostname = gethostname();
$from     = "FreePBX Voicemail <asterisk@{$hostname}>";
$subject  = "New Voicemail for Ext {$extension} from {$callerid}";

$boundary = 'VMBOUND_' . md5(uniqid('', true));

// Build plain-text body part
$text_body  = "New Voicemail Notification\n";
$text_body .= "==========================\n\n";
$text_body .= "Extension : {$extension}\n";
$text_body .= "Caller ID : {$callerid}\n";
$text_body .= "Date      : {$orig_date}\n";
$text_body .= "Duration  : {$duration_fmt} ({$duration_secs}s)\n\n";
$text_body .= "Transcription\n";
$text_body .= "-------------\n";
$text_body .= $transcript . "\n\n";
$text_body .= "(Transcribed locally using OpenAI Whisper)\n";

// Assemble MIME message
$mime  = "--{$boundary}\r\n";
$mime .= "Content-Type: text/plain; charset=UTF-8\r\n";
$mime .= "Content-Transfer-Encoding: 7bit\r\n\r\n";
$mime .= $text_body . "\r\n";

// Attach WAV file if it exists
if ($wav_file && is_readable($wav_file)) {
    $wav_name    = basename($wav_file);
    $wav_encoded = chunk_split(base64_encode(file_get_contents($wav_file)));
    $mime .= "--{$boundary}\r\n";
    $mime .= "Content-Type: audio/wav; name=\"{$wav_name}\"\r\n";
    $mime .= "Content-Transfer-Encoding: base64\r\n";
    $mime .= "Content-Disposition: attachment; filename=\"{$wav_name}\"\r\n\r\n";
    $mime .= $wav_encoded . "\r\n";
} else {
    fwrite(STDERR, "WARNING: WAV file not found or not readable: {$wav_file}\n");
}

$mime .= "--{$boundary}--\r\n";

// Send via Postfix sendmail (same path FreePBX uses internally)
$headers  = "From: {$from}\r\n";
$headers .= "To: {$to}\r\n";
$headers .= "MIME-Version: 1.0\r\n";
$headers .= "Content-Type: multipart/mixed; boundary=\"{$boundary}\"\r\n";

$full_message = $headers . "\r\n" . $mime;

$sendmail_cmd = '/usr/sbin/sendmail -t -i 2>&1';
$sendmail = popen($sendmail_cmd, 'w');
if ($sendmail === false) {
    fwrite(STDERR, "ERROR: Could not open sendmail pipe.\n");
    exit(1);
}
fwrite($sendmail, $full_message);
$ret = pclose($sendmail);

if ($ret !== 0) {
    fwrite(STDERR, "ERROR: sendmail exited with code {$ret}. Check: journalctl -u postfix or /var/log/maillog\n");
    exit(1);
}

echo "Email sent to {$to} for extension {$extension}\n";
