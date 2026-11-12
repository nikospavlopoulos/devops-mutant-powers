#!/usr/bin/env bash
# Human-in-the-loop reproduction loop: walks a person through steps only they can run and captures what they saw.
# The agent copies it and edits the steps between the markers; the person runs the copy in their own terminal and
# pastes the "--- Captured ---" block back. Docs: skills/systematic-debugging/references/feedback-loop.md.
#   step "<instruction>"                show an instruction, wait for Enter
#   capture NAME "<question>"           read a one-line answer into NAME (secrets masked)
#   capture_block NAME "<question>"     read pasted lines until an empty line, joined with \n (secrets masked)
# Every captured value is printed as NAME=VALUE. Exit 2 when input ran out before an answer (marked <NO ANSWER>).
# Capture observations only: signing in stays a step the person does, and a credential is never captured.
# Structure adapted from mattpocock/skills diagnosing-bugs (MIT); see LICENSE.
set -euo pipefail

if [ ! -t 0 ] && [ -z "${HITL_STDIN_OK:-}" ]; then # the agent's shell has no terminal: empty answers would look real
  echo "hitl-loop: run this in your own terminal, then paste the --- Captured --- block back to the agent" >&2
  exit 2
fi

_hitl_names=()
_hitl_missing=0

redact() { # labelled secrets, bearer/basic credentials, JWTs, URL passwords, long base64 (hex ids and UUIDs stay)
  sed -E \
    -e 's/(([Bb]earer|[Bb]asic) )[^ ]+/\1<REDACTED>/g' \
    -e 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/<REDACTED>/g' \
    -e 's#(://[^/:@ ]+:)[^@ /]+@#\1<REDACTED>@#g' \
    -e 's/(([A-Za-z0-9_-]*([Pp][Aa][Ss][Ss]([Ww][Oo][Rr][Dd]|[Ww][Dd])?|[Pp][Ww][Dd]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]))"?[[:space:]]*[=:][[:space:]]*"?)[^ ",}]+/\1<REDACTED>/g' |
    awk '{ n = split($0, w, / /); s = ""
           for (i = 1; i <= n; i++) {
             t = w[i]
             if (length(t) >= 40 && t ~ /^[A-Za-z0-9+\/]+=*$/ && t !~ /^[0-9A-Fa-f]+$/) t = "<REDACTED>"
             s = s (i > 1 ? " " : "") t
           }
           print s }'
}

_hitl_name() { # capture names: upper case, and never a variable the shell or this script relies on
  case "$1" in PATH | IFS | HOME | SHELL | PWD | OLDPWD | BASH*) ;; *) [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ ]] && return 0 ;; esac
  echo "hitl-loop: '$1' cannot be a capture name (use A-Z, 0-9 and _, and not PATH, IFS or HOME)" >&2
  exit 2
}

step() {
  printf '\n>>> %s\n' "$1" >&2
  IFS= read -r -p "    [Enter when done] " _ || _hitl_missing=1
}

capture() {
  _hitl_name "$1"
  local _hitl_answer=""
  printf '\n>>> %s\n' "$2" >&2
  if ! IFS= read -r -p "    > " _hitl_answer && [ -z "$_hitl_answer" ]; then
    _hitl_answer="<NO ANSWER>"; _hitl_missing=1
  else
    _hitl_answer=$(printf '%s' "$_hitl_answer" | redact)
  fi
  printf -v "$1" '%s' "$_hitl_answer"
  _hitl_names+=("$1")
}

capture_block() {
  _hitl_name "$1"
  local _hitl_line _hitl_text="" _hitl_got=0
  printf '\n>>> %s\n    (paste it, then press Enter on an empty line)\n' "$2" >&2
  while IFS= read -r _hitl_line || [ -n "$_hitl_line" ]; do
    _hitl_got=1
    [ -z "$_hitl_line" ] && break
    [ -z "$_hitl_text" ] || _hitl_text+='\n'
    _hitl_text+=$(printf '%s' "$_hitl_line" | redact)
  done
  if [ "$_hitl_got" = 0 ]; then _hitl_text="<NO ANSWER>"; _hitl_missing=1; fi
  printf -v "$1" '%s' "$_hitl_text"
  _hitl_names+=("$1")
}

# --- edit below ---------------------------------------------------------

step "Connect the VPN, then open https://app.example.com/orders in the browser and sign in."

capture STATUS "Open the browser's developer tools (Network tab) and reload. What status code does /api/orders return?"

capture_block ERROR_MSG "Paste the error text shown on the page (or 'none'):"

# --- edit above ---------------------------------------------------------

while IFS= read -r -t 1 _; do :; done 2>/dev/null || true # leftover pasted lines must not reach the shell

printf '\n--- Captured ---\n'
# ${a[@]+...}: bash < 4.4 treats an empty array as unset under set -u
for _hitl_v in ${_hitl_names[@]+"${_hitl_names[@]}"}; do printf '%s=%s\n' "$_hitl_v" "${!_hitl_v}"; done
if [ "$_hitl_missing" != 0 ]; then
  echo "hitl-loop: input ended before every answer (marked <NO ANSWER>); run it again in your own terminal" >&2
  exit 2
fi
