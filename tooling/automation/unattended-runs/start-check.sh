#!/usr/bin/env bash
# Fallback for a scheduled start: if the ledger still says SCHEDULED at check time, send ONE alert.
# Notification only: it never starts Claude and never changes anything.   start-check.sh LEDGER [--dry-run]
set -u
ledger="${1:?usage: start-check.sh LEDGER [--dry-run]}"; dry="${2:-}"
here="$(cd "$(dirname "$0")" && pwd)"
[ -r "$ledger" ] || { echo "start-check: cannot read ledger $ledger" >&2; exit 2; }   # a wrong path must not look like "started"
state=$(sed -n 's/^- Current: //p' "$ledger" | head -1)
home="${HOME:-/nonexistent}"
case "$ledger" in "$home"/*) shown="~${ledger#"$home"}";; *) shown="$ledger";; esac   # no user name in the chat
case "$state" in
  SCHEDULED*) msg="Unattended run has NOT started yet (ledger: ${state}). If its Claude session is still open, the starter keeps retrying; if the session was closed, open Claude and say: resume the run in ${shown}";;
  *) exit 0;;
esac
if [ "$dry" = "--dry-run" ]; then "$here/notify.sh" --dry-run "$msg"; else "$here/notify.sh" "$msg"; fi
