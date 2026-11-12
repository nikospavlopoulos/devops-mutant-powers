#!/usr/bin/env bash
# Strict, resumable batch/transfer job: preflight -> measure -> transfer -> verify -> ownership -> finalize.
# Configured by env (every "CHANGE:" line is a knob). Needs bash >= 4.4. Docs: skills/batch-data-jobs/.
# Exit codes: 0 ok | 1 runtime failure (retriable) | 2 config/preflight error (do not retry) | 128+N signal.
set -Eeuo pipefail
shopt -s inherit_errexit   # $(...) keeps -e
export LC_ALL=C            # dot decimals + byte-order sort; a decimal-comma locale corrupts numeric parsing

# ---------- configuration ----------
JOB_NAME="${JOB_NAME:-transfer}"                         # CHANGE: short id used in logs, markers, notifications
RUN_ID="${RUN_ID:-}"                                     # CHANGE: required; same id = resume from markers, new id = fresh run
TRANSFER_TOOL="${TRANSFER_TOOL:-rclone}"                 # CHANGE: rclone (object/network destination) | rsync (local destination)
SRC_DIR="${SRC_DIR:-/src}"                               # CHANGE: source directory (mount it read-only)
DST="${DST:-}"                                           # CHANGE: rclone "remote:bucket/prefix" or rsync local dir; never embed credentials
STATE_ROOT="${STATE_ROOT:-/scratch/state}"               # CHANGE: on a PVC, never emptyDir (markers + run log must outlive the pod)
ALLOW_EMPTY_SOURCE="${ALLOW_EMPTY_SOURCE:-0}"            # CHANGE: 1 only if an empty source is a legitimate result
RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-8}"                # CHANGE: parallel file transfers (rclone default 4)
RCLONE_CHECKERS="${RCLONE_CHECKERS:-16}"                 # CHANGE: parallel checkers (rclone default 8); raise for many small files
RCLONE_EXTRA_FLAGS="${RCLONE_EXTRA_FLAGS:-}"             # CHANGE: e.g. "--fast-list" (split on spaces; no quoting inside)
RCLONE_CHECK_FLAGS="${RCLONE_CHECK_FLAGS:-}"             # CHANGE: "--download" when source and destination share no hash type
RSYNC_EXTRA_FLAGS="${RSYNC_EXTRA_FLAGS:-}"               # CHANGE: e.g. "--numeric-ids"; never "--no-t" (breaks idempotent re-runs)
VERIFY_CHECKSUM="${VERIFY_CHECKSUM:-0}"                  # CHANGE: 1 = rsync verify compares content checksums (slow, thorough)
CHOWN_TO="${CHOWN_TO:-}"                                 # CHANGE: "uid:gid" after success (rsync only; needs root/CAP_CHOWN); empty = skip
CHOWN_PATH="${CHOWN_PATH:-}"                             # CHANGE: subtree under DST to chown; never the volume root
SUCCESS_MARKER="${SUCCESS_MARKER:-_SUCCESS}"             # CHANGE: marker written at the destination, last
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-60}"             # CHANGE: liveness line interval while a long step runs (0 = off)
HOLD_ON_FAILURE_SECONDS="${HOLD_ON_FAILURE_SECONDS:-0}"  # CHANGE: >0 keeps a failed pod Running for kubectl exec
NOTIFY_URL="${NOTIFY_URL:-}"                             # CHANGE: webhook from a Secret; empty disables; never logged
NOTIFY_REQUIRED="${NOTIFY_REQUIRED:-0}"                  # CHANGE: 1 = a failed notification fails the run

# ---------- internals ----------
readonly EX_CONFIG=2
START_EPOCH=$(date +%s)
CURRENT_PHASE=init
CHILD_PID=""
HEARTBEAT_PID=""
HOLD_PID=""
EXIT_RC=0
RUN_LOG=""
STATE_DIR=""
SRC_FILES=0
SRC_KIB=0
RCLONE_EXTRA=()
RCLONE_CHECK=()
RSYNC_EXTRA=()
TMP_DIR=$(mktemp -d)       # transient files (temp credentials, listings); removed on exit

