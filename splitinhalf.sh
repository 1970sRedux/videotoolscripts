#!/usr/bin/env bash
set -u

# Usage:
#   ./split_half.sh
#   ./split_half.sh source.mp4

get_duration() {
  local f="$1" d=""
  if command -v ffprobe >/dev/null 2>&1; then
    d=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null || true)
  fi
  if [ -z "$d" ]; then
    d=$(ffmpeg -hide_banner -i "$f" 2>&1 \
      | sed -nE 's/.*Duration: ([0-9]+):([0-9]+):([0-9.]+).*/\1 \2 \3/p' \
      | awk '{ printf "%.3f", $1*3600 + $2*60 + $3 }' || true)
  fi
  echo "$d"
}

pick_source() {
  if [ -n "${1:-}" ]; then
    echo "$1"
    return
  fi
  found=()
  for f in *.[Mm][Pp]4 *.[Mm][Kk][Vv] *.[Mm][Oo][Vv] *.[Ww][Ee][Bb][Mm] *.[Mm]2[Vv]; do
    [ -f "$f" ] || continue
    case "$f" in
      *_part1.*|*_part2.*) continue ;;
    esac
    found+=("$f")
  done
  if [ "${#found[@]}" -eq 1 ]; then
    echo "${found[0]}"
    return
  fi
  echo "ERROR: pass the video filename." >&2
  printf '  %s\n' "${found[@]:-}" >&2
  exit 1
}

INPUT="$(pick_source "${1:-}")"

if [ ! -f "$INPUT" ]; then
  echo "ERROR: not found: $INPUT"
  exit 1
fi

DURATION="$(get_duration "$INPUT")"
if [ -z "$DURATION" ]; then
  echo "ERROR: could not read duration"
  exit 1
fi

HALF=$(awk -v d="$DURATION" 'BEGIN { printf "%.3f", d / 2 }')
EXT="${INPUT##*.}"
BASE="${INPUT%.*}"
OUT1="${BASE}_part1.${EXT}"
OUT2="${BASE}_part2.${EXT}"

echo "PWD:      $PWD"
echo "Source:   $INPUT"
echo "Duration: $DURATION seconds"
echo "Split at: $HALF seconds"
echo "Part 1:   $OUT1"
echo "Part 2:   $OUT2"

ffmpeg -n -i "$INPUT" -t "$HALF" -c copy "$OUT1"
ffmpeg -n -ss "$HALF" -i "$INPUT" -c copy "$OUT2"

echo "Done."
ls -lh "$OUT1" "$OUT2"