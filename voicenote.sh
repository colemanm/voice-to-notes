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
VOICE_MEMOS_DIR="$OBSIDIAN_VAULT/Voice Notes"
DAILY_NOTES_DIR="$OBSIDIAN_VAULT/Journal"

# Audio archive (final renamed MP3s)
AUDIO_DIR="$HOME/Documents/Voice Notes"

# Gemini model
GEMINI_MODEL="gemini-2.5-flash"

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

FAILED_QUEUE="$LOG_ROOT/failed-queue.txt"

retry() {
  local attempt delays=(5 15 30)
  for attempt in 1 2 3; do
    "$@" && return 0 || true
    if [[ "$attempt" -lt 3 ]]; then
      log "Attempt $attempt failed, retrying in ${delays[$attempt]}s..."
      sleep "${delays[$attempt]}"
    fi
  done
  return 1
}

# Upload file to Gemini and get file URI
gemini_upload_file() {
  local audio_path="$1"
  local mime_type num_bytes upload_url file_uri file_name

  mime_type=$(file -b --mime-type "$audio_path")
  num_bytes=$(wc -c < "$audio_path" | tr -d ' ')

  local header_file=$(mktemp)

  curl -s --connect-timeout 10 --max-time 120 "https://generativelanguage.googleapis.com/upload/v1beta/files" \
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

  if [[ -z "$upload_url" ]]; then
    log "Upload failed: no upload URL received"
    return 1
  fi

  local file_info=$(mktemp)
  curl -s --connect-timeout 10 --max-time 120 "$upload_url" \
    -H "Content-Length: ${num_bytes}" \
    -H "X-Goog-Upload-Offset: 0" \
    -H "X-Goog-Upload-Command: upload, finalize" \
    --data-binary "@${audio_path}" > "$file_info"

  file_uri=$(jq -r '.file.uri // empty' "$file_info" 2>/dev/null)
  file_name=$(jq -r '.file.name // empty' "$file_info" 2>/dev/null)
  if [[ -z "$file_uri" ]]; then
    log "Upload response: $(cat "$file_info")"
    rm -f "$file_info"
    return 1
  fi
  rm -f "$file_info"

  # Wait for file to become ACTIVE (processing can take a few seconds)
  if [[ -n "$file_name" ]]; then
    local state="PROCESSING" attempts=0
    while [[ "$state" == "PROCESSING" && "$attempts" -lt 12 ]]; do
      sleep 5
      state=$(curl -s --connect-timeout 10 --max-time 120 "https://generativelanguage.googleapis.com/v1beta/${file_name}" \
        -H "x-goog-api-key: $GEMINI_API_KEY" | jq -r '.state // "ACTIVE"')
      attempts=$((attempts + 1))
    done
    if [[ "$state" != "ACTIVE" ]]; then
      log "File not ready after polling, state: $state"
      return 1
    fi
  fi

  print -r -- "$file_uri"
}

# Transcribe audio using Gemini
gemini_transcribe() {
  local file_uri="$1" mime_type="$2"
  local response=$(mktemp)

  curl -s --connect-timeout 10 --max-time 120 "https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent" \
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

  local text
  text=$(jq -r '.candidates[0].content.parts[0].text // empty' "$response" 2>/dev/null)
  if [[ -z "$text" ]]; then
    log "Transcription API response: $(cat "$response")"
    rm -f "$response"
    return 1
  fi
  rm -f "$response"
  print -r -- "$text"
}

# Generate title, summary, and tags
gemini_analyze() {
  local transcript="$1"
  local excerpt="${transcript:0:8000}"
  local response=$(mktemp)

  curl -s --connect-timeout 10 --max-time 120 "https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent" \
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

  local text
  text=$(jq -r '.candidates[0].content.parts[0].text // empty' "$response" 2>/dev/null)
  if [[ -z "$text" ]]; then
    log "Analyze API response: $(cat "$response")"
    rm -f "$response"
    return 1
  fi
  rm -f "$response"
  print -r -- "$text"
}

# Ensure daily note exists
ensure_daily_note() {
  local today=$(date +%Y-%m-%d)
  local daily_note="$DAILY_NOTES_DIR/${today}.md"

  if [[ ! -f "$daily_note" ]]; then
    cd "$OBSIDIAN_VAULT"
    command -v claude >/dev/null && echo "/daily" | claude --print >/dev/null 2>&1 || true

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
    echo "[[Voice Notes/${slug}|${title}]]"
    echo "> ${summary}"
  } >> "$daily_note"
}

