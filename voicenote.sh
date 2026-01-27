#!/bin/zsh
# Voice Memo to Obsidian Pipeline
# Transcribes audio using Gemini Flash, creates Obsidian notes, links to daily note

set -e
set -u
set -o pipefail

# --- PATH ---
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"

# --- API Keys ---
# When pasting this script into Automator, hardcode your API key below:
# export GEMINI_API_KEY="your-api-key-here"
export GEMINI_API_KEY="${GEMINI_API_KEY}"

# --- Logging ---
LOG_ROOT="$HOME/Library/Logs/voicenote-pipeline"
mkdir -p "$LOG_ROOT"
LOG_FILE="$LOG_ROOT/$(date +%F).log"
exec >>"$LOG_FILE" 2>&1

log() {
  osascript -e 'display notification "'"$1"'" with title "Voice Note Pipeline"' 2>/dev/null || true
  print -r -- "$1"
}

# ---------- CONFIG ----------
FFMPEG_BIN="${FFMPEG_BIN:-$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)}"

# Source: iCloud Voice Memos sync folder (for reference)
# VOICE_MEMOS_SOURCE="$HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"

# Obsidian vault paths
OBSIDIAN_VAULT="$HOME/Documents/Mem3x"
VOICE_MEMOS_DIR="$OBSIDIAN_VAULT/Voice Memos"
DAILY_NOTES_DIR="$OBSIDIAN_VAULT/Journal"

# Audio archive (final renamed MP3s)
AUDIO_DIR="$HOME/Documents/Voice Notes"

# Gemini model
GEMINI_MODEL="gemini-3-flash-preview"

MP3_OPTS=(-vn -acodec libmp3lame -q:a 2)

# ---------- PREP ----------
mkdir -p "$VOICE_MEMOS_DIR" "$AUDIO_DIR"
[[ -x "$FFMPEG_BIN" ]] || { echo "ffmpeg not found"; exit 1; }

log "[START] $(date '+%Y-%m-%dT%H:%M:%S') args: $*"

# ----- helpers -----
wait_stable() {
  local f="$1" prev=-1 same=0
  while true; do
    local sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
    if [[ "$sz" -eq "$prev" ]]; then
      same=$((same+1)); [[ "$same" -ge 2 ]] && break
    else
      same=0; prev="$sz"
    fi
    sleep 1
  done
}

sanitize_slug() {
  print -r -- "$1" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g; s/^(.{1,60}).*$/\1/'
}

unique_file() {
  local path="$1" dir base ext n cand
  dir="${path:h}"
  base="${path:t}"
  if [[ "$base" == *.* ]]; then
    ext="${base##*.}"
    base="${base%.*}"
    cand="$path"; n=2
    while [[ -e "$cand" ]]; do
      cand="${dir}/${base}-${n}.${ext}"
      ((n++))
    done
    print -r -- "$cand"
  else
    cand="$path"; n=2
    while [[ -e "$cand" ]]; do cand="${dir}/${base}-${n}"; ((n++)); done
    print -r -- "$cand"
  fi
}

# Upload file to Gemini and get file URI
gemini_upload_file() {
  local audio_path="$1"
  local mime_type num_bytes upload_url file_uri

  mime_type=$(file -b --mime-type "$audio_path")
  num_bytes=$(wc -c < "$audio_path" | tr -d ' ')

  local header_file=$(mktemp)

  curl -s "https://generativelanguage.googleapis.com/upload/v1beta/files" \
    -H "x-goog-api-key: $GEMINI_API_KEY" \
    -D "$header_file" \
    -H "X-Goog-Upload-Protocol: resumable" \
    -H "X-Goog-Upload-Command: start" \
    -H "X-Goog-Upload-Header-Content-Length: ${num_bytes}" \
    -H "X-Goog-Upload-Header-Content-Type: ${mime_type}" \
    -H "Content-Type: application/json" \
    -d "{\"file\": {\"display_name\": \"voice-memo-$(date +%s)\"}}" >/dev/null

  upload_url=$(grep -i "x-goog-upload-url: " "$header_file" | cut -d" " -f2 | tr -d "\r")
  rm -f "$header_file"

  [[ -z "$upload_url" ]] && return 1

  local file_info=$(mktemp)
  curl -s "$upload_url" \
    -H "Content-Length: ${num_bytes}" \
    -H "X-Goog-Upload-Offset: 0" \
    -H "X-Goog-Upload-Command: upload, finalize" \
    --data-binary "@${audio_path}" > "$file_info"

  file_uri=$(jq -r '.file.uri // empty' "$file_info" 2>/dev/null)
  rm -f "$file_info"
  print -r -- "$file_uri"
}

# Transcribe audio using Gemini
gemini_transcribe() {
  local file_uri="$1" mime_type="$2"
  local response=$(mktemp)

  curl -s "https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent" \
    -H "x-goog-api-key: $GEMINI_API_KEY" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{
      \"contents\": [{
        \"parts\": [
          {\"text\": \"Transcribe this audio accurately. Output only the transcription.\"},
          {\"file_data\": {\"mime_type\": \"${mime_type}\", \"file_uri\": \"${file_uri}\"}}
        ]
      }]
    }" > "$response"

  jq -r '.candidates[0].content.parts[0].text // empty' "$response" 2>/dev/null
  rm -f "$response"
}

