#!/usr/bin/env bash
# Stage beside the destination and publish only after structural validation.
set -Eeuo pipefail
export LC_ALL=C

usage() {
  cat <<'HELP'
Usage:
  disc-rip-safe.sh [options]
  disc-rip-safe.sh --local [--type movies|television] [options]
  disc-rip-safe.sh --server jellyfin|synology4|plexmedia [--type movies|television] [options]

Defaults: Jellyfin destination and movies type.
Choose --local or --server to override the destination.
Valid commands start immediately. No arguments shows this documentation.

Destinations:
  --local               ~/Videos/Movies/NAME or Television/NAME (created if needed)
  --server jellyfin     /mnt/jellyfin/Movies/NAME or Television/NAME (default)
  --server synology4    /mnt/synvideo/Movies/NAME or Television/NAME
  --server plexmedia    /mnt/plexmedia/Movies/NAME or Television/NAME
Server roots must already be mounted and writable.

Options:
  --type TYPE           movies (default) or television
  --name NAME           Disc folder name (default: disc label or timestamp)
  --drive DEVICE        Optical drive (default: /dev/sr0)
  --minlength SECONDS   Minimum title length: movies 1200, television 300
  --wait SECONDS        Media readiness budget (default: 300; 0: one scan)
                        With 0, the single scan has a 300-second timeout.
  --min-free-gb GB      Starting free-space threshold (default: 20 GiB)
  --no-eject            Leave disc inserted after success
  -h, --help            Show documentation

The script scans with MakeMKV, rips all eligible titles, checks each MKV for
video and positive duration, then moves the folder into the destination.
Checks are structural, not a full decode or proof every disc title was saved.
The free-space threshold is not an estimate of disc size.

Existing folders are never overwritten. Failed/interrupted rips remain in
DESTINATION_ROOT/.disc-rip-staging/ with a recovery.txt record and run.log.
Successful staging is removed; logs remain in DESTINATION_ROOT/.disc-rip-logs/.
Published folders allow traversal/read access; server ACLs still apply.
Use another --name for a new attempt. Television episodes need identification
and renaming for Jellyfin; use distinct folder names for multiple discs.

Examples:
  disc-rip-safe.sh --type movies --name 'Alien (1979)'
  disc-rip-safe.sh --local --type movies --name 'Alien (1979)'
  disc-rip-safe.sh --server jellyfin --type television --name 'Show Disc 1'
HELP
}

LOG='' STAGE='' FINAL='' FAILURE='' PHASE=starting PUBLISHED=0
SERVER='' TYPE=movies NAME='' DRIVE=/dev/sr0
MIN_LENGTH='' WAIT_SECONDS=300 MIN_FREE_GB=20 DO_EJECT=1

die() { FAILURE=$*; printf 'Error: %s\n' "$*" >&2; exit 1; }
arg_error() { printf 'Error: %s\n\n' "$*" >&2; usage >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

parse_args() {
  if (($# == 0)); then usage; exit 0; fi
  while (($#)); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --local)
        [[ -z "$SERVER" ]] || arg_error 'Choose exactly one destination'
        SERVER=local; shift ;;
      --server|--type|--name|--drive|--minlength|--wait|--min-free-gb)
        (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || arg_error "Missing value for $1"
        case "$1" in
          --server)
            [[ -z "$SERVER" ]] || arg_error 'Choose exactly one destination'
            case "${2,,}" in jellyfin|synology4|plexmedia) SERVER=${2,,} ;; *) arg_error "Unknown server: $2" ;; esac ;;
          --type) TYPE=${2,,} ;;
          --name) NAME=$2 ;;
          --drive) DRIVE=$2 ;;
          --minlength) MIN_LENGTH=$2 ;;
          --wait) WAIT_SECONDS=$2 ;;
          --min-free-gb) MIN_FREE_GB=$2 ;;
        esac
        shift 2 ;;
      --no-eject) DO_EJECT=0; shift ;;
      *) arg_error "Unexpected argument: $1" ;;
    esac
  done
  SERVER=${SERVER:-jellyfin}
  case "$TYPE" in
    movies) LIBRARY=Movies; MIN_LENGTH=${MIN_LENGTH:-1200} ;;
    television) LIBRARY=Television; MIN_LENGTH=${MIN_LENGTH:-300} ;;
    *) arg_error "Unknown type: $TYPE" ;;
  esac
  local value
  for value in "$MIN_LENGTH" "$WAIT_SECONDS" "$MIN_FREE_GB"; do
    [[ "$value" =~ ^(0|[1-9][0-9]{0,6})$ ]] || arg_error 'Numeric options must be whole numbers from 0 to 9999999'
  done
  [[ -z "$NAME" ]] || validate_name "$NAME"
}