log() {
  local level=$1; shift
  local line
  line=$(printf '%s %-5s %s phase=%s %s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$JOB_NAME" "$CURRENT_PHASE" "$*")
  printf '%s\n' "$line" >&2
  if [[ -n $RUN_LOG ]]; then
    printf '%s\n' "$line" >>"$RUN_LOG" || printf 'log: append to %s failed\n' "$RUN_LOG" >&2
  fi
}

die() { local code=$1; shift; log ERROR "$*"; exit "$code"; }

elapsed() { printf '%s' "$(( $(date +%s) - START_EPOCH ))"; }

# ---------- marker protocol: write .part -> verify non-empty -> atomic rename ----------
publish_file() {          # same filesystem required: rename(2) is atomic, a cross-device mv is a copy
  local part=$1 final=$2
  [[ -s $part ]] || die 1 "refusing to publish empty file: $part"
  mv -f -- "$part" "$final"
}

write_marker() {          # write_marker <path> <content...>
  local path=$1; shift
  printf '%s\n' "$*" >"$path.part"
  publish_file "$path.part" "$path"
}

phase_done() { [[ -s $STATE_DIR/$1.done ]]; }   # an EMPTY marker is not success

run_phase() {             # run_phase <name> <function>: skipped when its marker exists (resume)
  local name=$1; shift
  CURRENT_PHASE=$name
  if phase_done "$name"; then
    log INFO "skip: $STATE_DIR/$name.done present"
    return 0
  fi
  log INFO "start"
  "$@"
  write_marker "$STATE_DIR/$name.done" "ok utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) elapsed=$(elapsed)s"
  log INFO "done"
}

# ---------- child processes: background + wait so SIGTERM is handled now, not after the tool exits ----------
heartbeat_start() {
  if (( HEARTBEAT_SECONDS == 0 )); then return 0; fi
  ( trap - ERR; set +e; s="" total=""
    trap 'kill "$s" 2>/dev/null; exit 0' TERM   # take the sleep down too, or it holds the log pipe open
    if (( SRC_FILES > 0 )); then total="; measured source files=$SRC_FILES kib=$SRC_KIB"; fi   # progress needs a denominator
    while :; do
      sleep "$HEARTBEAT_SECONDS" & s=$!
      wait "$s"
      log INFO "heartbeat: running for $(elapsed)s$total"
    done ) &
  HEARTBEAT_PID=$!
}

heartbeat_stop() {
  if [[ -z $HEARTBEAT_PID ]]; then return 0; fi
  kill "$HEARTBEAT_PID" 2>/dev/null || true   # already gone is fine
  wait "$HEARTBEAT_PID" 2>/dev/null || true
  HEARTBEAT_PID=""
}

run_child() {             # argv is visible in ps and in this log: secrets go in env or files, never arguments
  log INFO "exec: $*"
  "$@" &
  CHILD_PID=$!
  heartbeat_start
  local rc=0
  wait "$CHILD_PID" || rc=$?
  heartbeat_stop
  CHILD_PID=""
  return "$rc"
}

# ---------- notification: loud on failure, never silently swallowed ----------
json_escape() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }

notify() {                # notify <status> <message>
  if [[ -z $NOTIFY_URL ]]; then return 0; fi
  local payload
  payload=$(printf '{"text":"[%s/%s] %s: %s"}' "$JOB_NAME" "$RUN_ID" "$1" "$(json_escape "$2")")
  # The webhook URL usually carries a token: pass it on stdin, never in argv (visible in ps / /proc).
  if command -v curl >/dev/null 2>&1 &&
     printf 'url = "%s"\n' "$NOTIFY_URL" |
       curl -fsS --max-time 15 --retry 2 -H 'Content-Type: application/json' -d "$payload" -K - >/dev/null; then
    return 0
  fi
  # GNU wget reads the URL from stdin with -i -; BusyBox wget cannot, so it falls through to the warning.
  if command -v wget >/dev/null 2>&1 &&
     printf '%s\n' "$NOTIFY_URL" |
       wget -q -T 15 -O /dev/null --header='Content-Type: application/json' --post-data="$payload" -i -; then
    return 0
  fi
  log WARN "notify FAILED (status=$1): check DNS, egress NetworkPolicy and the webhook Secret"
  if [[ $NOTIFY_REQUIRED == 1 ]]; then return 1; fi
  return 0
}

