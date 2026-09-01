#!/usr/bin/env bash
# renumber_inserts_v1.sh — Linux only
# Prefix video files with 001_, 002_, 003_... for the broadcast assembler.
# Original name is kept after the underscore.
#   open.mp4             -> 001_open.mp4
#   01_be right back.mp4 -> 001_be right back.mp4
VERSION=1
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script is Linux-only. Found: $(uname -s)" >&2
  exit 1
fi

SORT="name"
START=1
DRY=0
YES=0
TARGET=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [FOLDER]

Prefix every video in FOLDER with a 3-digit index so sort -V order
matches air order. The original name after any old leading number is kept.

  001_original-name.mp4
  002_original-name.mp4

Options:
  -s, --sort name|mtime   Order before numbering (default: name)
  -n, --start N           First index (default: 1 → 001)
  -d, --dry-run           Show renames, change nothing
  -y, --yes               Do not ask for confirmation
  -h, --help              This help

If FOLDER is omitted you will be prompted.
Re-running strips an existing leading NNN_ / NN- style prefix first
so you do not get 001_001_open.mp4.

Staging happens in FOLDER/.renumber.XXXXXX (same filesystem).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--sort)
      SORT="${2:-}"
      shift 2
      ;;
    -n|--start)
      START="${2:-}"
      shift 2
      ;;
    -d|--dry-run)
      DRY=1
      shift
      ;;
    -y|--yes)
      YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      TARGET="$1"
      shift
      ;;
  esac
done

if [[ "$SORT" != name && "$SORT" != mtime ]]; then
  echo "--sort must be name or mtime" >&2
  exit 1
fi
if ! [[ "$START" =~ ^[0-9]+$ ]] || (( START < 0 || START > 999 )); then
  echo "--start must be an integer 0-999" >&2
  exit 1
fi

if [[ -z "$TARGET" ]]; then
  read -r -p "Folder to renumber: " TARGET || true
fi
TARGET="${TARGET/#\~/$HOME}"
TARGET="${TARGET%/}"

if [[ -z "$TARGET" || ! -d "$TARGET" ]]; then
  echo "Not a directory: ${TARGET:-<(empty)>}" >&2
  exit 1
fi

strip_prefix() {
  local base="$1"
  if [[ "$base" =~ ^[0-9]{1,4}[_\-\.[:space:]]+(.*)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$base"
  fi
}

mapfile -t FILES < <(
  find "$TARGET" -maxdepth 1 -type f \( \
      -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' \
      -o -iname '*.webm' -o -iname '*.m4v' -o -iname '*.avi' \
    \) ! -name '.*' -printf '%P\n'
)

if ((${#FILES[@]} == 0)); then
  echo "No video files in $TARGET" >&2
  exit 1
fi

if [[ "$SORT" == mtime ]]; then
  mapfile -t FILES < <(
    printf '%s\n' "${FILES[@]}" \
      | while IFS= read -r f; do
          printf '%s\t%s\n' "$(stat -c '%Y' "$TARGET/$f")" "$f"
        done \
      | sort -n \
      | cut -f2-
  )
else
  mapfile -t FILES < <(printf '%s\n' "${FILES[@]}" | sort -V)
fi

if (( START + ${#FILES[@]} - 1 > 999 )); then
  echo "Need 3-digit names only; ${#FILES[@]} files starting at $START overflows 999." >&2
  exit 1
fi

echo "Folder: $TARGET"
echo "Sort:   $SORT"
echo "Plan:"
echo

n="$START"
declare -a SRC=() DEST=()
for f in "${FILES[@]}"; do
  ext="${f##*.}"
  base="${f%.*}"
  core="$(strip_prefix "$base")"
  [[ -n "$core" ]] || core="clip"
  dest="$(printf '%03d_%s.%s' "$n" "$core" "$ext")"
  printf '  %s\n    -> %s\n' "$f" "$dest"
  SRC+=("$f")
  DEST+=("$dest")
  n=$((n + 1))
done

declare -A seen=()
for d in "${DEST[@]}"; do
  if [[ -n "${seen[$d]:-}" ]]; then
    echo "Two files would become $d — rename one of the originals and retry." >&2
    exit 1
  fi
  seen[$d]=1
done

if (( DRY )); then
  echo
  echo "Dry run. Nothing renamed."
  exit 0
fi

if (( ! YES )); then
  echo
  read -r -p "Apply these renames? [Y/n]: " ans || true
  ans="${ans:-y}"
  if [[ ! "$ans" =~ ^[Yy] ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# Same filesystem as the videos. /tmp is often a small tmpfs;
# mv across devices copies every byte and fills it.
WORKDIR="$(mktemp -d "$TARGET/.renumber.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

for i in "${!SRC[@]}"; do
  mv -n -- "$TARGET/${SRC[$i]}" "$WORKDIR/$i.${SRC[$i]##*.}"
done
for i in "${!SRC[@]}"; do
  if [[ -e "$TARGET/${DEST[$i]}" ]]; then
    echo "Refusing to overwrite $TARGET/${DEST[$i]}" >&2
    echo "Partial move is in $WORKDIR — inspect before deleting." >&2
    trap - EXIT
    exit 1
  fi
  mv -n -- "$WORKDIR/$i.${SRC[$i]##*.}" "$TARGET/${DEST[$i]}"
done

echo
echo "Renamed ${#SRC[@]} file(s) in $TARGET"