validate_name() {
  [[ -n "$1" && "$1" != .* && "$1" != */* && ! "$1" =~ [[:cntrl:]] ]] ||
    arg_error "Folder name must be nonempty, not start with '.', and contain no slash or control characters"
}

check_requirements() {
  local cmd
  for cmd in makemkvcon ffprobe blkid flock mountpoint readlink stat df awk \
             mktemp mkdir mv rmdir rm chmod cp cat tee date tr sleep timeout; do need "$cmd"; done
  if ((DO_EJECT)); then need eject; fi
}

check_root() {
  if [[ "$SERVER" != local ]]; then
    mountpoint -q -- "$ROOT" || die "Server root is not mounted: $ROOT"
  fi
  [[ -d "$ROOT" && -w "$ROOT" && -x "$ROOT" ]] || die "Destination root is not a writable directory: $ROOT"
}

resolve_destination() {
  case "$SERVER" in
    local) ROOT="$HOME/Videos"; mkdir -p -- "$ROOT"; DEST_DIR="$ROOT/$LIBRARY" ;;
    jellyfin) ROOT=/mnt/jellyfin; DEST_DIR="$ROOT/$LIBRARY" ;;
    synology4) ROOT=/mnt/synvideo; DEST_DIR="$ROOT/$LIBRARY" ;;
    plexmedia) ROOT=/mnt/plexmedia; DEST_DIR="$ROOT/$LIBRARY" ;;
  esac
  check_root
  if [[ -n "$NAME" ]]; then
    FINAL="$DEST_DIR/$NAME"
    [[ ! -e "$FINAL" && ! -L "$FINAL" ]] || die "Destination already exists: $FINAL"
  fi
  mkdir -p -- "$DEST_DIR" "$ROOT/.disc-rip-staging" "$ROOT/.disc-rip-logs"
  [[ "$(stat -Lc %d -- "$ROOT/.disc-rip-staging")" == "$(stat -Lc %d -- "$DEST_DIR")" ]] ||
    die 'Staging and destination must be on the same filesystem'
  local available_kb
  available_kb=$(df -Pk -- "$ROOT/.disc-rip-staging" | awk 'NR==2 {print $4}')
  [[ "$available_kb" =~ ^[0-9]+$ ]] || die 'Cannot determine free space'
  ((available_kb >= MIN_FREE_GB * 1024 * 1024)) || die "Less than $MIN_FREE_GB GiB free on $ROOT"
}

lock_drive() {
  local lock_dir lock_name
  lock_dir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/disc-rip-safe-$UID"
  if ! mkdir -m 700 -- "$lock_dir" 2>/dev/null; then
    [[ -d "$lock_dir" && ! -L "$lock_dir" && -O "$lock_dir" ]] || die "Unsafe lock directory: $lock_dir"
    [[ "$(stat -c %a -- "$lock_dir")" == 700 ]] || die "Lock directory must have permissions 700: $lock_dir"
  fi
  DRIVE=$(readlink -m -- "$DRIVE")
  lock_name=${DRIVE//\//_}
  exec {drive_lock}>"$lock_dir/$lock_name.lock"
  flock -n "$drive_lock" || die "Another rip is already using $DRIVE"
}

write_record() {
  {
    printf 'Updated: %s\nPhase: %s\nDisc: %s\nDrive: %s\nType: %s\n' "$(date -Is)" "$PHASE" "${NAME:-not yet identified}" "$DRIVE" "$TYPE"
    printf 'Destination: %s\nMinimum title length: %s seconds\nLog: %s\n' "${FINAL:-$DEST_DIR/<disc label>}" "$MIN_LENGTH" "$LOG"
    printf 'Failure: %s\n' "${FAILURE:-none recorded}"
    printf 'Keep this folder until reviewed. media/ contains any ripped files.\n'
    printf 'No automatic resume: inspect run.log before retrying with a new --name.\n'
  } >"$STAGE/recovery.txt"
}

cleanup() {
  local status=$?
  trap - EXIT
  # Reporting must not hide the original outcome when storage is unavailable.
  set +e
  if ((status != 0)); then
    FAILURE=${FAILURE:-"Command failed or interrupted during $PHASE (exit $status)"}
    printf 'Error: %s\n' "$FAILURE" >>"$LOG"
  fi
  if [[ -n "$STAGE" && -d "$STAGE" ]]; then
    write_record
    cp -- "$LOG" "$STAGE/run.log"
    printf 'Recovery files retained: %s\n' "$STAGE" >&2
  fi
  if ((PUBLISHED)); then
    if ((status != 0)); then printf 'Media was published successfully: %s\nFollow-up failed: %s\n' "$FINAL" "$FAILURE" >&2; fi
  elif ((status != 0)); then
    printf 'Rip was not published; disc was not ejected.\n' >&2
  fi
  printf 'Log: %s\n' "$LOG"
  exit "$status"
}

prepare_run() {
  LOG=$(mktemp "$ROOT/.disc-rip-logs/$(date +%Y%m%d_%H%M%S).XXXXXX.log")
  trap cleanup EXIT
  trap 'FAILURE="Interrupted by user"; exit 130' INT
  trap 'FAILURE="Terminated"; exit 143' TERM
  STAGE=$(mktemp -d "$ROOT/.disc-rip-staging/rip.XXXXXX")
  # Keep the private record in staging while retaining one permanent log.
  # run.log is a copy made during cleanup, rather than a cross-filesystem link.
  mkdir -- "$STAGE/media"
  PHASE=waiting
  write_record
  printf 'Disc ripper: %s; output %s/%s\nMinimum title length: %ss; starting free-space threshold: %s GiB\nFailed rips are retained. Ctrl+C cancels; --help shows documentation.\n' \
    "$TYPE" "$DEST_DIR" "${NAME:-<disc label>}" "$MIN_LENGTH" "$MIN_FREE_GB" | tee -a "$LOG"
}

wait_for_media() {
  local deadline=$((SECONDS + WAIT_SECONDS)) budget count
  printf 'Checking disc readiness with MakeMKV in %s...\n' "$DRIVE" | tee -a "$LOG"
  while :; do
    budget=$((deadline - SECONDS))
    # Disc analysis can take minutes; do not repeatedly kill a healthy scan.
    if ((WAIT_SECONDS == 0)); then budget=300; fi
    ((budget > 0)) || budget=1
    if timeout --kill-after=2s "${budget}s" makemkvcon -r --cache=16 \
        "--minlength=$MIN_LENGTH" info "dev:$DRIVE" >"$STAGE/scan.txt" 2>&1; then
      count=$(awk -F: '/^(TCOUNT|TCOUT):[0-9]+\r?$/ {gsub(/\r/,"",$2); n=$2} END {print n+0}' "$STAGE/scan.txt")
      if ((count > 0)); then
        cat "$STAGE/scan.txt" >>"$LOG"
        break
      fi
    fi
    cat "$STAGE/scan.txt" >>"$LOG"
    ((SECONDS < deadline)) || die 'MakeMKV could not find readable eligible titles before the readiness timeout; see the log'
    sleep 1
  done
  if [[ -z "$NAME" ]]; then
    NAME=$(blkid -p -o value -s LABEL "$DRIVE" 2>/dev/null | tr -cd '[:alnum:]._-') || true
    NAME=${NAME:-Unknown_Disc_$(date +%Y%m%d_%H%M%S)}
    # Disc labels are external data; replace unsuitable labels with a timestamp.
    if [[ "$NAME" == .* ]]; then NAME=Unknown_Disc_$(date +%Y%m%d_%H%M%S); fi
  fi
  validate_name "$NAME"
  FINAL="$DEST_DIR/$NAME"
  [[ ! -e "$FINAL" && ! -L "$FINAL" ]] || die "Destination already exists: $FINAL"
}

rip_disc() {
  PHASE=ripping; write_record
  check_root
  printf 'Ripping to staging for: %s\n' "$FINAL" | tee -a "$LOG"
  if ! makemkvcon "--minlength=$MIN_LENGTH" --progress=-stdout \
      mkv "dev:$DRIVE" all "$STAGE/media" 2>&1 | tee -a "$LOG"; then
    die 'MakeMKV failed'
  fi
}

verify_outputs() {
  PHASE=verifying; write_record
  shopt -s nullglob
  files=("$STAGE/media/"*.mkv)
  ((${#files[@]})) || die 'MakeMKV produced no MKV files'
  local file
  for file in "${files[@]}"; do
    [[ -s "$file" ]] || die "Empty output: $file"
    if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_type \
        -of default=nw=1:nk=1 "$file" 2>>"$LOG" | awk '$0=="video" {ok=1} END {exit !ok}'; then die "No readable video: $file"; fi
    if ! ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 \
        "$file" 2>>"$LOG" | awk '$0 ~ /^[0-9]+([.][0-9]+)?$/ && $0+0>0 {ok=1} END {exit !ok}'; then die "Invalid duration: $file"; fi
    chmod a+r -- "$file"
  done
  chmod a+rx -- "$STAGE/media"
}

publish_rip() {
  PHASE=publishing; write_record
  check_root
  [[ ! -e "$FINAL" && ! -L "$FINAL" ]] || die "Destination appeared during ripping: $FINAL"
  [[ "$(stat -Lc %d -- "$STAGE/media")" == "$(stat -Lc %d -- "$DEST_DIR")" ]] || die 'Destination filesystem changed'
  mv -T -n -- "$STAGE/media" "$FINAL"
  [[ ! -d "$STAGE/media" ]] || die 'Destination was not published'
  PUBLISHED=1
  PHASE=published; write_record
  printf 'Published: %s (%s MKV files passed video/duration checks).\nChecks do not prove every disc title was saved or fully decoded.\n' "$FINAL" "${#files[@]}" | tee -a "$LOG"
  # Remove only known bookkeeping files; unexpected files preserve the folder.
  rm -f -- "$STAGE/recovery.txt" "$STAGE/scan.txt"
  rmdir -- "$STAGE"
  STAGE=''
}

eject_disc() {
  if ((DO_EJECT)); then
    PHASE=ejecting
    if ! eject "$DRIVE" 2>&1 | tee -a "$LOG"; then die 'Eject failed'; fi
  fi
  PHASE=complete
}

main() {
  parse_args "$@"
  check_requirements
  resolve_destination
  lock_drive
  prepare_run
  wait_for_media
  rip_disc
  verify_outputs
  publish_rip
  eject_disc
}
main "$@"
