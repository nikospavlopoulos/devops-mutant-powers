#!/usr/bin/env bash
# The session-start hook must emit exactly one JSON field, in the shape each harness reads, carrying the bootstrap.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/session-start"
WRAPPER="$ROOT/hooks/run-hook.cmd"
BOOT=$(ls -d "$ROOT"/skills/using-devops-mutant-powers | head -1)
BOOT_NAME=$(basename "$BOOT")
VERSION=$(jq -r .version "$ROOT/.claude-plugin/plugin.json")
FAILURES=0
CTX=""
TMPS=()
trap 'rm -rf "${TMPS[@]}"' EXIT

pass() { echo "  [PASS] $1"; }
failc() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }
newtmp() { local d; d=$(mktemp -d); TMPS+=("$d"); printf -v "$1" '%s' "$d"; } # $1 variable to set
newtmp THOME # throwaway HOME: no user git config or harness state leaks into the hook

# One top-level key per shape: a second field would make a harness inject the bootstrap twice.
CLAUDE='(keys == ["hookSpecificOutput"]) and (.hookSpecificOutput | keys == ["additionalContext", "hookEventName"])
        and .hookSpecificOutput.hookEventName == "SessionStart"'
CURSOR='keys == ["additional_context"]'
TOPLEVEL='keys == ["additionalContext"]'

check() { # $1 description, $2 jq shape predicate, $3 jq filter yielding the context, then the command
  local desc="$1" shape="$2" filter="$3" out
  shift 3
  CTX=""
  if ! out=$(env -i PATH="$PATH" HOME="$THOME" "$@" 2>&1); then
    failc "$desc (hook exited non-zero)"; return
  fi
  if ! printf '%s' "$out" | jq -e "$shape" >/dev/null 2>&1; then
    failc "$desc (wrong JSON shape)"; printf '%s\n' "$out" | head -3 | sed 's/^/      /'; return
  fi
  CTX=$(printf '%s' "$out" | jq -r "$filter")
  if [[ "$CTX" != *"<EXTREMELY_IMPORTANT>"* || "$CTX" != *"name: $BOOT_NAME"* || "$CTX" != *"You have devops-mutant-powers v$VERSION"* ]]; then
    failc "$desc (bootstrap skill content missing)"; return
  fi
  pass "$desc"
}

marker_is() { # $1 description, $2 the exact marker line expected in the last checked context
  local got
  got=$(printf '%s\n' "$CTX" | grep -m1 '^You have devops-mutant-powers' || true)
  if [ "$got" = "$2" ]; then pass "$1"; else failc "$1 (got '$got', want '$2')"; fi
}

minimal_copy() { # $1 destination: just what the hook reads, no .git
  mkdir -p "$1/skills"
  cp -a "$ROOT/hooks" "$ROOT/.claude-plugin" "$1/"
  cp -a "$BOOT" "$1/skills/"
}

echo "session-start output shapes:"
check "Claude Code: hookSpecificOutput.additionalContext only" "$CLAUDE" '.hookSpecificOutput.additionalContext' \
  env CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK"
check "Claude Code via run-hook.cmd wrapper" "$CLAUDE" '.hookSpecificOutput.additionalContext' \
  env CLAUDE_PLUGIN_ROOT="$ROOT" bash "$WRAPPER" session-start
check "Cursor: additional_context only" "$CURSOR" '.additional_context' \
  env CURSOR_PLUGIN_ROOT="$ROOT" bash "$HOOK"
check "Cursor wins when CLAUDE_PLUGIN_ROOT is also set" "$CURSOR" '.additional_context' \
  env CURSOR_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK"
check "Copilot CLI (with CLAUDE_PLUGIN_ROOT): top-level additionalContext only" "$TOPLEVEL" '.additionalContext' \
  env COPILOT_CLI=1 CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK"
check "Copilot CLI (alone): top-level additionalContext only" "$TOPLEVEL" '.additionalContext' \
  env COPILOT_CLI=1 bash "$HOOK"
check "Unknown harness: top-level additionalContext only" "$TOPLEVEL" '.additionalContext' bash "$HOOK"

echo "hook registrations:"
if jq -e '.hooks.SessionStart[0].hooks[0] | (.shell == "bash") and (.command | startswith("bash "))' "$ROOT/hooks/hooks.json" >/dev/null; then
  pass "Claude Code hook runs the wrapper through bash (exec bit not required)"
