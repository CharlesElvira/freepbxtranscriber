# FreePBX Voicemail Transcriber

Automatically transcribes FreePBX voicemail messages using [OpenAI Whisper](https://github.com/openai/whisper) (local, no cloud API required) and emails the transcription with the original WAV file attached.

## How It Works

1. A `systemd` service runs `transcribe_watcher.sh` in the background
2. `inotifywait` watches `/var/spool/asterisk/voicemail/default/` recursively for new `.wav` files
3. When a new voicemail arrives, the companion `.txt` file is parsed for caller ID, date, duration, and extension
4. Whisper transcribes the audio locally
5. `send_voicemail_email.php` sends an email to the extension's address (from `voicemail.conf`) with the transcription in the body and the WAV file attached

> **No FreePBX mail config changes needed.** This service operates independently of FreePBX's built-in voicemail email system.

---

## Requirements

- CentOS / RHEL (tested on FreePBX distro)
- Internet access during setup (to download Python, Whisper, and Rust)
- A working mail relay (Postfix/sendmail) on the server — FreePBX typically has this configured already
- PHP CLI (`php-cli`) — installed automatically by the setup script

---

## Installation

### 1. Clone the repository

```bash
cd /opt
git clone https://github.com/technetnew/freepbxtranscriber.git
cd freepbxtranscriber
```

### 2. Set your fallback email

Open `setup_transcriber.sh` and set the `FALLBACK_EMAIL` variable near the top of the Service Setup section. This address receives transcriptions for any extension that does not have an email configured in `/etc/asterisk/voicemail.conf`:

```bash
FALLBACK_EMAIL="admin@yourdomain.com"
```

> Per-extension emails are read automatically from `/etc/asterisk/voicemail.conf`.
> Format: `207 => password,Full Name,email@example.com`

### 3. Run the setup script

```bash
bash setup_transcriber.sh
```

The script will:
- Build a custom Python 3.10 with OpenSSL (if not already present)
- Install Rust (required to compile `tiktoken`, a Whisper dependency)
- Create a Python virtual environment at `/opt/whisper_env`
- Install OpenAI Whisper and dependencies
- Install `inotify-tools` and `php-cli` if missing
- Deploy `transcribe_watcher.sh` → `/var/transcripts/`
- Deploy `send_voicemail_email.php` → `/usr/local/bin/`
- Create and start the `transcriber` systemd service

---

## Checking the Service

```bash
# Service status
systemctl status transcriber

# Live logs
tail -f /var/log/transcriber_watcher.log

# Restart after config changes
systemctl restart transcriber
```

---

## Email Behaviour

- Each extension receives email at the address in `/etc/asterisk/voicemail.conf`
- If no address is found for an extension, the `FALLBACK_EMAIL` is used
- FreePBX's own voicemail notification email is **not** affected — you may receive two emails per voicemail (FreePBX's plain notification + our transcription email). To avoid duplicates, disable FreePBX's voicemail email per extension in **Admin → User Management → Voicemail** or clear the email field in **Voicemail Admin**

---

## File Locations After Install

| File | Location |
|------|----------|
| Watcher script | `/var/transcripts/transcribe_watcher.sh` |
| PHP mailer | `/usr/local/bin/send_voicemail_email.php` |
| Transcripts output | `/var/transcripts/` |
| Watcher log | `/var/log/transcriber_watcher.log` |
| Setup log | `/var/log/setupdiagnostic.log` |
| Whisper virtual env | `/opt/whisper_env/` |
| Systemd service | `/etc/systemd/system/transcriber.service` |

---

## Updating Scripts Without Re-running Setup

If you only updated `transcribe_watcher.sh` or `send_voicemail_email.php` and want to redeploy without recompiling Python or Whisper, use the `--deploy-only` flag:

```bash
bash setup_transcriber.sh --deploy-only
```

This copies both scripts to their install locations, fixes line endings, sets the fallback email, and restarts the service — skipping all compilation steps.

---

## Manual Deploy (Without Re-running Setup)

If you update a script in the repo and want to deploy it without re-running the full setup:

### Update `transcribe_watcher.sh`

```bash
sudo cp /opt/freepbxtranscriber/transcribe_watcher.sh /var/transcripts/transcribe_watcher.sh
sudo sed -i 's/\r//' /var/transcripts/transcribe_watcher.sh
sudo sed -i 's/FALLBACK_EMAIL_PLACEHOLDER/your@email.com/' /var/transcripts/transcribe_watcher.sh
sudo chmod +x /var/transcripts/transcribe_watcher.sh
sudo systemctl restart transcriber
```

### Update `send_voicemail_email.php`

```bash
sudo cp /opt/freepbxtranscriber/send_voicemail_email.php /usr/local/bin/send_voicemail_email.php
sudo sed -i 's/\r//' /usr/local/bin/send_voicemail_email.php
sudo chmod +x /usr/local/bin/send_voicemail_email.php
sudo systemctl restart transcriber
```

> Replace `your@email.com` with your actual fallback email address.

---

## Troubleshooting

**`$'\r': command not found`**
The scripts have Windows line endings. The setup script strips these automatically with `sed`. To fix manually on a deployed server:
```bash
sed -i 's/\r//' /var/transcripts/transcribe_watcher.sh
sed -i 's/\r//' /usr/local/bin/send_voicemail_email.php
systemctl restart transcriber
```

**Whisper install fails with `tiktoken` build error**
Rust is required to compile `tiktoken`. The setup script installs Rust automatically. To install manually:
```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
source /opt/whisper_env/bin/activate
pip install git+https://github.com/openai/whisper.git
```

**No email received**
- Confirm the extension has an email in `/etc/asterisk/voicemail.conf`
- Check the watcher log: `tail -f /var/log/transcriber_watcher.log`
- Test sendmail is working: `echo "test" | sendmail -v your@email.com`

**Service not starting**
```bash
journalctl -u transcriber -n 50
systemctl status transcriber
```