# Generate title, summary, and tags
gemini_analyze() {
  local transcript="$1"
  local excerpt="${transcript:0:8000}"
  local response=$(mktemp)

  curl -s "https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent" \
    -H "x-goog-api-key: $GEMINI_API_KEY" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$(jq -n --arg excerpt "$excerpt" '{
      "contents": [{
        "parts": [{
          "text": ("You are summarizing personal voice memos. Write summaries in first person.\n\nProvide:\n1. TITLE (max 70 chars)\n2. SLUG (lowercase, hyphens, max 50 chars)\n3. SUMMARY (2-3 sentences, first person)\n4. CONTEXT: work, personal, health, learning, or family\n5. PRIORITY: high, medium, or low\n6. TOPICS: 1-3 specific tags\n\nFormat:\nTITLE: <title>\nSLUG: <slug>\nSUMMARY: <summary>\nCONTEXT: <tags>\nPRIORITY: <level>\nTOPICS: <tags>\n\nTranscript:\n" + $excerpt)
        }]
      }]
    }')" > "$response"

  jq -r '.candidates[0].content.parts[0].text // empty' "$response" 2>/dev/null
  rm -f "$response"
}

# Ensure daily note exists
ensure_daily_note() {
  local today=$(date +%Y-%m-%d)
  local daily_note="$DAILY_NOTES_DIR/${today}.md"

  if [[ ! -f "$daily_note" ]]; then
    cd "$OBSIDIAN_VAULT"
    command -v claude >/dev/null && echo "/daily" | claude --print 2>/dev/null || true

    [[ ! -f "$daily_note" ]] && cat > "$daily_note" << EOF
---
date: ${today}
tags: daily-note
---
# $(date '+%A, %B %d, %Y')
EOF
  fi
  print -r -- "$daily_note"
}

# Append to daily note
append_to_daily_note() {
  local title="$1" slug="$2" summary="$3"
  local daily_note=$(ensure_daily_note)

  {
    echo ""; echo "---"; echo ""
    echo "### Voice Memo: $(date '+%H:%M')"
    echo "[[Voice Memos/${slug}|${title}]]"
    echo "> ${summary}"
  } >> "$daily_note"
}

# ----- main loop -----
for input in "$@"; do
  [[ -d "$input" ]] && continue
  case "${input:l}" in
    *.m4a|*.mp3|*.wav|*.aac) ;;
    *) continue ;;
  esac

  wait_stable "$input"

  base="${input:t}"; stem="${base%.*}"; ext="${base##*.}"
  timestamp="$(date +"%Y-%m-%dT%H:%M:%S%z")"
  today="$(date +%Y-%m-%d)"
  time_slug="$(date +%Y%m%d-%H%M%S)"

  log "Processing: $base"

  # Convert to MP3 with datestamp name
  mp3_file="$AUDIO_DIR/voice-memo-${time_slug}.mp3"
  [[ "${input:l}" == *.mp3 ]] && cp "$input" "$mp3_file" || \
    "$FFMPEG_BIN" -y -i "$input" "${MP3_OPTS[@]}" "$mp3_file"

  # Upload and transcribe
  mime_type=$(file -b --mime-type "$mp3_file")
  file_uri=$(gemini_upload_file "$mp3_file")
  [[ -z "$file_uri" ]] && { log "Upload failed"; continue; }

  transcript=$(gemini_transcribe "$file_uri" "$mime_type")
  [[ -z "$transcript" ]] && { log "Transcription failed"; continue; }

  # Analyze
  ai_out=$(gemini_analyze "$transcript")
  title=$(echo "$ai_out" | sed -n 's/^TITLE:[[:space:]]*//Ip' | head -1)
  slug=$(sanitize_slug "$(echo "$ai_out" | sed -n 's/^SLUG:[[:space:]]*//Ip' | head -1)")
  summary=$(echo "$ai_out" | sed -n 's/^SUMMARY:[[:space:]]*//Ip' | head -1)

  [[ -z "$title" ]] && title="Voice memo $(date '+%Y-%m-%d %H:%M')"
  [[ -z "$slug" ]] && slug="voice-memo-${time_slug}"

  # Create note
  md_file=$(unique_file "$VOICE_MEMOS_DIR/${slug}.md")
  {
    echo "---"
    echo "title: \"$title\""
    echo "date: ${timestamp}"
    echo "tags: [voice-memo]"
    echo "audio: \"${mp3_file:t}\""
    echo "---"
    echo ""; echo "# $title"
    echo ""; echo "**Recorded:** ${today} at $(date '+%H:%M')"
    echo ""; echo "## Summary"; echo ""; echo "$summary"
    echo ""; echo "## Transcript"; echo ""; echo "$transcript"
  } > "$md_file"

  append_to_daily_note "$title" "${md_file:t:r}" "$summary"

  # Git commit (if vault is a git repo)
  cd "$OBSIDIAN_VAULT"
  if [[ -d ".git" ]]; then
    git add "Voice Memos/${md_file:t}" "${DAILY_NOTES_DIR#$OBSIDIAN_VAULT/}/${today}.md" 2>/dev/null || true
    git commit -m "Voice memo: ${title}" 2>/dev/null || true
    git push origin main 2>/dev/null || true
  fi

  log "Done: ${md_file:t}"
done

echo "[DONE] $(date '+%Y-%m-%dT%H:%M:%S')"