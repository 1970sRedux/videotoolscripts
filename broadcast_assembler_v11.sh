#!/usr/bin/env bash
# broadcast_assembler_v11.sh — Linux only (GNU bash + GNU coreutils + ffmpeg)
# Version: 11
# v10 plus a program-folder browser: scan mount roots, optional name filter,
# fzf multi-select (numbered fallback), save program_folders.txt.
VERSION=11
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script is Linux-only. Found: $(uname -s)" >&2
  exit 1
fi

WIDTH=1920
HEIGHT=1080
FPS=30
CRF=23
PRESET="medium"
AUDIO_RATE=48000
AUDIO_BITRATE="128k"
CONFIG_FILE="./broadcast.conf"
MEMORY_FILE="./broadcast_memory.txt"
STAGE_DIR="${STAGE_DIR:-./broadcast_pack}"
OUTPUT_MODE="${OUTPUT_MODE:-stage}"
FOLDER_LIST_FILE="${FOLDER_LIST_FILE:-./program_folders.txt}"
# sd480: how to treat 720x480 or 720x576 when SAR is 1:1 / unknown
#   square | 4:3 | 16:9
SD480_ASSUME="${SD480_ASSUME:-square}"
# Extra horizontal stretch after SAR. 1 = none.
# 1.333 ≈ 4:3 sensor + 1.33x adapter to 16:9
# 2     = 2x anamorphic lens
OPTICAL_UNSQUEEZE="${OPTICAL_UNSQUEEZE:-1}"

BROADCAST_TMP=""
cleanup() {
  if [[ -n "${BROADCAST_TMP:-}" && -d "$BROADCAST_TMP" ]]; then
    rm -rf "$BROADCAST_TMP"
  fi
}
trap cleanup EXIT INT TERM

need_bins() {
  for b in ffmpeg ffprobe find shuf awk sort mktemp cp mkdir; do
    command -v "$b" >/dev/null || { echo "Missing required command: $b" >&2; exit 1; }
  done
}

memory_prune() {
  local tmp kind path
  [[ -f "$MEMORY_FILE" ]] || { : > "$MEMORY_FILE"; return 0; }
  tmp="$(mktemp)"
  while IFS=$'\t' read -r kind path || [[ -n "${kind:-}" ]]; do
    [[ "$kind" == \#* || -z "$kind" ]] && continue
    [[ -f "$path" ]] || continue
    printf '%s\t%s\n' "$kind" "$path"
  done < "$MEMORY_FILE" > "$tmp"
  mv "$tmp" "$MEMORY_FILE"
}

memory_has() {
  local kind="$1" path="$2"
  [[ -f "$MEMORY_FILE" ]] || return 1
  grep -Fxq "${kind}	${path}" "$MEMORY_FILE"
}

memory_append() {
  local kind="$1" path="$2"
  [[ -n "$path" && -f "$path" ]] || return 0
  memory_has "$kind" "$path" && return 0
  printf '%s\t%s\n' "$kind" "$path" >> "$MEMORY_FILE"
}

memory_clear_kind() {
  local kind="$1" tmp
  [[ -f "$MEMORY_FILE" ]] || return 0
  tmp="$(mktemp)"
  grep -v "^${kind}	" "$MEMORY_FILE" > "$tmp" || true
  mv "$tmp" "$MEMORY_FILE"
}

filter_unused() {
  local kind="$1"
  shift
  local f
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    memory_has "$kind" "$f" && continue
    printf '%s\n' "$f"
  done
}

remember_rundown() {
  local entry kind path
  for entry in "${RUNDOWN[@]}"; do
    kind="${entry%%|*}"
    path="${entry#*|}"
    case "$kind" in
      PROGRAM) memory_append PROGRAM "$path" ;;
      SIGNOFF) memory_append SIGNOFF "$path" ;;
    esac
  done
}

stage_slug() {
  local kind="$1" base="$2"
  kind="${kind//\//-}"
  printf '%s_%s' "$kind" "$base"
}

prompt() {
  local q="$1" def="${2-}" ans
  if [[ -n "$def" ]]; then
    read -r -p "$q [$def]: " ans || true
    printf '%s' "${ans:-$def}"
  else
    read -r -p "$q: " ans || true
    printf '%s' "$ans"
  fi
}

prompt_yn() {
  local q="$1" def="${2:-y}" ans
  local shown
  if [[ "$def" == y ]]; then shown="Y/n"; else shown="y/N"; fi
  read -r -p "$q [$shown]: " ans || true
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]]
}

hms() {
  local s="${1%.*}"
  [[ "$s" =~ ^[0-9]+$ ]] || { printf '??:??:??'; return; }
  printf '%02d:%02d:%02d' $((s/3600)) $(((s%3600)/60)) $((s%60))
}

duration_of() {
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null || echo 0
}

collect_videos() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -type f \( \
      -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' \
      -o -iname '*.webm' -o -iname '*.m4v' -o -iname '*.avi' \
      -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.wmv' \
      -o -iname '*.flv' -o -iname '*.ts' -o -iname '*.vob' \
      -o -iname '*.m2ts' \
    \) ! -name '.*' | sort -V
}

read_paths_until_blank() {
  local line
  local -n _out=$1
  while true; do
    read -r -p "  folder (blank to finish): " line || true
    [[ -z "$line" ]] && break
    line="${line/#\~/$HOME}"
    if [[ ! -d "$line" ]]; then
      echo "    not a directory, skipped: $line"
      continue
    fi
    _out+=("$line")
  done
}

ask_folder() {
  local label="$1" current="${2-}" path
  path="$(prompt "$label (blank to skip)" "$current")"
  path="${path/#\~/$HOME}"
  if [[ -z "$path" ]]; then
    printf ''
    return
  fi
  if [[ ! -d "$path" ]]; then
    echo "    not a directory, skipped: $path" >&2
    printf ''
    return
  fi
  printf '%s' "$path"
}