else failc "Claude Code hook must use shell=bash and a 'bash <wrapper>' command"; fi
CURSOR_CMD=$(jq -r 'select(.version == 1) | .hooks.sessionStart | select(length == 1) | .[0].command // empty' "$ROOT/hooks/hooks-cursor.json" 2>/dev/null)
if [ "$CURSOR_CMD" = "./hooks/run-hook.cmd session-start" ] && jq -e '.hooks | keys == ["sessionStart"]' "$ROOT/hooks/hooks-cursor.json" >/dev/null; then
  pass "Cursor hook file: version 1, one sessionStart entry, relative wrapper command"
else failc "hooks/hooks-cursor.json must be {version: 1, hooks: {sessionStart: [{command: './hooks/run-hook.cmd session-start'}]}}"; fi
check "Cursor: the registered command, run from the plugin root" "$CURSOR" '.additional_context' \
  env CURSOR_PLUGIN_ROOT="$ROOT" bash -c 'cd "$1" && eval "$2"' _ "$ROOT" "${CURSOR_CMD:-false}"
newtmp stripped; minimal_copy "$stripped"; chmod -x "$stripped/hooks/session-start" "$stripped/hooks/run-hook.cmd"
check "Claude Code works with exec bits stripped (packager-safe)" "$CLAUDE" '.hookSpecificOutput.additionalContext' \
  env CLAUDE_PLUGIN_ROOT="$stripped" bash "$stripped/hooks/run-hook.cmd" session-start

echo "broken PATH (anthropics/claude-code#43127):"
check "Claude Code with an unusable PATH" "$CLAUDE" '.hookSpecificOutput.additionalContext' \
  env PATH=/nonexistent CLAUDE_PLUGIN_ROOT="$ROOT" "$BASH" "$HOOK"
check "run-hook.cmd wrapper with an unusable PATH" "$CLAUDE" '.hookSpecificOutput.additionalContext' \
  env PATH=/nonexistent CLAUDE_PLUGIN_ROOT="$ROOT" "$BASH" "$WRAPPER" session-start

echo "build marker:"
if [ "$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$ROOT" && pwd -P)" ]; then
  check "own clone" "$CLAUDE" '.hookSpecificOutput.additionalContext' env CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK"
  marker_is "own clone: version and the clone's short SHA" \
    "You have devops-mutant-powers v$VERSION ($(git -C "$ROOT" rev-parse --short HEAD))."
else
  echo "  [SKIP] own clone: $ROOT is not the top of its own git checkout"
fi
check "copied install (no .git)" "$CLAUDE" '.hookSpecificOutput.additionalContext' \
  env CLAUDE_PLUGIN_ROOT="$stripped" bash "$stripped/hooks/session-start"
marker_is "copied install: version only" "You have devops-mutant-powers v$VERSION."
newtmp outer
env -i PATH="$PATH" HOME="$THOME" git -c init.defaultBranch=main init -q "$outer" &&
  env -i PATH="$PATH" HOME="$THOME" git -C "$outer" -c user.name=test -c user.email=test@example.com \
    -c commit.gpgsign=false commit -q --allow-empty -m init
minimal_copy "$outer/vendor/plugin"
check "copy inside another git repository" "$CLAUDE" '.hookSpecificOutput.additionalContext' \
  env CLAUDE_PLUGIN_ROOT="$outer/vendor/plugin" bash "$outer/vendor/plugin/hooks/session-start"
marker_is "enclosing repository: no SHA (not the plugin's own clone)" "You have devops-mutant-powers v$VERSION."

# Claude Code caps hook additionalContext at 10,000 characters and silently shows only a preview above it.
ctx_len=$(env CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK" | jq -r '.hookSpecificOutput.additionalContext' | wc -m)
# Budget 9800 (the plain-language rule was added regardless of token cost); the 10000 cap stays hard.
if [ "$ctx_len" -lt 9800 ]; then pass "bootstrap context is $ctx_len chars (cap 10000, budget 9800)"
else failc "bootstrap context is $ctx_len chars: over the 9800-char budget for the 10000-char hook cap"; fi

[ "$FAILURES" -eq 0 ] && { echo "session-start: ALL OK"; exit 0; }
echo "session-start: $FAILURES failure(s)"; exit 1
