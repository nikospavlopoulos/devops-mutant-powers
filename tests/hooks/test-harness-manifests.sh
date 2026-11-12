#!/usr/bin/env bash
# Harness manifests (Cursor, Codex, OpenCode package) must wire the bootstrap the way each harness reads it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLUGIN=devops-mutant-powers
FAILURES=0

expect() { # $1 description, $2 file (relative to ROOT), $3 jq predicate that must be true
  if [ ! -f "$ROOT/$2" ]; then echo "  [FAIL] $1 ($2 missing)"; FAILURES=$((FAILURES + 1)); return; fi
  if jq -e --arg plugin "$PLUGIN" "$3" "$ROOT/$2" >/dev/null 2>&1; then echo "  [PASS] $1"
  else echo "  [FAIL] $1 ($2)"; FAILURES=$((FAILURES + 1)); fi
}
exists() { # $1 description, $2 path relative to ROOT
  if [ -e "$ROOT/$2" ]; then echo "  [PASS] $1"; else echo "  [FAIL] $1 ($2 missing)"; FAILURES=$((FAILURES + 1)); fi
}

echo "Cursor (.cursor-plugin/plugin.json):"
expect "name is the plugin name" .cursor-plugin/plugin.json '.name == $plugin'
expect "skills points at ./skills/" .cursor-plugin/plugin.json '.skills == "./skills/"'
# A declared hooks path replaces Cursor's default hooks/hooks.json, which is Claude Code's schema.
expect "hooks points at the Cursor hook file" .cursor-plugin/plugin.json '.hooks == "./hooks/hooks-cursor.json"'
exists "Cursor hook file exists" hooks/hooks-cursor.json

echo "Codex (.codex-plugin/plugin.json, .agents/plugins/marketplace.json):"
expect "name is the plugin name" .codex-plugin/plugin.json '.name == $plugin'
expect "skills points at ./skills/" .codex-plugin/plugin.json '.skills == "./skills/"'
# Exactly {}: absent, [] or an empty list fall back to auto-discovering hooks/hooks.json (Claude Code's hook).
expect "hooks is exactly {} (suppresses hooks/hooks.json discovery)" .codex-plugin/plugin.json \
  '(.hooks | type) == "object" and (.hooks | length) == 0'
expect "interface.defaultPrompt: at most 3 prompts of at most 128 chars" .codex-plugin/plugin.json \
  '(.interface.defaultPrompt // []) | (length <= 3) and all(.[]; type == "string" and length <= 128)'
expect "marketplace lists the plugin once, sourced from the repo root" .agents/plugins/marketplace.json \
  '[.plugins[] | select(.name == $plugin)] | length == 1 and .[0].source == {"source": "url", "url": "./"}
     and .[0].policy == {"installation": "AVAILABLE", "authentication": "ON_INSTALL"} and .[0].category == "Developer Tools"'
codex_mp=$(jq -r .name "$ROOT/.agents/plugins/marketplace.json" 2>/dev/null)
claude_mp=$(jq -r .name "$ROOT/.claude-plugin/marketplace.json" 2>/dev/null)
if [ -n "$codex_mp" ] && [ "$codex_mp" = "$claude_mp" ]; then
  echo "  [PASS] Codex and Claude Code marketplaces share one name ($codex_mp)"
else echo "  [FAIL] marketplace names differ (Codex '$codex_mp', Claude Code '$claude_mp')"; FAILURES=$((FAILURES + 1)); fi

echo "OpenCode (package.json):"
expect "main is the OpenCode module" package.json '.main == ".opencode/plugins/\($plugin).js"'
exists "OpenCode module exists" ".opencode/plugins/$PLUGIN.js"
expect "type is module (the plugin is ESM)" package.json '.type == "module"'

echo "Icons (one root file: harnesses accept no outside URL, and bundles drop paths with a dot part):"
expect "Claude Code icon is the plugin icon" .claude-plugin/plugin.json '.icon == "./icon.png"'
expect "Codex logo is the plugin icon" .codex-plugin/plugin.json '.interface.logo == "./icon.png"'
# The composer draws its icon at about 20 px, where the app icon's helix crossings blur: the micro-mark tile reads there.
expect "Codex composer icon is the small icon" .codex-plugin/plugin.json '.interface.composerIcon == "./icon-small.png"'
expect "Codex brand colours are the GFP greens" .codex-plugin/plugin.json \
  '.interface.brandColor == "#13843f" and .interface.brandColorDark == "#4be07f"'
expect "Cursor logo is the plugin icon" .cursor-plugin/plugin.json '.logo == "./icon.png"'
expect "Antigravity logo is the plugin icon" plugin.json '.logo == "./icon.png"'
exists "plugin icon exists" icon.png
# Claude's directory takes a square PNG or JPEG of 512-2048 px under 2 MB, once, at the first submission.
if python3 -I - "$ROOT/icon.png" <<'PY' 2>/dev/null
import os, struct, sys
p = sys.argv[1]; b = open(p, "rb").read(24); w, h = struct.unpack(">II", b[16:24])
sys.exit(0 if b[:8] == b"\x89PNG\r\n\x1a\n" and w == h and 512 <= w <= 2048 and os.path.getsize(p) < 2 * 1024 * 1024 else 1)
PY
then echo "  [PASS] icon is a square PNG of 512-2048 px under 2 MB"
else echo "  [FAIL] icon is not a square PNG of 512-2048 px under 2 MB"; FAILURES=$((FAILURES + 1)); fi
exists "composer icon exists" icon-small.png
# Codex takes square icons of 48-4096 px, at most 5 MiB.
if python3 -I - "$ROOT/icon-small.png" <<'PY' 2>/dev/null
import os, struct, sys
p = sys.argv[1]; b = open(p, "rb").read(24); w, h = struct.unpack(">II", b[16:24])
sys.exit(0 if b[:8] == b"\x89PNG\r\n\x1a\n" and w == h and 48 <= w <= 4096 and os.path.getsize(p) <= 5 * 1024 * 1024 else 1)
PY
then echo "  [PASS] composer icon is a square PNG of 48-4096 px, at most 5 MiB"
else echo "  [FAIL] composer icon is not a square PNG of 48-4096 px, at most 5 MiB"; FAILURES=$((FAILURES + 1)); fi

[ "$FAILURES" -eq 0 ] && { echo "harness manifests: ALL OK"; exit 0; }
echo "harness manifests: $FAILURES failure(s)"; exit 1