cleanup_external() {      # CHANGE: revoke temporary keys / detach temporary disks created by this run
  :
}

# ---------- traps ----------
on_err() { log ERROR "rc=$1 at line $2: $3"; }

on_signal() {             # bash as PID 1 ignores SIGTERM unless trapped
  log WARN "received SIG$1, stopping child ${CHILD_PID:-none}"
  if [[ -n $CHILD_PID ]]; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" || true
  fi
  exit "$2"
}

on_exit() {
  EXIT_RC=$?
  trap - ERR
  set +e
  heartbeat_stop
  local secs
  secs=$(elapsed)
  cleanup_external
  rm -rf -- "$TMP_DIR"
  if (( EXIT_RC == 0 )); then
    log INFO "SUCCESS after ${secs}s files=$SRC_FILES kib=$SRC_KIB"
    notify OK "completed in ${secs}s, files=$SRC_FILES" || EXIT_RC=1
    exit "$EXIT_RC"
  fi
  if (( secs < 1 )); then log WARN "failed within 1s of start: suspect config, mounts or image before data"; fi
  if [[ -n $STATE_DIR && -d $STATE_DIR ]]; then
    write_marker "$STATE_DIR/FAILED" "rc=$EXIT_RC phase=$CURRENT_PHASE utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  log ERROR "FAILED rc=$EXIT_RC phase=$CURRENT_PHASE after ${secs}s"
  notify FAILED "rc=$EXIT_RC phase=$CURRENT_PHASE after ${secs}s"
  if (( HOLD_ON_FAILURE_SECONDS > 0 && EXIT_RC < 128 )); then
    log WARN "holding ${HOLD_ON_FAILURE_SECONDS}s for inspection (kubectl exec); delete the pod to end early"
    sleep "$HOLD_ON_FAILURE_SECONDS" &
    HOLD_PID=$!
    trap 'kill "$HOLD_PID" 2>/dev/null; exit "$EXIT_RC"' TERM INT
    wait "$HOLD_PID"
  fi
  exit "$EXIT_RC"
}

trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
trap 'on_signal TERM 143' TERM
trap 'on_signal INT 130' INT
trap on_exit EXIT

# ---------- phases ----------
validate_config() {       # runs before anything touches data; numeric checks guard later (( )) arithmetic
  local v
  for v in ALLOW_EMPTY_SOURCE RCLONE_TRANSFERS RCLONE_CHECKERS VERIFY_CHECKSUM HEARTBEAT_SECONDS \
           HOLD_ON_FAILURE_SECONDS NOTIFY_REQUIRED; do
    [[ ${!v} =~ ^[0-9]+$ ]] || die "$EX_CONFIG" "$v must be a non-negative integer, got '${!v}'"
  done
  for v in JOB_NAME RUN_ID; do   # used in paths: no slashes, no leading dot
    [[ ${!v} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "$EX_CONFIG" "$v is required and must match [A-Za-z0-9][A-Za-z0-9._-]*"
  done
  [[ -n $DST ]] || die "$EX_CONFIG" "DST is empty"
  for v in SRC_DIR DST STATE_ROOT; do   # Kubernetes leaves an unresolved $(VAR) env reference as literal text
    [[ ${!v} != *'$('* ]] || die "$EX_CONFIG" "$v contains an unresolved \$(VAR) reference: '${!v}'"
  done
  case $TRANSFER_TOOL in
    rclone | rsync) ;;
    *) die "$EX_CONFIG" "TRANSFER_TOOL must be rclone or rsync, got '$TRANSFER_TOOL'" ;;
  esac
  command -v "$TRANSFER_TOOL" >/dev/null 2>&1 || die "$EX_CONFIG" "$TRANSFER_TOOL not found in the image"
  if [[ -n $CHOWN_TO ]]; then
    [[ $TRANSFER_TOOL == rsync ]] || die "$EX_CONFIG" "CHOWN_TO applies to local (rsync) destinations only"
    [[ $CHOWN_PATH == "${DST%/}"/?* ]] || die "$EX_CONFIG" "CHOWN_PATH must be a subdirectory of DST, never its root"
  fi
  read -r -a RCLONE_EXTRA <<<"$RCLONE_EXTRA_FLAGS"
  read -r -a RCLONE_CHECK <<<"$RCLONE_CHECK_FLAGS"
  read -r -a RSYNC_EXTRA <<<"$RSYNC_EXTRA_FLAGS"
  STATE_DIR="$STATE_ROOT/$JOB_NAME/$RUN_ID"
  mkdir -p -- "$STATE_DIR"
  RUN_LOG="$STATE_DIR/run.log"
}

