#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# -------------------- Defaults --------------------
AAC_BR="${AAC_BR:-192k}"
AC3_BR="${AC3_BR:-640k}"

QP_H264="${QP_H264:-20}"
QP_HEVC="${QP_HEVC:-22}"

VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"
LIBVA_DRIVER_NAME="${LIBVA_DRIVER_NAME:-radeonsi}"

SCRATCH_DIR="${SCRATCH_DIR:-/var/tmp/jellyfin-transcode-$USER}"
KEEP_SCRATCH="${KEEP_SCRATCH:-0}"
DRYRUN="${DRYRUN:-0}"
FORCE="${FORCE:-0}"

SKIP_COMPAT="${SKIP_COMPAT:-1}"     # skip already AppleTV compatible MP4/MOV
REMUX_COMPAT="${REMUX_COMPAT:-1}"   # remux compatible MKV-ish to MP4 quickly
REMUX_ONLY="${REMUX_ONLY:-0}"       # only remux; never encode

MIN_FREE_GB="${MIN_FREE_GB:-20}"    # scratch must have at least this much free
MIN_FREE_PCT="${MIN_FREE_PCT:-5}"   # and at least this percent free

# Subtitle behavior
SUBS_ENABLE="${SUBS_ENABLE:-1}"              # 1=include text subs, 0=omit all subs
SUBS_MAX_TEXT="${SUBS_MAX_TEXT:-6}"          # keep at most N text subtitle tracks
SUBS_LANG_PREFER="${SUBS_LANG_PREFER:-}"     # optional: e.g. "eng" or "en" (best-effort)

# Buffering control
THREAD_QUEUE_SIZE="${THREAD_QUEUE_SIZE:-256}"
FFMPEG_THREADS="${FFMPEG_THREADS:-2}"
EXTRA_HW_FRAMES="${EXTRA_HW_FRAMES:-8}"      # caps VAAPI surface queueing (helps stability)

# Option A: delete source after VERIFIED success (default ON)
DELETE_SOURCE="${DELETE_SOURCE:-1}"          # 1=delete original after verified success
DELETE_EXTS_RE="${DELETE_EXTS_RE:-\.(mkv|avi|mpg|mpeg|ts|m2ts|wmv|mov)$}"  # only delete these source types

# -------------------- Helpers --------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need ffmpeg
need ffprobe
need rsync
need df
need awk
need find
need sed

run() {
  if [[ "$DRYRUN" == "1" ]]; then
    printf 'DRYRUN: '; printf '%q ' "$@"; echo
  else
    "$@"
  fi
}

verify_output_ok() {
  local f="$1"
  ffprobe -v error -show_format -show_streams "$f" >/dev/null 2>&1
}

maybe_delete_source() {
  local in="$1"
  local out_final="$2"

  [[ "$DELETE_SOURCE" == "1" ]] || return 0

  # Only delete certain source extensions (safety net)
  if ! echo "$in" | grep -qiE "$DELETE_EXTS_RE"; then
    echo "Keep source (ext not in delete list): $in"
    return 0
  fi

  # Never delete if input and output resolve to same path (paranoia)
  if [[ "$(readlink -f "$in")" == "$(readlink -f "$out_final")" ]]; then
    echo "WARNING: in==out; refusing to delete source: $in" >&2
    return 0
  fi

  if verify_output_ok "$out_final"; then
    echo "Deleting source (verified): $in"
    run rm -f -- "$in"
  else
    echo "WARNING: Output failed verification; keeping source: $in" >&2
  fi
}

# ---------- ffprobe helpers ----------
video_height() {
  ffprobe -v error -select_streams v:0 -show_entries stream=height \
    -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1 || true
}
container_format() {
  ffprobe -v error -show_entries format=format_name -of default=nw=1:nk=1 \
    "$1" 2>/dev/null | head -n1 || true
}
video_codec0() {
  ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
    -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1 || true
}
audio_codec0() {
  ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
    -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1 || true
}
audio_channels0() {
  ffprobe -v error -select_streams a:0 -show_entries stream=channels \
    -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1 || true
}
audio_codecs_all() {
  ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 \
    "$1" 2>/dev/null || true
}
subtitle_codecs() {
  ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 \
    "$1" 2>/dev/null || true
}

