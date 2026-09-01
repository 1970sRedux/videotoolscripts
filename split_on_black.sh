#!/usr/bin/env bash
set -u

# Usage:
#   ./split_on_black.sh
#   ./split_on_black.sh source.mp4
#   ./split_on_black.sh source.mp4 clips

OUTDIR="${2:-clips}"
LOG="blackdetect.log"

pick_source() {
  if [ -n "${1:-}" ]; then
    echo "$1"
    return
  fi
  if [ -f source.mp4 ]; then
    echo source.mp4
    return
  fi
  found=()
  for f in *.[Mm][Pp]4 *.[Mm][Oo][Vv] *.[Mm][Kk][Vv] *.[Ww][Ee][Bb][Mm]; do
    [ -f "$f" ] || continue
    found+=("$f")
  done
  if [ "${#found[@]}" -eq 1 ]; then
    echo "${found[0]}"
    return
  fi
  echo "ERROR: pass the source filename."
  echo "Videos in this folder:"
  printf '  %s\n' "${found[@]:-}"
  exit 1
}

INPUT="$(pick_source "${1:-}")"

mkdir -p "$OUTDIR"

echo "PWD:     $PWD"
echo "Source:  $INPUT"
echo "Log:     $LOG"
echo "Clips:   $OUTDIR"

if [ ! -f "$INPUT" ]; then
  echo "ERROR: source not found: $INPUT"
  exit 1
fi

echo
echo "== Detecting black gaps =="
ffmpeg -hide_banner -i "$INPUT" \
  -vf "blackdetect=d=0.2:pic_th=0.98:pix_th=0.10" \
  -an -f null - 2> "$LOG"

if ! grep -q "black_start:" "$LOG"; then
  echo "ERROR: no black gaps found. Check $LOG"
  echo "Try: d=0.1  or  pic_th=0.90  or  pix_th=0.15"
  exit 1
fi

DURATION=$(ffmpeg -hide_banner -i "$INPUT" 2>&1 \
  | sed -nE 's/.*Duration: ([0-9]+):([0-9]+):([0-9.]+).*/\1 \2 \3/p' \
  | awk '{ printf "%.3f", $1*3600 + $2*60 + $3 }' || true)

if [ -z "$DURATION" ]; then
  echo "ERROR: could not read duration"
  exit 1
fi

BLACKS=()
while IFS= read -r line; do
  BLACKS+=("$line")
done < <(
  grep -oE 'black_start:[0-9.]+ black_end:[0-9.]+' "$LOG" \
    | sed -E 's/black_start:([0-9.]+) black_end:([0-9.]+)/\1 \2/'
)

echo "Duration: $DURATION seconds"
echo "Gaps:     ${#BLACKS[@]}"
echo
echo "== Cutting clips =="

STARTS=(0)
ENDS=()
for pair in "${BLACKS[@]}"; do
  set -- $pair
  ENDS+=("$1")
  STARTS+=("$2")
done
ENDS+=("$DURATION")

i=1
for idx in "${!STARTS[@]}"; do
  s="${STARTS[$idx]}"
  e="${ENDS[$idx]}"
  awk -v s="$s" -v e="$e" 'BEGIN { if ((e - s) < 0.4) exit 1 }' || continue
  dur=$(awk -v s="$s" -v e="$e" 'BEGIN { printf "%.3f", e - s }')
  out=$(printf "%s/clip_%03d.mp4" "$OUTDIR" "$i")
  echo "clip_$(printf '%03d' "$i")  $s -> $e  (${dur}s)"
  ffmpeg -n -ss "$s" -i "$INPUT" -t "$dur" -c copy "$out" \
    || echo "WARN: failed $out"
  i=$((i + 1))
done

echo
echo "Done."
echo "Fine-trim individual clips in LosslessCut if needed."
ls -lh "$OUTDIR"