preflight() {             # not marker-gated: cheap, and credentials/mounts can change between attempts
  [[ -d $SRC_DIR && -r $SRC_DIR && -x $SRC_DIR ]] || die "$EX_CONFIG" "source $SRC_DIR missing or unreadable (mount?)"
  case $TRANSFER_TOOL in
    rclone) # surfaces auth, region, endpoint and permission errors before any data moves.
            # Bucket remotes list a missing prefix as empty (exit 0); sftp/local remotes exit 3 if DST does not exist yet:
            # create it first (rclone mkdir) for those.
      run_child rclone lsf --max-depth 1 "${RCLONE_EXTRA[@]}" "$DST" >/dev/null ;;
    rsync)
      [[ -d $DST && -w $DST ]] || die "$EX_CONFIG" "destination $DST missing or not writable" ;;
  esac
}

count_files() {           # count_files <dir> [find predicates...]
  local dir=$1 n; shift
  n=$(find "$dir" "$@" -type f | wc -l)
  printf '%s' "$(( n ))"
}

measure_source() {        # a long walk on big trees: background it so heartbeat and SIGTERM keep working
  run_child measure_walk
}

measure_walk() {          # totals + per-directory counts, directories discovered dynamically
  local dirs="$TMP_DIR/topdirs" counts="$STATE_DIR/src-counts.tsv" d n
  find "$SRC_DIR" -mindepth 1 -maxdepth 1 -type d -print0 >"$dirs"
  n=$(count_files "$SRC_DIR" -maxdepth 1)
  printf '.\t%s\n' "$n" >"$counts.part"
  while IFS= read -r -d '' d; do
    n=$(count_files "$d")
    printf '%s\t%s\n' "${d#"$SRC_DIR"/}" "$n" >>"$counts.part"
  done <"$dirs"
  publish_file "$counts.part" "$counts"
  n=$(count_files "$SRC_DIR")
  write_marker "$STATE_DIR/src-files" "$n"
  n=$(du -sk "$SRC_DIR" | awk '{print $1}')
  write_marker "$STATE_DIR/src-kib" "$n"
}

load_measure() {
  SRC_FILES=$(<"$STATE_DIR/src-files")
  SRC_KIB=$(<"$STATE_DIR/src-kib")
  [[ $SRC_FILES =~ ^[0-9]+$ && $SRC_KIB =~ ^[0-9]+$ ]] || die 1 "corrupt measure markers in $STATE_DIR"
  log INFO "measured source: files=$SRC_FILES disk_usage_kib=$SRC_KIB"
  if (( SRC_FILES == 0 && ALLOW_EMPTY_SOURCE != 1 )); then
    die "$EX_CONFIG" "source has 0 files: a wrong mount or path looks exactly like this"
  fi
}

clear_stale_marker() {    # a marker left by an earlier run would announce this run's partial data
  if [[ $TRANSFER_TOOL == rclone ]]; then
    local found
    found=$(rclone lsf --files-only --include "/$SUCCESS_MARKER" "${RCLONE_EXTRA[@]}" "$DST")
    if [[ -n $found ]]; then run_child rclone deletefile "${RCLONE_EXTRA[@]}" "${DST%/}/$SUCCESS_MARKER"; fi
  else
    rm -f -- "${DST%/}/$SUCCESS_MARKER"
  fi
}

transfer() {
  clear_stale_marker
  case $TRANSFER_TOOL in
    rclone) # copy, never sync: sync deletes destination files that are absent from the source
      run_child rclone copy "$SRC_DIR" "$DST" --transfers "$RCLONE_TRANSFERS" --checkers "$RCLONE_CHECKERS" \
        --stats 60s --stats-one-line --stats-log-level NOTICE "${RCLONE_EXTRA[@]}" ;;
    rsync)  # -a keeps -t so re-runs skip finished files; --partial resumes large files
      run_child rsync -a --partial --no-o --no-g --info=stats2 "${RSYNC_EXTRA[@]}" "$SRC_DIR"/ "$DST"/ ;;
  esac
}

