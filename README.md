# FreePBX Call Transcriber

This project installs and runs a background service that transcribes recorded calls from a FreePBX system using OpenAI’s Whisper model. Transcriptions are emailed (if SMTP is configured) or saved locally per extension.

## Features

- Automatically monitors FreePBX call recordings
- Transcribes calls using Whisper in an isolated Python virtual environment
- Sends transcriptions via email or stores them in `/var/transcripts/output`
- Works with CentOS and systems where Whisper fails to install by default
- Self-healing service using `systemd`

## Installation

Clone this repository and run the installer:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/technetnew/freepbxtranscriber/main/setup_transcriber.sh)