load_folder_list_file() {
  local file="$1" line
  PROGRAM_FOLDERS=()
  [[ -f "$file" ]] || { echo "No file: $file" >&2; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line/#\~/$HOME}"
    if [[ -d "$line" ]]; then
      PROGRAM_FOLDERS+=("$line")
    else
      echo "  skip missing: $line"
    fi
  done < "$file"
}

save_folder_list_file() {
  local f
  {
    echo "# program folders  $(date)"
    for f in "${PROGRAM_FOLDERS[@]}"; do
      printf '%s\n' "$f"
    done
  } > "$FOLDER_LIST_FILE"
  echo "Wrote $FOLDER_LIST_FILE"
}

discover_video_dirs() {
  local root="$1" pat="${2-}" dir base
  [[ -d "$root" ]] || return 0
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    base="${dir##*/}"
    if [[ -n "$pat" ]]; then
      case "$base" in
        $pat) ;;
        *) continue ;;
      esac
    fi
    printf '%s\n' "$dir"
  done < <(
    find "$root" -type f \( \
        -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' \
        -o -iname '*.webm' -o -iname '*.m4v' -o -iname '*.avi' \
        -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.wmv' \
        -o -iname '*.flv' -o -iname '*.ts' -o -iname '*.vob' \
        -o -iname '*.m2ts' \
      \) ! -name '.*' -printf '%h\n' 2>/dev/null | sort -u
  )
}

count_videos_here() {
  local dir="$1"
  find "$dir" -maxdepth 1 -type f \( \
      -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' \
      -o -iname '*.webm' -o -iname '*.m4v' -o -iname '*.avi' \
      -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.wmv' \
      -o -iname '*.flv' -o -iname '*.ts' -o -iname '*.vob' \
      -o -iname '*.m2ts' \
    \) ! -name '.*' 2>/dev/null | wc -l
}

parse_index_picks() {
  local spec="$1" max="$2"
  local -a out=()
  local tok a b i
  spec="${spec//,/ }"
  for tok in $spec; do
    if [[ "$tok" =~ ^[0-9]+-[0-9]+$ ]]; then
      a="${tok%-*}"
      b="${tok#*-}"
      (( a < 1 )) && a=1
      (( b > max )) && b=$max
      for ((i=a; i<=b; i++)); do
        out+=("$i")
      done
    elif [[ "$tok" =~ ^[0-9]+$ ]]; then
      (( tok >= 1 && tok <= max )) && out+=("$tok")
    fi
  done
  printf '%s\n' "${out[@]}"
}