is_text_sub_codec() {
  case "$1" in
    subrip|ass|ssa|mov_text|text|webvtt) return 0 ;;
    *) return 1 ;;
  esac
}

has_problem_audio() {
  audio_codecs_all "$1" | grep -qiE '^(dts|truehd|mlp|opus|vorbis|flac|alac|pcm_.*)$'
}
has_image_subs() {
  subtitle_codecs "$1" | grep -qiE '^(hdmv_pgs_subtitle|pgs|dvd_subtitle|vobsub|xsub|dvd_subtitle)$'
}

# Conservative: skip if already MP4/MOV + (h264/hevc) + (aac/ac3/eac3) and no nasty extras
is_appletv_compatible_skip() {
  local f="$1"
  local fmt vcodec a0
  fmt="$(container_format "$f")"
  vcodec="$(video_codec0 "$f")"
  a0="$(audio_codec0 "$f")"

  echo "$fmt" | grep -qiE '(mp4|mov)' || return 1
  echo "$vcodec" | grep -qiE '^(h264|hevc)$' || return 1
  echo "$a0" | grep -qiE '^(aac|ac3|eac3)$' || return 1

  has_problem_audio "$f" && return 1
  has_image_subs "$f" && return 1
  return 0
}

# Fast-remux eligibility: non-mp4 container + h264 video + acceptable audio present + only text subs
is_mkv_h264_appletv_remuxable() {
  local f="$1"
  local fmt vcodec
  fmt="$(container_format "$f")"
  vcodec="$(video_codec0 "$f")"

  echo "$fmt" | grep -qiE '(mp4|mov)' && return 1
  echo "$vcodec" | grep -qiE '^h264$' || return 1

  has_problem_audio "$f" && return 1
  audio_codecs_all "$f" | grep -qiE '^(aac|ac3|eac3)$' || return 1

  has_image_subs "$f" && return 1

  local sc
  while IFS= read -r sc; do
    [[ -z "$sc" ]] && continue
    is_text_sub_codec "$sc" || return 1
  done < <(subtitle_codecs "$f")

  return 0
}