dst_count() {             # dst_count <relative dir or .>
  local rel=$1 n
  if [[ $TRANSFER_TOOL == rclone ]]; then
    if [[ $rel == . ]]; then
      n=$(rclone lsf --files-only --exclude "/$SUCCESS_MARKER" "${RCLONE_EXTRA[@]}" "$DST" | wc -l)
    else
      n=$(rclone lsf -R --files-only "${RCLONE_EXTRA[@]}" "${DST%/}/$rel" | wc -l)
    fi
  elif [[ $rel == . ]]; then
    n=$(count_files "$DST" -maxdepth 1 ! -name "$SUCCESS_MARKER")
  elif [[ ! -d ${DST%/}/$rel ]]; then
    n=0
  else
    n=$(count_files "${DST%/}/$rel")
  fi
  printf '%s' "$(( n ))"
}

compare_counts() {        # a missing prefix on S3/GCS/Azure lists as empty with exit 0, so compare counts
  local rel want got bad=0
  while IFS=$'\t' read -r rel want; do
    got=$(dst_count "$rel")
    if (( got < want )); then
      log ERROR "count mismatch dir=$rel src=$want dst=$got"
      bad=1
    elif (( got > want )); then
      log WARN "destination has extra files dir=$rel src=$want dst=$got"
    fi
  done <"$STATE_DIR/src-counts.tsv"
  if (( bad )); then die 1 "per-directory counts differ (see run log)"; fi
}

verify() {
  local report
  case $TRANSFER_TOOL in
    rclone)
      report="$STATE_DIR/check-combined.txt"
      run_child rclone check --one-way --checkers "$RCLONE_CHECKERS" --combined "$report" \
        "${RCLONE_CHECK[@]}" "${RCLONE_EXTRA[@]}" "$SRC_DIR" "$DST"
      [[ -s $report ]] || die 1 "rclone check wrote no report: $report"
      if grep -q '^[+*!] ' "$report"; then die 1 "rclone check report lists missing/different files: $report"; fi ;;
    rsync)
      report="$STATE_DIR/verify-itemize.txt"
      local -a vflags=(-a --dry-run --itemize-changes --no-o --no-g)
      if (( VERIFY_CHECKSUM == 1 )); then vflags+=(--checksum); fi
      run_child rsync "${vflags[@]}" "${RSYNC_EXTRA[@]}" "$SRC_DIR"/ "$DST"/ >"$report"
      if [[ -s $report ]]; then die 1 "rsync dry-run still finds differences: $report"; fi ;;
  esac
  run_child compare_counts  # one listing per directory: background it like any long step
}

fix_ownership() {         # only the target subtree, only after verification
  if [[ -z $CHOWN_TO ]]; then log INFO "CHOWN_TO empty, skipping"; return 0; fi
  [[ -d $CHOWN_PATH ]] || die 1 "CHOWN_PATH $CHOWN_PATH does not exist after transfer"
  run_child chown -R -- "$CHOWN_TO" "$CHOWN_PATH"
}

finalize() {              # the destination marker is written last; consumers wait for it, non-empty
  local summary
  summary="job=$JOB_NAME run=$RUN_ID files=$SRC_FILES kib=$SRC_KIB utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ $TRANSFER_TOOL == rclone ]]; then
    printf '%s\n' "$summary" >"$TMP_DIR/$SUCCESS_MARKER"
    run_child rclone copyto "${RCLONE_EXTRA[@]}" "$TMP_DIR/$SUCCESS_MARKER" "${DST%/}/$SUCCESS_MARKER"
  else
    write_marker "${DST%/}/$SUCCESS_MARKER" "$summary"
  fi
  rm -f -- "$STATE_DIR/FAILED"
}

main() {
  validate_config
  log INFO "start tool=$TRANSFER_TOOL src=$SRC_DIR dst=$DST state=$STATE_DIR"
  CURRENT_PHASE=preflight
  preflight
  run_phase measure measure_source
  load_measure
  run_phase transfer transfer
  run_phase verify verify
  run_phase ownership fix_ownership
  run_phase finalize finalize
}

main "$@"
