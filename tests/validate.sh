#!/usr/bin/env bash
# Structural validation for devops-mutant-powers (see tests/validate.py for the checks).
set -euo pipefail
exec python3 -I "$(cd "$(dirname "$0")" && pwd)/validate.py" "$@"
