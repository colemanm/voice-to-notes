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

## macOS Automator Setup

Create a Quick Action to process voice memos directly from Finder:

1. Open **Automator** and create a new **Quick Action**
2. Set workflow to receive **files or folders** in **Finder**
3. Add a **Run Shell Script** action with these settings:
   - Shell: `/bin/zsh`
   - Pass input: **as arguments**
   - Replace the script content with:
     ```bash
     export GEMINI_API_KEY="your-api-key-here"
     /path/to/voice-to-notes/voicenote.sh "$@"
     ```
   - Replace `your-api-key-here` with your actual API key
   - Replace `/path/to/voice-to-notes/` with the actual path to this directory
4. Save as "Process Voice Memo" (or any name you prefer)
5. Right-click any audio file in Finder → **Quick Actions** → **Process Voice Memo**

**Note:** For Automator, you may want to hardcode the API key directly in the script (as noted in `voicenote.sh`) instead of relying on `.env` file loading.

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