# ---------- Subtitle args for MP4 (ARRAY-SAFE) ----------
subtitle_args_for_mp4_arr() {
  local f="$1"
  [[ "$SUBS_ENABLE" == "1" ]] || return 0

  mapfile -t rows < <(
    ffprobe -v error -select_streams s \
      -show_entries stream=index,codec_name:stream_tags=language \
      -of csv=p=0 "$f" 2>/dev/null || true
  )
  (( ${#rows[@]} > 0 )) || return 0

  local -a keep_sN=()
  local row codec lang sN=0

  for row in "${rows[@]}"; do
    IFS=',' read -r _idx codec lang <<<"$row"
    lang="${lang:-}"

    if is_text_sub_codec "$codec"; then
      if [[ -n "$SUBS_LANG_PREFER" ]]; then
        if [[ -n "$lang" && "$lang" == "$SUBS_LANG_PREFER"* ]]; then
          keep_sN+=("$sN")
        fi
      else
        keep_sN+=("$sN")
      fi
    fi
    sN=$((sN+1))
  done

  # If pref set but nothing matched, fall back to all text subs
  if [[ -n "$SUBS_LANG_PREFER" && ${#keep_sN[@]} -eq 0 ]]; then
    sN=0
    for row in "${rows[@]}"; do
      IFS=',' read -r _idx codec lang <<<"$row"
      if is_text_sub_codec "$codec"; then
        keep_sN+=("$sN")
      fi
      sN=$((sN+1))
    done
  fi

  (( ${#keep_sN[@]} > 0 )) || return 0

  local kept=0
  for sN in "${keep_sN[@]}"; do
    echo "-map"
    echo "0:s:${sN}"
    kept=$((kept+1))
    (( kept >= SUBS_MAX_TEXT )) && break
  done

  echo "-c:s"
  echo "mov_text"
}

# ---------- Free space guard ----------
check_free_space_or_die() {
  local path="$1"
  local min_gb="$2"
  local min_pct="$3"

  mkdir -p "$path"

  local avail_kb used_pct avail_gb free_pct
  avail_kb="$(df -Pk "$path" | awk 'NR==2 {print $4}')"
  used_pct="$(df -Pk "$path" | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
  avail_gb="$(awk -v kb="$avail_kb" 'BEGIN {printf "%.1f", kb/1024/1024}')"
  free_pct="$(awk -v used="$used_pct" 'BEGIN {printf "%d", 100-used}')"

  if [[ "$DRYRUN" == "1" ]]; then
    echo "DRYRUN: scratch free space at $path: avail=${avail_gb}GB free=${free_pct}% (need >=${min_gb}GB and >=${min_pct}%)"
    return 0
  fi

  awk -v a="$avail_gb" -v mg="$min_gb" 'BEGIN{exit !(a+0 >= mg+0)}' || {
    echo "ERROR: Not enough free space in scratch ($path): available ${avail_gb}GB, need at least ${min_gb}GB" >&2
    exit 1
  }
  awk -v fp="$free_pct" -v mp="$min_pct" 'BEGIN{exit !(fp+0 >= mp+0)}' || {
    echo "ERROR: Not enough free percent in scratch ($path): free ${free_pct}%, need at least ${min_pct}%" >&2
    exit 1
  }
}

# ---------- CIFS-safe finalize ----------
finalize_to_dest() {
  local src_local="$1"
  local dest_final="$2"

  local dest_dir dest_base dest_tmp
  dest_dir="$(dirname "$dest_final")"
  dest_base="$(basename "$dest_final")"
  dest_tmp="${dest_dir}/${dest_base}.copying.$$"

  if [[ "$DRYRUN" == "1" ]]; then
    echo "DRYRUN: rsync local -> $dest_tmp then rename -> $dest_final"
    return 0
  fi

  rsync -a --no-owner --no-group --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r \
    "$src_local" "$dest_tmp"

  mv -f "$dest_tmp" "$dest_final"
}

scratch_tmp_mp4() {
  local out_final="$1"
  local base
  base="$(basename "$out_final")"
  echo "${SCRATCH_DIR}/.${base}.tmp.$$_.mp4"
}
scratch_done_mp4() {
  local out_final="$1"
  local base
  base="$(basename "$out_final")"
  echo "${SCRATCH_DIR}/${base}.$$"
}

# ---------- Fast remux ----------
remux_to_mp4() {
  local in="$1"
  local out_final="$2"

  run mkdir -p "$SCRATCH_DIR"
  check_free_space_or_die "$SCRATCH_DIR" "$MIN_FREE_GB" "$MIN_FREE_PCT"

  local scratch_tmp scratch_done
  scratch_tmp="$(scratch_tmp_mp4 "$out_final")"
  scratch_done="$(scratch_done_mp4 "$out_final")"

  local -a subarr=()
  mapfile -t subarr < <(subtitle_args_for_mp4_arr "$in")

  local cmd=(ffmpeg -hide_banner -nostdin -y
    -thread_queue_size "$THREAD_QUEUE_SIZE"
    -threads "$FFMPEG_THREADS"
    -i "$in"
    -map 0:v:0
    -map 0:a
  )

  if (( ${#subarr[@]} > 0 )); then
    cmd+=("${subarr[@]}")
  fi

  cmd+=(
    -c:v copy
    -c:a copy
    -map_metadata 0 -map_chapters 0
    -movflags +faststart
    -f mp4
    "$scratch_tmp"
  )

  echo "Remux : $in"
  echo "Final : $out_final"
  echo "Scratch: $SCRATCH_DIR"
  echo

  run "${cmd[@]}"

  if [[ "$DRYRUN" != "1" ]]; then
    mv -f "$scratch_tmp" "$scratch_done"
  fi

  finalize_to_dest "$scratch_done" "$out_final"
  maybe_delete_source "$in" "$out_final"

  if [[ "$DRYRUN" != "1" && "$KEEP_SCRATCH" != "1" ]]; then
    rm -f "$scratch_done" 2>/dev/null || true
  fi
}

# ---------- Encode (VAAPI) ----------
encode_to_mp4() {
  local in="$1"
  local out_final="$2"

  run mkdir -p "$SCRATCH_DIR"
  check_free_space_or_die "$SCRATCH_DIR" "$MIN_FREE_GB" "$MIN_FREE_PCT"

  local h
  h="$(video_height "$in")"
  [[ -n "$h" ]] || { echo "No video stream found, skipping: $in" >&2; return 0; }

  local target_vcodec target_qp
  if [[ "$h" -ge 2160 ]]; then
    target_vcodec="hevc_vaapi"
    target_qp="$QP_HEVC"
  else
    target_vcodec="h264_vaapi"
    target_qp="$QP_H264"
  fi

  local acodec ach surround
  acodec="$(audio_codec0 "$in")"
  ach="$(audio_channels0 "$in")"
  surround=0
  [[ -n "$ach" && "$ach" -ge 6 ]] && surround=1

  local audio_maps=() audio_codecs=() audio_meta=()

  if [[ "$surround" -eq 1 ]]; then
    case "$acodec" in
      ac3|eac3)
        audio_maps+=(-map 0:a:0)
        audio_codecs+=(-c:a:0 copy)
        audio_meta+=(-metadata:s:a:0 title="Surround (passthrough)")
        ;;
      *)
        audio_maps+=(-map 0:a:0)
        audio_codecs+=(-c:a:0 ac3 -b:a:0 "$AC3_BR")
        audio_meta+=(-metadata:s:a:0 title="Surround (AC3)")
        ;;
    esac
    audio_maps+=(-map 0:a:0)
    audio_codecs+=(-c:a:1 aac -ac:a:1 2 -b:a:1 "$AAC_BR")
    audio_meta+=(-metadata:s:a:1 title="Stereo (AAC)")
  else
    case "$acodec" in
      aac)
        audio_maps+=(-map 0:a:0)
        audio_codecs+=(-c:a:0 copy)
        audio_meta+=(-metadata:s:a:0 title="Stereo (AAC passthrough)")
        ;;
      ac3|eac3)
        audio_maps+=(-map 0:a:0)
        audio_codecs+=(-c:a:0 copy)
        audio_meta+=(-metadata:s:a:0 title="Audio (passthrough)")
        audio_maps+=(-map 0:a:0)
        audio_codecs+=(-c:a:1 aac -ac:a:1 2 -b:a:1 "$AAC_BR")
        audio_meta+=(-metadata:s:a:1 title="Stereo (AAC)")
        ;;
      *)
        audio_maps+=(-map 0:a:0)
        audio_codecs+=(-c:a:0 aac -ac:a:0 2 -b:a:0 "$AAC_BR")
        audio_meta+=(-metadata:s:a:0 title="Stereo (AAC)")
        ;;
    esac
  fi

  local -a subarr=()
  mapfile -t subarr < <(subtitle_args_for_mp4_arr "$in")

  local scratch_tmp scratch_done
  scratch_tmp="$(scratch_tmp_mp4 "$out_final")"
  scratch_done="$(scratch_done_mp4 "$out_final")"

  local cmd=(ffmpeg -hide_banner -nostdin -y
    -thread_queue_size "$THREAD_QUEUE_SIZE"
    -threads "$FFMPEG_THREADS"
    -init_hw_device vaapi=va:"$VAAPI_DEVICE"
    -filter_hw_device va
    -extra_hw_frames "$EXTRA_HW_FRAMES"
    -hwaccel vaapi
    -hwaccel_device va
    -hwaccel_output_format vaapi
    -i "$in"
    -map 0:v:0
    "${audio_maps[@]}"
  )

  if (( ${#subarr[@]} > 0 )); then
    cmd+=("${subarr[@]}")
  fi

  cmd+=(
    -vf "scale_vaapi=format=nv12"
    -c:v "$target_vcodec" -qp "$target_qp"
    -map_metadata 0 -map_chapters 0
    "${audio_codecs[@]}"
    "${audio_meta[@]}"
    -movflags +faststart
    -f mp4
    "$scratch_tmp"
  )

  echo "Encode: $in"
  echo "Final : $out_final"
  echo "Scratch: $SCRATCH_DIR"
  echo "Video : height=${h} -> ${target_vcodec} (QP=${target_qp})"
  echo "Audio : codec=${acodec:-?} channels=${ach:-?} -> AppleTV layout"
  echo "Buf   : thread_queue_size=${THREAD_QUEUE_SIZE} threads=${FFMPEG_THREADS} extra_hw_frames=${EXTRA_HW_FRAMES}"
  if [[ "$SUBS_ENABLE" == "1" ]]; then
    echo "Subs  : text->mov_text (max ${SUBS_MAX_TEXT}${SUBS_LANG_PREFER:+, prefer ${SUBS_LANG_PREFER}})"
  else
    echo "Subs  : disabled"
  fi
  echo "Delete: ${DELETE_SOURCE} (exts: ${DELETE_EXTS_RE})"
  echo

  run env LIBVA_DRIVER_NAME="$LIBVA_DRIVER_NAME" "${cmd[@]}"

  if [[ "$DRYRUN" != "1" ]]; then
    mv -f "$scratch_tmp" "$scratch_done"
  fi

  finalize_to_dest "$scratch_done" "$out_final"
  maybe_delete_source "$in" "$out_final"

  if [[ "$DRYRUN" != "1" && "$KEEP_SCRATCH" != "1" ]]; then
    rm -f "$scratch_done" 2>/dev/null || true
  fi
}

process_one() {
  local in="$1"
  [[ -f "$in" ]] || { echo "Skip (not a file): $in" >&2; return 0; }

  # Skip macOS AppleDouble "._*" files
  local bn
  bn="$(basename "$in")"
  if [[ "$bn" == ._* ]]; then
    echo "AppleDouble metadata, skipping: $in"
    return 0
  fi

  local dir base out_final
  dir="$(dirname "$in")"
  base="$(basename "$in")"
  base="${base%.*}"
  out_final="${dir}/${base}.appletv.mp4"

  if [[ -e "$out_final" && "$FORCE" != "1" ]]; then
    echo "Exists, skipping: $out_final"
    return 0
  fi

  if [[ "$SKIP_COMPAT" == "1" && "$FORCE" != "1" ]]; then
    if is_appletv_compatible_skip "$in"; then
      echo "AppleTV-compatible, skipping: $in"
      return 0
    fi
  fi

  if [[ "$REMUX_COMPAT" == "1" && "$FORCE" != "1" ]]; then
    if is_mkv_h264_appletv_remuxable "$in"; then
      remux_to_mp4 "$in" "$out_final"
      return 0
    fi
  fi

  if [[ "$REMUX_ONLY" == "1" ]]; then
    echo "Not remuxable (REMUX_ONLY=1), skipping: $in"
    return 0
  fi

  encode_to_mp4 "$in" "$out_final"
}

expand_inputs() {
  local p
  for p in "$@"; do
    if [[ -d "$p" ]]; then
      find "$p" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.m4v" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.ts" -o -iname "*.m2ts" \) -print
    else
      echo "$p"
    fi
  done
}

main() {
  (( $# >= 1 )) || { echo "Usage: $0 <file-or-dir> [more...]"; exit 1; }
  while IFS= read -r f; do
    process_one "$f"
  done < <(expand_inputs "$@")
}

main "$@"

