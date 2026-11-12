#!/usr/bin/env bash
# Public diagrams render with GitHub's defaults: no %%{init}%% directive and no front-matter config in any file.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/scripts/docs/check-mermaid.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
mkdir -p "$T/docs"
page() {  # page <file> <first lines of the diagram, or empty>
  printf 'Intro.\n\n```mermaid\n%sflowchart TD\n    A["One"] --> B["Two"]\n```\n\nAfter.\n' "$2" > "$T/$1"
}
house="%%{init: { 'theme': 'default', 'themeVariables': { 'fontSize': '14px' }, 'flowchart': { 'nodeSpacing': 15, 'rankSpacing': 25, 'padding': 8, 'useMaxWidth': true } }}%%"
page README.md ""
page docs/plain.md ""
page docs/house.md "$house"$'\n'
page docs/wrap.md "%%{init: { 'flowchart': { 'wrappingWidth': 320 } } }%%"$'\n'
page docs/config.md $'---\nconfig:\n  theme: dark\n---\n'
page docs/title.md $'---\ntitle: Request path\n---\n'
expect() {  # expect <name> <want-exit> <file>
  (cd "$T" && python3 -I "$CHECK" "$3" > /dev/null); rc=$?
  if [ "$rc" -eq "$2" ]; then echo "  [PASS] $1"; else echo "  [FAIL] $1 (exit $rc, want $2)"; fail=1; fi
}
echo "=== Test: check-mermaid ==="
expect "the root README with no init line passes" 0 README.md
expect "a docs page with no init line passes" 0 docs/plain.md
expect "the house init line fails" 1 docs/house.md
expect "an init line with only a wrapping width fails" 1 docs/wrap.md
expect "front matter with config fails" 1 docs/config.md
expect "front matter with only a title passes" 0 docs/title.md
[ "$fail" -eq 0 ] && echo "check-mermaid: ALL OK" || { echo "check-mermaid: FAILED"; exit 1; }
