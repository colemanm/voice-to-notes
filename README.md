# Voice to Notes

Transcribes voice memos using Google Gemini and creates Obsidian notes with automatic linking to daily notes.

## Requirements

- `zsh`
- `ffmpeg`
- `jq`
- Google Gemini API key
- Obsidian vault at `~/Documents/Mem3x`

## Setup

1. Set your Gemini API key in `.env`:
   ```
   GEMINI_API_KEY=your-api-key-here
   ```

2. Make the script executable:
   ```bash
   chmod +x voicenote.sh
   ```

3. Configure paths in `voicenote.sh` if needed (Obsidian vault location, audio archive directory, etc.)

## Usage

Run the script with audio file(s) as arguments:

```bash
./voicenote.sh /path/to/voice-memo.m4a
```

The script will:
- Convert audio to MP3
- Upload to Gemini for transcription
- Generate a title, summary, and tags
- Create an Obsidian note in `Voice Notes/`
- Link to the daily note in `Journal/`
- Optionally commit to git if the vault is a git repo

Supported formats: `.m4a`, `.mp3`, `.wav`, `.aac`
