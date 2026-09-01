#!/usr/bin/env bash
set -u

pick_file() {
  local prompt="$1"
  osascript -e "POSIX path of (choose file with prompt \"${prompt}\")" 2>/dev/null
}

VIDEO="${1:-}"
AUDIO="${2:-}"
OUT="${3:-}"

if [ -z "$VIDEO" ]; then
  VIDEO="$(pick_file "Select the video file")"
fi
if [ -z "$AUDIO" ]; then
  AUDIO="$(pick_file "Select the audio file")"
fi

VIDEO="${VIDEO%$'\r'}"
AUDIO="${AUDIO%$'\r'}"

if [ -z "$VIDEO" ] || [ ! -f "$VIDEO" ]; then
  echo "ERROR: no video selected"
  exit 1
fi
if [ -z "$AUDIO" ] || [ ! -f "$AUDIO" ]; then
  echo "ERROR: no audio selected"
  exit 1
fi

if [ -z "$OUT" ]; then
  base="$(basename "${VIDEO%.*}")"
  OUT="${base}.mkv"
fi

echo "Video: $VIDEO"
echo "Audio: $AUDIO"
echo "Out:   $OUT"

ffmpeg -n -i "$VIDEO" -i "$AUDIO" \
  -map 0:v:0 -map 1:a:0 \
  -c copy -shortest \
  "$OUT"

echo "Wrote $OUT"