browse_program_folders() {
  local -a roots=() cands=() labels=() picked=()
  local filter rel n i line spec idx
  echo
  echo "Search under one or more roots (drive / library top). Blank line ends."
  read_paths_until_blank roots
  if ((${#roots[@]} == 0)); then
    echo "No roots given."
    return 1
  fi
  filter="$(prompt "Only list folders matching (blank = all)" "${FOLDER_FILTER:-Season*}")"
  echo "Scanning..."
  for r in "${roots[@]}"; do
    mapfile -t _found < <(discover_video_dirs "$r" "$filter")
    cands+=("${_found[@]+"${_found[@]}"}")
  done
  if ((${#cands[@]} > 0)); then
    mapfile -t cands < <(printf '%s\n' "${cands[@]}" | sort -u)
  fi
  if ((${#cands[@]} == 0)); then
    echo "No matching folders."
    return 1
  fi

  for i in "${!cands[@]}"; do
    n="$(count_videos_here "${cands[$i]}")"
    rel="${cands[$i]}"
    labels+=("$(printf '%5s  %s' "$n" "$rel")")
  done

  echo "Found ${#cands[@]} folder(s)."
  if command -v fzf >/dev/null 2>&1; then
    echo "fzf: type to filter, Tab to mark, Enter to accept."
    mapfile -t picked < <(
      printf '%s\n' "${labels[@]}" | fzf -m --height=80% --reverse \
        --header 'Tab mark  Enter accept  Esc cancel' \
        --preview 'p=$(echo {} | sed -E "s/^[[:space:]]*[0-9]+[[:space:]]+//"); ls -1 "$p" 2>/dev/null | head -n 20' \
        || true
    )
    PROGRAM_FOLDERS=()
    for line in "${picked[@]+"${picked[@]}"}"; do
      path="$(sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' <<<"$line")"
      [[ -d "$path" ]] && PROGRAM_FOLDERS+=("$path")
    done
  else
    echo "fzf not installed; numbered list."
    for i in "${!cands[@]}"; do
      printf '  %3d  %s\n' $((i+1)) "${labels[$i]}"
    done
    spec="$(prompt "Keep which? (all / 1 3 4 / 1-5)" "all")"
    PROGRAM_FOLDERS=()
    if [[ "$spec" == all ]]; then
      PROGRAM_FOLDERS=("${cands[@]}")
    else
      mapfile -t _idx < <(parse_index_picks "$spec" "${#cands[@]}")
      for idx in "${_idx[@]+"${_idx[@]}"}"; do
        PROGRAM_FOLDERS+=("${cands[$((idx-1))]}")
      done
    fi
  fi

  if ((${#PROGRAM_FOLDERS[@]} == 0)); then
    echo "Nothing selected."
    return 1
  fi
  return 0
}

choose_program_folders() {
  local how list
  echo
  echo "How do you want to choose program folders?"
  echo "  1) Type folders one by one"
  echo "  2) Browse a drive (fzf if installed)"
  echo "  3) Load $FOLDER_LIST_FILE"
  how="$(prompt "Choice" "2")"
  case "$how" in
    3)
      list="$(prompt "Folder list file" "$FOLDER_LIST_FILE")"
      load_folder_list_file "$list" || return 1
      ;;
    2)
      browse_program_folders || return 1
      ;;
    *)
      echo "Enter one or more folders. Blank line ends."
      read_paths_until_blank PROGRAM_FOLDERS
      ;;
  esac
  ((${#PROGRAM_FOLDERS[@]} > 0))
}

program_root() {
  local f="$1" d
  for d in "${PROGRAM_FOLDERS[@]}"; do
    case "$f" in
      "$d"|"$d"/*) printf '%s' "$d"; return 0 ;;
    esac
  done
  dirname "$f"
}

# Reorder PROGRAMS so the same source folder is not used twice in a row
# when at least one clip from another folder is still available.
spread_apart_by_folder() {
  local -a leftover=("${PROGRAMS[@]}")
  local -a out=()
  local last="" f root i best_i others cnt j cand
  PROGRAMS=()
  ((${#leftover[@]})) || return 0

  while ((${#leftover[@]} > 0)); do
    others=0
    for f in "${leftover[@]}"; do
      [[ "$(program_root "$f")" == "$last" ]] || others=$((others + 1))
    done

    best_i=-1
    cnt=-1
    for i in "${!leftover[@]}"; do
      cand="$(program_root "${leftover[$i]}")"
      if [[ -n "$last" && "$cand" == "$last" && others -gt 0 ]]; then
        continue
      fi
      local n=0
      for j in "${!leftover[@]}"; do
        [[ "$(program_root "${leftover[$j]}")" == "$cand" ]] && n=$((n + 1))
      done
      if (( n > cnt )); then
        cnt=$n
        best_i=$i
      fi
    done

    if (( best_i < 0 )); then
      for i in "${!leftover[@]}"; do
        best_i=$i
        break
      done
    fi

    f="${leftover[$best_i]}"
    out+=("$f")
    last="$(program_root "$f")"
    unset "leftover[$best_i]"
    leftover=("${leftover[@]}")
  done
  PROGRAMS=("${out[@]}")
}

# Random N clips, spread across folders instead of one global shuffle
# (which can easily draw everything from the largest / last library).
pick_balanced() {
  local need="$1"
  local -a pool=("${@:2}")
  local -a chosen=()
  local -A bucket=()
  local f dir
  PROGRAMS=()
  ((${#pool[@]})) || return 0
  if (( need > ${#pool[@]} )); then
    need=${#pool[@]}
  fi

  for f in "${pool[@]}"; do
    dir="$(dirname "$f")"
    # Bucket by top program folder, not the immediate parent.
    # A file under /media/user/videos/alpha/season1 still counts as alpha.
    local root="" d
    for d in "${PROGRAM_FOLDERS[@]}"; do
      case "$f" in
        "$d"|"$d"/*) root="$d"; break ;;
      esac
    done
    [[ -n "$root" ]] || root="$dir"
    bucket["$root"]+="$f"$'\n'
  done

  local -a roots=("${PROGRAM_FOLDERS[@]}")
  local -a nonempty=()
  for d in "${roots[@]}"; do
    if [[ -n "${bucket[$d]:-}" ]]; then
      nonempty+=("$d")
    fi
  done
  local n=${#nonempty[@]}
  (( n > 0 )) || return 0

  local base extra i take
  base=$((need / n))
  extra=$((need % n))

  declare -A used=()
  i=0
  for d in "${nonempty[@]}"; do
    take=$base
    (( i < extra )) && take=$((take + 1))
    i=$((i + 1))
    (( take > 0 )) || continue
    mapfile -t _files < <(printf '%s' "${bucket[$d]}" | sed '/^$/d' | shuf)
    local j=0
    for f in "${_files[@]}"; do
      (( j < take )) || break
      PROGRAMS+=("$f")
      used["$f"]=1
      j=$((j + 1))
    done
  done

  if ((${#PROGRAMS[@]} < need)); then
    mapfile -t _rest < <(
      for f in "${pool[@]}"; do
        [[ -n "${used[$f]:-}" ]] && continue
        printf '%s\n' "$f"
      done | shuf
    )
    for f in "${_rest[@]}"; do
      ((${#PROGRAMS[@]} < need)) || break
      PROGRAMS+=("$f")
    done
  fi

  spread_apart_by_folder
}

print_folder_inventory() {
  local d n
  echo
  echo "Program library inventory:"
  for d in "${PROGRAM_FOLDERS[@]}"; do
    n="$(collect_videos "$d" | wc -l)"
    printf '  %5s  %s\n' "$n" "$d"
    if [[ "$n" == 0 ]]; then
      echo "         (no matching videos — check path and extensions)"
    fi
  done
}

list_library() {
  local title="$1"
  shift
  local files=("$@")
  echo
  if ((${#files[@]} == 0)); then
    echo "$title: (none)"
    return
  fi
  echo "$title (${#files[@]}), filename order:"
  local i=1 f
  for f in "${files[@]}"; do
    printf '  %2d. %s\n' "$i" "$(basename "$f")"
    i=$((i+1))
  done
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
# last-used broadcast_assembler settings (Linux)  version=$VERSION
PROGRAM_FOLDERS=($(printf '%q ' "${PROGRAM_FOLDERS[@]+"${PROGRAM_FOLDERS[@]}"}"))
ID_FOLDER=$(printf '%q' "${ID_FOLDER:-}")
BUMP_OUT_FOLDER=$(printf '%q' "${BUMP_OUT_FOLDER:-}")
BUMP_IN_FOLDER=$(printf '%q' "${BUMP_IN_FOLDER:-}")
COMM_FOLDER=$(printf '%q' "${COMM_FOLDER:-}")
SIGNOFF_FOLDER=$(printf '%q' "${SIGNOFF_FOLDER:-}")
SIGNOFF_MODE=${SIGNOFF_MODE:-random}
COUNT=${COUNT:-10}
MODE=${MODE:-1}
BREAK_EVERY=${BREAK_EVERY:-1}
COMMS_PER_BREAK=${COMMS_PER_BREAK:-2}
OPEN_WITH_ID=${OPEN_WITH_ID:-y}
CLOSE_WITH_ID=${CLOSE_WITH_ID:-y}
HOUR_ID=${HOUR_ID:-n}
HOUR_SECONDS=${HOUR_SECONDS:-3600}
LOOP_IDS=${LOOP_IDS:-y}
LOOP_BUMP_OUT=${LOOP_BUMP_OUT:-y}
LOOP_BUMP_IN=${LOOP_BUMP_IN:-y}
LOOP_COMMS=${LOOP_COMMS:-y}
FADE=${FADE:-0}
SD480_ASSUME=$(printf '%q' "${SD480_ASSUME:-16:9}")
OPTICAL_UNSQUEEZE=${OPTICAL_UNSQUEEZE:-1}
OUTPUT=$(printf '%q' "${OUTPUT:-broadcast.mp4}")
OUTPUT_MODE=${OUTPUT_MODE:-stage}
STAGE_DIR=$(printf '%q' "${STAGE_DIR:-./broadcast_pack}")
EOF
  echo "Saved settings to $CONFIG_FILE"
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  # v2 stored a single BUMP_FOLDER. Offer it as the out-folder default
  # only when the v3 keys are empty.
  if [[ -z "${BUMP_OUT_FOLDER:-}" && -n "${BUMP_FOLDER:-}" ]]; then
    BUMP_OUT_FOLDER="$BUMP_FOLDER"
  fi
}

sar_is_square() {
  local sar="$1"
  [[ -z "$sar" || "$sar" == "N/A" || "$sar" == "0:1" ]] && return 0
  [[ "$sar" == "1:1" ]] && return 0
  awk -v s="$sar" 'BEGIN{
    n=split(s,a,":");
    if(n!=2 || a[2]==0) exit 0;
    r=a[1]/a[2];
    exit !(r>0.98 && r<1.02)
  }'
}

is_sd_anamorphic_size() {
  local w="$1" h="$2"
  [[ "$w" == 720 || "$w" == 704 ]] || return 1
  [[ "$h" == 480 || "$h" == 486 || "$h" == 576 ]]
}

# Unsqueeze by stored SAR (and optional SD / lens policy), then fit 1920x1080.
build_vf() {
  local src="$1"
  local w h sar unsqueeze vf probe rest
  probe="$(
    ffprobe -v error -select_streams v:0 \
      -show_entries stream=width,height,sample_aspect_ratio \
      -of csv=p=0:s='|' "$src" 2>/dev/null || true
  )"
  w="${probe%%|*}"
  rest="${probe#*|}"
  h="${rest%%|*}"
  sar="${rest#*|}"

  unsqueeze="sar"
  if is_sd_anamorphic_size "$w" "$h" && sar_is_square "$sar"; then
    case "${SD480_ASSUME}" in
      4:3)  unsqueeze="(8/9)" ;;   # NTSC 720x480 → 4:3 DAR
      16:9) unsqueeze="(32/27)" ;; # NTSC 720x480 → 16:9 DAR
      pal4:3) unsqueeze="(16/15)" ;;
      pal16:9) unsqueeze="(64/45)" ;;
      square|*) unsqueeze="1" ;;
    esac
    if [[ "$h" == 576 && "$SD480_ASSUME" == 4:3 ]]; then
      unsqueeze="(16/15)"
    fi
    if [[ "$h" == 576 && "$SD480_ASSUME" == 16:9 ]]; then
      unsqueeze="(64/45)"
    fi
  fi

  # Square-pixel unsqueeze first (even dimensions for yuv420p).
  vf="scale=trunc(iw*${unsqueeze}/2)*2:trunc(ih/2)*2,setsar=1"

  if awk -v o="${OPTICAL_UNSQUEEZE}" 'BEGIN{exit !(o>1.001)}'; then
    if is_sd_anamorphic_size "$w" "$h"; then
      vf="${vf},scale=trunc(iw*${OPTICAL_UNSQUEEZE}/2)*2:ih,setsar=1"
    fi
  fi

  vf="${vf},scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=${FPS}"
  printf '%s' "$vf"
}

normalize_clip() {
  local src="$1" dest="$2"
  local has_audio vf fade_a dur fade out_start
  fade="${FADE:-0}"
  vf="$(build_vf "$src")"

  if awk -v f="$fade" 'BEGIN{exit !(f>0)}'; then
    dur="$(duration_of "$src")"
    dur="${dur%.*}"
    [[ "$dur" =~ ^[0-9]+$ ]] || dur=0
    out_start=0
    if awk -v d="$dur" -v f="$fade" 'BEGIN{exit !(d>f*2)}'; then
      out_start="$(awk -v d="$dur" -v f="$fade" 'BEGIN{printf "%s", d-f}')"
    fi
    vf="${vf},fade=t=in:st=0:d=${fade},fade=t=out:st=${out_start}:d=${fade}"
    fade_a="afade=t=in:st=0:d=${fade},afade=t=out:st=${out_start}:d=${fade}"
  fi

  has_audio="$(
    ffprobe -v error -select_streams a:0 \
      -show_entries stream=codec_type -of csv=p=0 "$src" 2>/dev/null || true
  )"

  if [[ -n "$has_audio" ]]; then
    ffmpeg -hide_banner -loglevel error -y -i "$src" \
      -vf "$vf" \
      ${fade_a:+-af "$fade_a"} \
      -c:v libx264 -crf "$CRF" -preset "$PRESET" -pix_fmt yuv420p -threads 4 \
      -c:a aac -b:a "$AUDIO_BITRATE" -ar "$AUDIO_RATE" -ac 2 \
      -movflags +faststart \
      "$dest"
  else
    ffmpeg -hide_banner -loglevel error -y -i "$src" \
      -f lavfi -i "anullsrc=r=${AUDIO_RATE}:cl=stereo" \
      -vf "$vf" \
      ${fade_a:+-af "$fade_a"} \
      -map 0:v:0 -map 1:a:0 \
      -c:v libx264 -crf "$CRF" -preset "$PRESET" -pix_fmt yuv420p -threads 4 \
      -c:a aac -b:a "$AUDIO_BITRATE" -ar "$AUDIO_RATE" -ac 2 \
      -shortest \
      -movflags +faststart \
      "$dest"
  fi
}

print_rundown() {
  local i=1 total=0 d kind path
  printf '\n--- rundown ---\n'
  printf '%-4s %-12s %-10s %s\n' '#' 'TYPE' 'LENGTH' 'FILE'
  for entry in "${RUNDOWN[@]}"; do
    kind="${entry%%|*}"
    path="${entry#*|}"
    d="$(duration_of "$path")"
    total="$(awk -v a="$total" -v b="$d" 'BEGIN{printf "%.3f", a+b}')"
    printf '%-4s %-12s %-10s %s\n' "$i" "$kind" "$(hms "$d")" "$path"
    i=$((i+1))
  done
  printf '\nSegments: %s   Approx. runtime: %s\n\n' "${#RUNDOWN[@]}" "$(hms "$total")"
}

NEXT_PATH=""
next_from() {
  # Must NOT run in command substitution: the index lives in this shell.
  local -n _arr=$1
  local -n _idx=$2
  local loop="$3"
  local n=${#_arr[@]}
  NEXT_PATH=""
  (( n > 0 )) || return 0
  if (( _idx >= n )); then
    [[ "$loop" == y ]] || return 0
    _idx=0
  fi
  NEXT_PATH="${_arr[$_idx]}"
  _idx=$((_idx + 1))
}

last_kind() {
  if ((${#RUNDOWN[@]} == 0)); then
    printf ''
    return
  fi
  local last="${RUNDOWN[-1]}"
  printf '%s' "${last%%|*}"
}

append_seg() {
  local kind="$1" path="$2"
  [[ -n "$path" ]] || return 0
  if [[ "$kind" == ID && "$(last_kind)" == ID ]]; then
    return 0
  fi
  RUNDOWN+=("${kind}|${path}")
}

append_id() {
  next_from IDS ID_I "${LOOP_IDS}"
  append_seg ID "$NEXT_PATH"
}

append_bump_out() {
  next_from BUMPS_OUT BUMP_OUT_I "${LOOP_BUMP_OUT}"
  append_seg BUMP-OUT "$NEXT_PATH"
}

append_bump_in() {
  next_from BUMPS_IN BUMP_IN_I "${LOOP_BUMP_IN}"
  append_seg BUMP-IN "$NEXT_PATH"
}

append_comm() {
  next_from COMMS COMM_I "${LOOP_COMMS}"
  append_seg COMMERCIAL "$NEXT_PATH"
}

# Pod: bump-out -> K commercials -> bump-in
# A missing library just omits that side; a "we'll be right back"
# can never be pulled from the in folder.
append_break() {
  local k="${1:-$COMMS_PER_BREAK}" i
  append_bump_out
  for ((i=0; i<k; i++)); do
    append_comm
  done
  append_bump_in
}

maybe_hour_id() {
  [[ "${HOUR_ID}" == y ]] || return 0
  local now="$1"
  awk -v n="$now" -v h="$HOUR_SECONDS" -v last="$LAST_HOUR_MARK" \
    'BEGIN{exit !((int(n/h) > int(last/h)) && n>=h)}' || return 0
  if [[ "$(last_kind)" != ID ]]; then
    append_id
  fi
  LAST_HOUR_MARK="$now"
}

running_total() {
  local sum=0 entry d
  for entry in "${RUNDOWN[@]}"; do
    d="$(duration_of "${entry#*|}")"
    sum="$(awk -v a="$sum" -v b="$d" 'BEGIN{printf "%.3f", a+b}')"
  done
  printf '%s' "$sum"
}

build_rundown() {
  RUNDOWN=()
  ID_I=0
  BUMP_OUT_I=0
  BUMP_IN_I=0
  COMM_I=0
  LAST_HOUR_MARK=0

  if [[ "${OPEN_WITH_ID}" == y ]]; then
    append_id
  fi

  local p is_last
  for ((p=0; p<${#PROGRAMS[@]}; p++)); do
    append_seg PROGRAM "${PROGRAMS[$p]}"
    maybe_hour_id "$(running_total)"

    is_last=0
    (( p == ${#PROGRAMS[@]}-1 )) && is_last=1

    if (( is_last )); then
      continue
    fi
    if (( BREAK_EVERY > 0 && (p+1) % BREAK_EVERY == 0 )); then
      append_break "$COMMS_PER_BREAK"
    fi
  done

  if [[ "${CLOSE_WITH_ID}" == y ]]; then
    append_id
  fi

  # End of broadcast day: always the last segment when the library exists.
  if ((${#SIGNOFFS[@]} > 0)); then
    local closer=""
    case "${SIGNOFF_MODE}" in
      first)
        closer="${SIGNOFFS[0]}"
        ;;
      *)
        closer="$(printf '%s\n' "${SIGNOFFS[@]}" | shuf -n 1)"
        ;;
    esac
    append_seg SIGNOFF "$closer"
  fi
}

interactive() {
  echo
  echo "========================================"
  echo "  DIY broadcast assembler  v${VERSION}  (Linux)"
  echo "========================================"
  echo "Programs are the unpredictable part."
  echo "Each insert library plays in filename order:"
  echo "  ids/            01_open.mp4"
  echo "  bumps_out/      01_brb.mp4"
  echo "  commercials/    01_spot.mp4"
  echo "  bumps_in/       01_welcome.mp4"
  echo "  signoff/        end-of-day videos (one of these is always last)"
  echo
  echo "A break is always:  bump-out -> commercials -> bump-in"
  echo "IDs only open, close, or optional top-of-hour."
  echo "Two IDs will never air back to back."
  echo "Out-bumps and in-bumps never share a folder."
  echo
  echo "Anamorphic / SD: stored SAR is honored. 720x480 with no SAR"
  echo "can be treated as 4:3 or 16:9. An extra optical unsqueeze"
  echo "applies only to those 720-wide SD frames."
  echo

  load_config
  memory_prune
  if [[ -f "$CONFIG_FILE" ]]; then
    echo "Loaded last-run settings from $CONFIG_FILE"
    echo
  fi
  if [[ -f "$MEMORY_FILE" ]]; then
    echo "Memory file: $MEMORY_FILE (gone files already dropped)"
  fi

  PROGRAM_FOLDERS=("${PROGRAM_FOLDERS[@]+"${PROGRAM_FOLDERS[@]}"}")
  if ((${#PROGRAM_FOLDERS[@]})); then
    echo "Last program folders:"
    printf '  - %s\n' "${PROGRAM_FOLDERS[@]}"
    if ! prompt_yn "Reuse these program folders?" y; then
      PROGRAM_FOLDERS=()
    fi
  fi
  if ((${#PROGRAM_FOLDERS[@]} == 0)); then
    if ! choose_program_folders; then
      echo "No program folders given." >&2
      exit 1
    fi
  fi
  if ((${#PROGRAM_FOLDERS[@]} == 0)); then
    echo "No program folders given." >&2
    exit 1
  fi
  echo
  echo "Using ${#PROGRAM_FOLDERS[@]} program folder(s):"
  printf '  - %s\n' "${PROGRAM_FOLDERS[@]}"
  if prompt_yn "Save this list as $FOLDER_LIST_FILE?" y; then
    save_folder_list_file
  fi

  echo
  echo "Insert libraries (leave a prompt blank to disable that type):"
  ID_FOLDER="$(ask_folder "IDs folder" "${ID_FOLDER:-}")"
  BUMP_OUT_FOLDER="$(ask_folder "Bump-OUT folder (we'll be right back)" "${BUMP_OUT_FOLDER:-}")"
  COMM_FOLDER="$(ask_folder "Commercials folder" "${COMM_FOLDER:-}")"
  BUMP_IN_FOLDER="$(ask_folder "Bump-IN folder (welcome back)" "${BUMP_IN_FOLDER:-}")"
  SIGNOFF_FOLDER="$(ask_folder "Sign-off / end-of-day folder" "${SIGNOFF_FOLDER:-}")"

  echo
  echo "How should program clips be chosen?"
  echo "  1) Random N clips"
  echo "  2) All clips, shuffled"
  echo "  3) All clips, filename order"
  echo "  4) Load a text file of paths (one per line)"
  MODE="$(prompt "Choice" "${MODE:-1}")"

  mapfile -t ALL_PROGRAMS < <(
    for d in "${PROGRAM_FOLDERS[@]}"; do
      collect_videos "$d"
    done
  )
  if ((${#ALL_PROGRAMS[@]} == 0)) && [[ "$MODE" != 4 ]]; then
    echo "No program videos found." >&2
    exit 1
  fi
  if [[ "$MODE" != 4 ]]; then
    print_folder_inventory
    echo "  total ${#ALL_PROGRAMS[@]} file(s) on disk"
    mapfile -t ALL_PROGRAMS < <(filter_unused PROGRAM "${ALL_PROGRAMS[@]+"${ALL_PROGRAMS[@]}"}")
    echo "  unused ${#ALL_PROGRAMS[@]} after memory filter"
    if ((${#ALL_PROGRAMS[@]} == 0)); then
      echo
      echo "Every existing program file in these folders is already in memory."
      if prompt_yn "Clear program memory and start the library over?" y; then
        memory_clear_kind PROGRAM
        mapfile -t ALL_PROGRAMS < <(
          for d in "${PROGRAM_FOLDERS[@]}"; do
            collect_videos "$d"
          done
        )
        echo "Program memory cleared. Pool is ${#ALL_PROGRAMS[@]} file(s)."
      else
        echo "Nothing left to pick." >&2
        exit 1
      fi
    fi
  fi

  PROGRAMS=()
  case "$MODE" in
    2)
      mapfile -t PROGRAMS < <(printf '%s\n' "${ALL_PROGRAMS[@]}" | shuf)
      spread_apart_by_folder
      ;;
    3)
      PROGRAMS=("${ALL_PROGRAMS[@]}")
      ;;
    4)
      local list
      list="$(prompt "Path to program list file" "${PROGRAM_LIST:-programs.txt}")"
      mapfile -t PROGRAMS < <(grep -v '^\s*$' "$list" | grep -v '^\s*#')
      ;;
    *)
      MODE=1
      COUNT="$(prompt "How many program clips" "${COUNT:-10}")"
      if (( COUNT > ${#ALL_PROGRAMS[@]} )); then
        echo "Only ${#ALL_PROGRAMS[@]} unused available; using all of them."
        COUNT=${#ALL_PROGRAMS[@]}
      fi
      pick_balanced "$COUNT" "${ALL_PROGRAMS[@]}"
      ;;
  esac

  mapfile -t IDS       < <(collect_videos "${ID_FOLDER:-}")
  mapfile -t BUMPS_OUT < <(collect_videos "${BUMP_OUT_FOLDER:-}")
  mapfile -t COMMS     < <(collect_videos "${COMM_FOLDER:-}")
  mapfile -t BUMPS_IN  < <(collect_videos "${BUMP_IN_FOLDER:-}")
  mapfile -t SIGNOFFS  < <(collect_videos "${SIGNOFF_FOLDER:-}")
  if ((${#SIGNOFFS[@]} > 0)); then
    local _so_all=("${SIGNOFFS[@]}")
    mapfile -t SIGNOFFS < <(filter_unused SIGNOFF "${_so_all[@]}")
    if ((${#SIGNOFFS[@]} == 0)); then
      echo "All sign-off files have aired. Starting that folder over."
      memory_clear_kind SIGNOFF
      SIGNOFFS=("${_so_all[@]}")
    fi
  fi

  list_library "IDs" "${IDS[@]+"${IDS[@]}"}"
  list_library "Bump-OUT" "${BUMPS_OUT[@]+"${BUMPS_OUT[@]}"}"
  list_library "Commercials" "${COMMS[@]+"${COMMS[@]}"}"
  list_library "Bump-IN" "${BUMPS_IN[@]+"${BUMPS_IN[@]}"}"
  list_library "Sign-off" "${SIGNOFFS[@]+"${SIGNOFFS[@]}"}"

  echo
  echo "Break pattern:"
  echo "  After every N program clips, air one pod:"
  echo "  bump-out -> K commercials -> bump-in"
  BREAK_EVERY="$(prompt "N  (break after every N programs)" "${BREAK_EVERY:-1}")"
  COMMS_PER_BREAK="$(prompt "K  (commercials per pod)" "${COMMS_PER_BREAK:-2}")"

  if prompt_yn "Open with a station ID?" "${OPEN_WITH_ID:-y}"; then
    OPEN_WITH_ID=y
  else
    OPEN_WITH_ID=n
  fi
  if prompt_yn "Close with a station ID?" "${CLOSE_WITH_ID:-y}"; then
    CLOSE_WITH_ID=y
  else
    CLOSE_WITH_ID=n
  fi
  if ((${#SIGNOFFS[@]} > 0)); then
    echo
    echo "Sign-off pick (exactly one, always last after the close ID):"
    echo "  random  different closer each run"
    echo "  first   first file in filename order every run"
    SIGNOFF_MODE="$(prompt "Sign-off mode" "${SIGNOFF_MODE:-random}")"
  fi
  if prompt_yn "Also fire an ID when runtime crosses each hour?" "${HOUR_ID:-n}"; then
    HOUR_ID=y
    HOUR_SECONDS="$(prompt "Seconds per 'hour'" "${HOUR_SECONDS:-3600}")"
  else
    HOUR_ID=n
    HOUR_SECONDS="${HOUR_SECONDS:-3600}"
  fi

  if prompt_yn "Loop IDs when the list is exhausted?" "${LOOP_IDS:-y}"; then
    LOOP_IDS=y
  else
    LOOP_IDS=n
  fi
  if prompt_yn "Loop bump-OUT when the list is exhausted?" "${LOOP_BUMP_OUT:-y}"; then
    LOOP_BUMP_OUT=y
  else
    LOOP_BUMP_OUT=n
  fi
  if prompt_yn "Loop bump-IN when the list is exhausted?" "${LOOP_BUMP_IN:-y}"; then
    LOOP_BUMP_IN=y
  else
    LOOP_BUMP_IN=n
  fi
  if prompt_yn "Loop commercials when the list is exhausted?" "${LOOP_COMMS:-y}"; then
    LOOP_COMMS=y
  else
    LOOP_COMMS=n
  fi

  echo
  echo "720x480 / 720x576 with square or missing SAR:"
  echo "  square  keep 3:2 pixels (old v3 behavior)"
  echo "  4:3     NTSC/PAL fullscreen"
  echo "  16:9    camcorder widescreen / anamorphic flag missing"
  SD480_ASSUME="$(prompt "SD assume" "${SD480_ASSUME:-square}")"
  echo
  echo "Optical unsqueeze (horizontal) for 720-wide SD only."
  echo "Use 1 if the file SAR or the assume setting already looks right."
  echo "  1      none"
  echo "  1.333  1.33x adapter on a 4:3 camera"
  echo "  2      2x anamorphic lens"
  OPTICAL_UNSQUEEZE="$(prompt "Optical unsqueeze" "${OPTICAL_UNSQUEEZE:-1}")"

  FADE="$(prompt "Fade seconds on each segment (0 = hard cut)" "${FADE:-0}")"
  OUTPUT="$(prompt "Output filename" "${OUTPUT:-broadcast.mp4}")"
  echo
  echo "What should this machine do?"
  echo "  stage   copy numbered files + playlists + HandBrake/stitch scripts (no encode here)"
  echo "  encode  encode on this Linux box as v8 did"
  echo "  both    stage pack and encode here"
  OUTPUT_MODE="$(prompt "Output mode" "${OUTPUT_MODE:-stage}")"
  if [[ "$OUTPUT_MODE" == stage || "$OUTPUT_MODE" == both ]]; then
    STAGE_DIR="$(prompt "Stage folder" "${STAGE_DIR:-./broadcast_pack}")"
  fi

  build_rundown
  print_rundown

  if ! prompt_yn "Write rundown, update memory, and continue?" y; then
    echo "Aborted. Settings and memory not updated."
    exit 0
  fi

  {
    echo "# broadcast rundown  $(date)"
    echo "# assembler v${VERSION}"
    echo "# output: $OUTPUT"
    echo "# break: every ${BREAK_EVERY} program(s), ${COMMS_PER_BREAK} commercial(s) per pod"
    echo "# pod: bump-out -> commercials -> bump-in"
    echo "# signoff: ${SIGNOFF_MODE:-none}  folder=${SIGNOFF_FOLDER:-}"
    echo "# sd480_assume=${SD480_ASSUME}  optical=${OPTICAL_UNSQUEEZE}"
    for entry in "${RUNDOWN[@]}"; do
      printf '%s\t%s\n' "${entry%%|*}" "${entry#*|}"
    done
  } > rundown.txt
  echo "Wrote rundown.txt"

  remember_rundown
  echo "Updated $MEMORY_FILE (PROGRAM and SIGNOFF paths from this rundown)"
  save_config
}

write_stage_pack() {
  local pack srcs enc i=0 entry kind src base dest slug
  pack="${STAGE_DIR}"
  srcs="$pack/sources"
  enc="$pack/encoded"
  mkdir -p "$srcs" "$enc"

  : > "$pack/playlist_sources.m3u"
  : > "$pack/playlist_encoded.m3u"
  : > "$pack/concat.txt"
  printf '#EXTM3U\n' > "$pack/playlist_sources.m3u"
  printf '#EXTM3U\n' > "$pack/playlist_encoded.m3u"

  echo
  echo "Staging ${#RUNDOWN[@]} file(s) into $pack ..."
  for entry in "${RUNDOWN[@]}"; do
    kind="${entry%%|*}"
    src="${entry#*|}"
    if [[ ! -f "$src" ]]; then
      echo "  skip missing: $src"
      continue
    fi
    i=$((i + 1))
    base="$(basename "$src")"
    slug="$(printf '%03d_%s' "$i" "$(stage_slug "$kind" "$base")")"
    dest="$srcs/$slug"
    cp -f -- "$src" "$dest"
    printf '  [%s] %s\n' "$kind" "$slug"
    printf '#EXTINF:-1,%s %s\n%s\n' "$kind" "$base" "sources/${slug}" >> "$pack/playlist_sources.m3u"
    printf '#EXTINF:-1,%s %s\n%s\n' "$kind" "${slug%.*}.mp4" "encoded/${slug%.*}.mp4" >> "$pack/playlist_encoded.m3u"
    printf "file 'encoded/%s.mp4'\n" "${slug%.*}" >> "$pack/concat.txt"
  done

  cp -f rundown.txt "$pack/rundown.txt"

  cat > "$pack/encode.sh" <<'EOS'
#!/usr/bin/env bash
# Run on the Mac (or any machine with HandBrakeCLI).
# Reads sources/ and writes encoded/*.mp4 with identical settings
# so ffmpeg -c copy can stitch them afterward.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
command -v HandBrakeCLI >/dev/null || {
  echo "HandBrakeCLI not on PATH. Install the official CLI zip or MacPorts HandBrakeCLI." >&2
  exit 1
}
ENC="vt_h264"
if ! HandBrakeCLI --help 2>&1 | grep -q 'vt_h264'; then
  ENC="x264"
  echo "vt_h264 not available; using x264"
fi
mkdir -p encoded
shopt -s nullglob
for src in sources/*; do
  [[ -f "$src" ]] || continue
  base="$(basename "$src")"
  stem="${base%.*}"
  out="encoded/${stem}.mp4"
  echo "=== $base -> $out ($ENC) ==="
  HandBrakeCLI -i "$src" -o "$out" \
    --format av_mp4 \
    --optimize \
    --encoder "$ENC" \
    --quality 35 \
    --cfr --rate 30 \
    --width 1920 --height 1080 \
    --crop 0:0:0:0 \
    --loose-anamorphic \
    --keep-display-aspect \
    --pad "width=1920:height=1080:color=black" \
    --aencoder av_aac --ab 128 --mixdown stereo --arate 48
done
echo "HandBrake pass done. Next: bash stitch.sh"
EOS

  cat > "$pack/stitch.sh" <<'EOS'
#!/usr/bin/env bash
# Lossless join of encoded/*.mp4 in rundown order.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
command -v ffmpeg >/dev/null || { echo "ffmpeg is required for stitch.sh" >&2; exit 1; }
[[ -s concat.txt ]] || { echo "concat.txt missing or empty" >&2; exit 1; }
ffmpeg -hide_banner -y -f concat -safe 0 -i concat.txt -c copy -movflags +faststart broadcast.mp4
echo "Done -> $DIR/broadcast.mp4"
EOS

  chmod +x "$pack/encode.sh" "$pack/stitch.sh"
  echo
  echo "Stage pack ready: $pack"
  echo "  playlist_sources.m3u  VLC/mpv of the copies (relative paths)"
  echo "  encode.sh             HandBrakeCLI batch -> encoded/"
  echo "  stitch.sh             ffmpeg -c copy -> broadcast.mp4"
}

encode_rundown() {
  local concat i=0 entry kind src clip
  BROADCAST_TMP="$(mktemp -d /tmp/broadcast.XXXXXX)"
  concat="$BROADCAST_TMP/concat_list.txt"
  : > "$concat"

  echo
  echo "Normalizing ${#RUNDOWN[@]} segment(s) to ${WIDTH}x${HEIGHT} @ ${FPS}fps..."
  for entry in "${RUNDOWN[@]}"; do
    kind="${entry%%|*}"
    src="${entry#*|}"
    clip="$(printf '%s/seg_%03d.mp4' "$BROADCAST_TMP" "$i")"
    printf '  [%s] %s\n' "$kind" "$(basename "$src")"
    normalize_clip "$src" "$clip"
    printf "file '%s'\n" "$clip" >> "$concat"
    i=$((i+1))
  done

  echo "Concatenating..."
  ffmpeg -hide_banner -loglevel error -y \
    -f concat -safe 0 -i "$concat" \
    -c copy \
    -movflags +faststart \
    "$OUTPUT"

  echo
  ffprobe -hide_banner "$OUTPUT"
  echo
  echo "Done -> $OUTPUT"
}

need_bins
interactive
case "${OUTPUT_MODE}" in
  encode)
    encode_rundown
    ;;
  both)
    write_stage_pack
    encode_rundown
    ;;
  *)
    write_stage_pack
    ;;
esac
