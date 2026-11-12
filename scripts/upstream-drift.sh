#!/usr/bin/env bash
# Upstream sync helper: per-file 3-way status vs obra/superpowers, with the rename map applied first.
#   scripts/upstream-drift.sh <upstream-clone> <base-tag> <theirs-tag> <out-dir> [--merge] [--paths skills,hooks]
# See docs/maintenance/upstream-sync.md. Base tag = the one recorded in UPSTREAM.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 4 ] || { sed -n '2,4p' "$0"; exit 2; }
exec python3 -I "$ROOT/scripts/lib/upstream_drift.py" "$ROOT" "$@"