# ----- helper: process a single MP3 file -----
process_mp3() {
  local mp3_file="$1"
  local timestamp="$(date +"%Y-%m-%dT%H:%M:%S%z")"
  local today="$(date +%Y-%m-%d)"
  local time_slug="$(date +%Y%m%d-%H%M%S)"

  # Upload and transcribe
  local mime_type file_uri transcript ai_out title slug summary
  local _retry_out
  mime_type=$(file -b --mime-type "$mp3_file")

  _retry_out=$(mktemp)
  retry gemini_upload_file "$mp3_file" > "$_retry_out" || true
  file_uri=$(cat "$_retry_out"); rm -f "$_retry_out"
  if [[ -z "$file_uri" ]]; then
    log "Upload failed after 3 attempts: ${mp3_file:t}"
    return 1
  fi

  _retry_out=$(mktemp)
  retry gemini_transcribe "$file_uri" "$mime_type" > "$_retry_out" || true
  transcript=$(cat "$_retry_out"); rm -f "$_retry_out"
  if [[ -z "$transcript" ]]; then
    log "Transcription failed after 3 attempts: ${mp3_file:t}"
    return 1
  fi

  _retry_out=$(mktemp)
  retry gemini_analyze "$transcript" > "$_retry_out" || true
  ai_out=$(cat "$_retry_out"); rm -f "$_retry_out"
  title=$(echo "$ai_out" | sed -n 's/^TITLE:[[:space:]]*//Ip' | head -1)
  slug=$(sanitize_slug "$(echo "$ai_out" | sed -n 's/^SLUG:[[:space:]]*//Ip' | head -1)")
  summary=$(echo "$ai_out" | sed -n 's/^SUMMARY:[[:space:]]*//Ip' | head -1)

  [[ -z "$title" ]] && title="Voice memo $(date '+%Y-%m-%d %H:%M')"
  [[ -z "$slug" ]] && slug="voice-memo-${time_slug}"

  # Create note
  local md_file
  md_file=$(unique_file "$VOICE_MEMOS_DIR/${today} ${slug}.md")
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
    git add "Voice Notes/${md_file:t}" "${DAILY_NOTES_DIR#$OBSIDIAN_VAULT/}/${today}.md" 2>/dev/null || true
    git commit -m "Voice note: ${title}" 2>/dev/null || true
    git push origin main 2>/dev/null || true
  fi

  log "Done: ${md_file:t}"
}

# ----- build processing list: failed queue + new args -----
mp3_queue=()

# Prepend previously failed files
if [[ -f "$FAILED_QUEUE" ]]; then
  while IFS= read -r queued_mp3; do
    [[ -f "$queued_mp3" ]] && mp3_queue+=("$queued_mp3")
  done < "$FAILED_QUEUE"
  if [[ ${#mp3_queue[@]} -gt 0 ]]; then
    log "Retrying ${#mp3_queue[@]} previously failed file(s)"
  fi
fi

# ----- convert new input files to MP3 and add to queue -----
for input in "$@"; do
  [[ -d "$input" ]] && continue
  case "${input:l}" in
    *.m4a|*.mp3|*.wav|*.aac) ;;
    *) continue ;;
  esac

  wait_stable "$input"

  local_time_slug="$(date +%Y%m%d-%H%M%S)"
  log "Processing: ${input:t}"

  mp3_file="$AUDIO_DIR/voice-memo-${local_time_slug}.mp3"
  [[ "${input:l}" == *.mp3 ]] && cp "$input" "$mp3_file" || \
    "$FFMPEG_BIN" -y -i "$input" "${MP3_OPTS[@]}" "$mp3_file"

  mp3_queue+=("$mp3_file")
done

# ----- process all queued MP3s -----
new_failures=()
for mp3_file in ${mp3_queue[@]+"${mp3_queue[@]}"}; do
  log "Processing MP3: ${mp3_file:t}"
  if process_mp3 "$mp3_file"; then
    # Success — remove from failed queue if it was there
    if [[ -f "$FAILED_QUEUE" ]]; then
      grep -vxF "$mp3_file" "$FAILED_QUEUE" > "${FAILED_QUEUE}.tmp" 2>/dev/null || true
      mv "${FAILED_QUEUE}.tmp" "$FAILED_QUEUE"
    fi
  else
    # Failure — queue for next run and notify
    new_failures+=("$mp3_file")
    osascript -e 'display notification "Voice note failed to transcribe (will retry next run)" with title "Voice Note Pipeline" sound name "Basso"' 2>/dev/null || true
  fi
done

# Write any new failures to the queue (preserving existing entries)
for f in ${new_failures[@]+"${new_failures[@]}"}; do
  grep -qxF "$f" "$FAILED_QUEUE" 2>/dev/null || echo "$f" >> "$FAILED_QUEUE"
done

# Clean up empty queue file
if [[ -f "$FAILED_QUEUE" ]] && [[ ! -s "$FAILED_QUEUE" ]]; then
  rm -f "$FAILED_QUEUE"
fi

echo "[DONE] $(date '+%Y-%m-%dT%H:%M:%S')"