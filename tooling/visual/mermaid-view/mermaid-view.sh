#!/usr/bin/env bash
# mermaid-view: render Mermaid diagrams to PNG or SVG and show them, inline (through the agent) or in a viewer pane.
# Usage: mermaid-view <new SLUG | render FILE [OUT] | show FILE | watch [--once] | status | open FILE | overlay FILE |
#                      demo | doctor | install | autostart | help>
set -uo pipefail

CLI_VERSION="12.0.0" # @mermaid-js/mermaid-cli, pinned
PLUGIN="devops-mutant-powers" # must equal .claude-plugin/plugin.json name (tests/validate.py checks it)
VERSION="2.2.0" # must equal the plugin version (tests/validate.py checks it); a stale copy on PATH is reported
DIR="${MERMAID_VIEW_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/$PLUGIN/visual}"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/$PLUGIN/mermaid-view"
INIT="%%{init: { 'theme': 'default', 'themeVariables': { 'fontSize': '14px' }, 'flowchart': { 'nodeSpacing': 15, 'rankSpacing': 25, 'padding': 8, 'useMaxWidth': true } }}%%"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "mermaid-view: $*" >&2; exit 1; }

stale_copy() { # one line when the mermaid-view on PATH is another file with an older or no VERSION
  local other v
  other=$(command -v mermaid-view 2>/dev/null) || return 0
  [ -f "$other" ] || return 0 # a function or alias of that name
  [ "$other" -ef "${BASH_SOURCE[0]}" ] && return 0
  v=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$other" 2>/dev/null | head -n1)
  [ -n "$v" ] && { [ "$v" = "$VERSION" ] || [ "$(printf '%s\n%s\n' "$v" "$VERSION" | sort -V 2>/dev/null | head -n1)" != "$v" ]; } && return 0
  echo "the mermaid-view on PATH ($other, ${v:-no version}) is older than this one ($VERSION): run 'bash $HERE/mermaid-view.sh install'"
}

find_npx() {
  command -v npx 2>/dev/null && return 0
  local n
  n=$(ls -1d "$HOME"/.nvm/versions/node/*/bin/npx 2>/dev/null | sort -V | tail -1)
  [ -n "$n" ] && echo "$n"
}

find_browser() {
  [ -n "${MERMAID_VIEW_BROWSER:-}" ] && { echo "$MERMAID_VIEW_BROWSER"; return 0; }
  local b
  for b in google-chrome-stable google-chrome chromium chromium-browser; do command -v "$b" 2>/dev/null && return 0; done
  b="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" # scan-allow: macOS app bundle path, not a host
  [ -x "$b" ] && echo "$b"
}

pick_theme() { # a house theme at random, never the one used last
  local last t pool=()
  last=$(cat "$DIR/.last-theme" 2>/dev/null)
  for t in default neutral forest base; do [ "$t" = "$last" ] || pool+=("$t"); done
  t=${pool[RANDOM % ${#pool[@]}]}
  mkdir -p "$DIR" && printf '%s\n' "$t" > "$DIR/.last-theme"
  echo "$t"
}

# Print $1 without leading blank lines or CRs; with $2 set, insert that init line right after a leading ---/--- title
# header (Mermaid reads front matter only on line 1), or at the top. With $2 empty, exit 0 if the source needs one;
# a source that sets config or theme in its front matter never does.
with_init() {
  awk -v init="$2" '
    { sub(/\r$/, "") }
    !started && /^[[:space:]]*$/ { next }
    !started { started = 1; if ($0 ~ /^---[[:space:]]*$/) { fm = 1; if (init != "") print; next } }
    fm == 1 { if ($0 ~ /^[[:space:]]*(config|theme)[[:space:]]*:/) has = 1
              if (init != "") print; if ($0 ~ /^---[[:space:]]*$/) fm = 2; next }
    !checked && /^[[:space:]]*$/ { if (init != "") print; next }
    !checked { checked = 1; has = has || ($0 ~ /^%%\{init/); if (!has && init != "") print init }
    { if (init != "") print }
    END { if (init == "") exit has ? 1 : 0 }
  ' "$1"
}

# Render $1 (Mermaid source) to $2 (.png or .svg). A source without an init line gets the house-style one with a
# rotating theme; a diagram in $DIR keeps it (written back before rendering), so re-renders show the same theme.
render_to() {
  local in="$1" out="$2" src rc line="" q="'"
  src=$(mktemp "${TMPDIR:-/tmp}/mermaid-view.XXXXXX") || die "cannot create a temp file"
  mv -f "$src" "$src.mmd" && src="$src.mmd"
  if with_init "$in" ""; then line="${INIT/${q}default${q}/${q}$(pick_theme)${q}}"; with_init "$in" "$line" > "$src"
    case "$in" in "$DIR"/*) cp "$src" "$in" ;; esac # before rendering, so the PNG ends up newer than its source
  else cat "$in" > "$src"; fi
  local tmp_out="${out%.*}.tmp.$$.${out##*.}"
  if [ -n "${MERMAID_VIEW_RENDERER:-}" ]; then
    "$MERMAID_VIEW_RENDERER" "$src" "$tmp_out" 2> "$src.err"; rc=$?
  else
    local npx browser
    npx=$(find_npx) || true; [ -n "$npx" ] || { rm -f "$src"; die "npx not found (install Node.js 18+)"; }
    browser=$(find_browser) || true; [ -n "$browser" ] || { rm -f "$src"; die "no Chrome or Chromium found (set MERMAID_VIEW_BROWSER)"; }
    PATH="$(dirname "$npx"):$PATH" PUPPETEER_EXECUTABLE_PATH="$browser" PUPPETEER_SKIP_DOWNLOAD=1 \
      "$npx" -y "@mermaid-js/mermaid-cli@$CLI_VERSION" -q -i "$src" -o "$tmp_out" -b white -s 2 2> "$src.err" >/dev/null; rc=$?
  fi
  if [ "$rc" -ne 0 ] || [ ! -s "$tmp_out" ]; then
    echo "mermaid-view: render failed for $in" >&2
    grep -v '^[[:space:]]*at ' "$src.err" | head -n 8 >&2 # the parse message, not the JavaScript stack frames
    rm -f "$src" "$src.err" "$tmp_out"; return 2
  fi
  mv -f "$tmp_out" "$out"
  rm -f "$src" "$src.err"
}

png_for() { echo "${1%.mmd}.png"; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

KEEP_DAYS=300
prune_old() { # only names cmd_new creates, only at the top of $DIR
  local stamp='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*'
  find "$DIR" -maxdepth 1 -type f \( -name "$stamp.mmd" -o -name "$stamp.png" -o -name "$stamp.svg" \) \
    -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true
}

cmd_new() {
  local slug="${1:-diagram}"
  slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')
  mkdir -p "$DIR" && prune_old && echo "$DIR/$(date +%Y%m%d-%H%M%S)-${slug:-diagram}.mmd"
}

cmd_render() {
  [ $# -ge 1 ] && [ -r "$1" ] || die "render: need a readable .mmd file"
  local out="${2:-$(png_for "$1")}"
  render_to "$1" "$out" || exit 2
  echo "$out"
}

cmd_show() { # render next to the source; a running viewer picks it up; print the PNG path for the agent to open
  [ $# -ge 1 ] && [ -r "$1" ] || die "show: need a readable .mmd file"
  local png; png=$(png_for "$1")
  render_to "$1" "$png" || exit 2
  echo "$png"
  viewer_alive >/dev/null 2>&1 && echo "mermaid-view: shown in the viewer pane" >&2
  local w; w=$(stale_copy); [ -n "$w" ] && echo "mermaid-view: $w" >&2
  return 0
}

viewer_alive() {
  local pid
  [ -f "$DIR/.viewer" ] || return 1
  pid=$(head -n1 "$DIR/.viewer" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o args= 2>/dev/null | grep -q "mermaid-view.*watch" \
    && { echo "$pid"; return 0; }
  return 1
}

cmd_status() {
  local pid
  if pid=$(viewer_alive); then echo "viewer running (pid $pid, $(sed -n 2p "$DIR/.viewer" 2>/dev/null))"; return 0; fi
  echo "no viewer running (start one with: mermaid-view watch)"; return 1
}

display_method() {
  [ -n "${MERMAID_VIEW_DISPLAY:-}" ] && { echo custom; return; }
  if command -v kitten >/dev/null 2>&1 && kitten icat --detect-support >/dev/null 2>&1; then echo kitty; return; fi
  if command -v chafa >/dev/null 2>&1; then echo chafa; return; fi
  if command -v img2sixel >/dev/null 2>&1; then echo sixel; return; fi
  echo path
}

display_png() { # $1 method, $2 png
  case "$1" in
    custom) "$MERMAID_VIEW_DISPLAY" "$2" ;;
    kitty) kitten icat --clear --stdin=no --align=left "$2" ;;
    chafa) chafa "$2" ;;
    sixel) img2sixel "$2" ;;
    *) echo "(this terminal cannot draw images; open: $2)" ;;
  esac
}

newest() { ls -1t "$DIR"/*.mmd "$DIR"/*.png 2>/dev/null | grep -v '\.tmp\.' | head -n1; }

term_size() { # COLSxROWS of this terminal; tests set MERMAID_VIEW_SIZE to a file that holds it
  if [ -n "${MERMAID_VIEW_SIZE:-}" ]; then cat "$MERMAID_VIEW_SIZE" 2>/dev/null; return; fi
  echo "$(tput cols 2>/dev/null || echo 80)x$(tput lines 2>/dev/null || echo 24)"
}

cmd_watch() {
  local once=no shown="" failed="" method f png key size
  [ "${1:-}" = "--once" ] && once=yes
  mkdir -p "$DIR"
  method=$(display_method)
  printf '%s\n%s\n' "$$" "$method" > "$DIR/.viewer"
  trap 'rm -f "$DIR/.viewer"; exit 0' INT TERM
  trap 'rm -f "$DIR/.viewer"' EXIT
  [ "$once" = yes ] || echo "mermaid-view: watching $DIR ($method). Diagrams appear here; Ctrl+C to stop."
  while :; do
    f=$(newest)
    if [ -n "$f" ]; then
      case "$f" in
        *.mmd)
          png=$(png_for "$f")
          if ! { [ -s "$png" ] && [ "$png" -nt "$f" ]; }; then
            key="$f|$(mtime "$f")" # a broken diagram is retried only after the file changes
            if [ "$key" = "$failed" ]; then png=""; elif ! render_to "$f" "$png"; then failed="$key"; png=""; fi
          fi ;;
        *) png="$f" ;;
      esac
      size=$(term_size)
      if [ -n "$png" ] && [ "$png|$(mtime "$png")|$size" != "$shown" ]; then # a resize redraws too
        [ "$once" = yes ] || clear
        echo "── $(basename "${png%.png}")  $(date +%H:%M:%S)"
        overlay_png "$method" "$png" "${size%x*}" "$(( ${size#*x} - 2 ))" 1
        shown="$png|$(mtime "$png")|$size"
      fi
    fi
    [ "$once" = yes ] && return 0
    sleep "${MERMAID_VIEW_INTERVAL:-1}"
  done
}

find_opener() { # the desktop's default handler for a file
  [ -n "${MERMAID_VIEW_OPENER:-}" ] && { echo "$MERMAID_VIEW_OPENER"; return 0; }
  command -v xdg-open 2>/dev/null && return 0
  command -v open 2>/dev/null
}

cmd_open() {
  [ $# -ge 1 ] && [ -r "$1" ] || die "open: need a readable file"
  local f="$1" opener
  case "$f" in *.mmd) f=$(png_for "$1"); render_to "$1" "$f" || exit 2 ;; esac
  opener=$(find_opener) || die "no xdg-open or open found; the image is at $f"
  "$opener" "$f" >/dev/null 2>&1 &
  echo "$f"
}

overlay_png() { # $1 method, $2 png, $3 columns, $4 rows, $5 top row: draw the image scaled to fit that area
  case "$1" in
    custom) "$MERMAID_VIEW_DISPLAY" "$2" "$3" "$4" ;;
    kitty) kitten icat --clear --stdin=no --place "${3}x${4}@0x${5:-0}" "$2" ;;
    chafa) chafa --size "${3}x${4}" "$2" ;;
    *) display_png "$1" "$2" ;;
  esac
}

# For a terminal's click rule (kitty: open-actions.conf): show FILE full-window; o opens it in the desktop's
# image viewer (to print or save), any other key closes.
cmd_overlay() {
  # the overlay window closes when this exits, so an error waits for a key to stay readable
  held() { echo "mermaid-view: $1 (press any key)" >&2; IFS= read -rsn1 _ || true; exit "${2:-1}"; }
  [ $# -ge 1 ] && [ -r "$1" ] || held "overlay: cannot open ${1:-(no file given)}"
  local f="$1" opener key rows cols
  case "$f" in *.mmd) f=$(png_for "$1"); render_to "$1" "$f" || held "overlay: render failed for $1" 2 ;; esac
  rows=$(tput lines 2>/dev/null) || rows=24; cols=$(tput cols 2>/dev/null) || cols=80
  clear
  overlay_png "$(display_method)" "$f" "$cols" "$((rows - 2))"
  printf '\033[%d;1H%s  ·  o: open in the image viewer  ·  any other key: close' "$rows" "$(basename "$f")"
  IFS= read -rsn1 key || true
  case "$key" in
    o|O)
      opener=$(find_opener) || held "no xdg-open or open found; the image is at $f"
      # detached, so the viewer survives the overlay window closing
      if command -v setsid >/dev/null 2>&1; then setsid -f "$opener" "$f" >/dev/null 2>&1
      else nohup "$opener" "$f" >/dev/null 2>&1 & fi ;;
  esac
  return 0
}

examples_dir() { [ -d "$HERE/examples" ] && echo "$HERE/examples" || echo "$SHARE/examples"; }

cmd_demo() {
  local ex f dst
  ex=$(examples_dir); [ -d "$ex" ] || die "examples not found ($ex)"
  for f in "$ex"/*.mmd; do
    dst=$(cmd_new "demo-$(basename "${f%.mmd}")"); cp "$f" "$dst"
    cmd_show "$dst"
    sleep "${MERMAID_VIEW_DEMO_PAUSE:-4}"
  done
}

cmd_doctor() {
  local ok=0 t
  check() { if ( eval "$2" ) >/dev/null 2>&1; then echo "  [OK]   $1"; else echo "  [FAIL] $1${3:+ ($3)}"; ok=1; fi; }
  echo "mermaid-view doctor:"
  check "npx found: $(find_npx || echo none)" '[ -n "$(find_npx)" ]' "install Node.js 18+"
  check "Chrome or Chromium found: $(find_browser || echo none)" '[ -n "$(find_browser)" ]' "install Google Chrome or Chromium"
  t=$(mktemp -d); printf 'flowchart LR\n  A[render] --> B[check]\n' > "$t/d.mmd"
  check "renders a test diagram (first run downloads mermaid-cli $CLI_VERSION)" 'render_to "$t/d.mmd" "$t/d.png" && [ -s "$t/d.png" ]'
  rm -rf "$t"
  if [ -t 1 ]; then echo "  [INFO] this terminal displays images via: $(display_method)"; fi
  echo "  [INFO] diagrams folder: $DIR"
  local w; w=$(stale_copy); [ -n "$w" ] && echo "  [WARN] $w"
  local rules="${KITTY_CONFIG_DIRECTORY:-${XDG_CONFIG_HOME:-$HOME/.config}/kitty}/open-actions.conf"
  local tpl="$HERE/kitty-open-actions.conf"
  [ -f "$tpl" ] || tpl="$SHARE/kitty-open-actions.conf"
  if ! grep -qs 'mermaid-view overlay' "$rules"; then
    echo "  [INFO] kitty click rule: not set up (kitty only: add $tpl to $rules, above other image rules, then press Ctrl+Shift+F5)"
  elif [ ! -x "$HOME/.local/bin/mermaid-view" ]; then
    echo "  [INFO] kitty click rule: found, but $HOME/.local/bin/mermaid-view is missing (run mermaid-view install)"
  else
    echo "  [INFO] kitty click rule: found ($rules); Ctrl+Shift+Click a diagram link opens it full-window"
  fi
  return $ok
}

cmd_install() {
  local bin="$HOME/.local/bin"
  install -d "$bin" "$SHARE/examples" && install -m 755 "${BASH_SOURCE[0]}" "$bin/mermaid-view" \
    || die "install failed (could not write $bin/mermaid-view)"
  cp "$HERE"/examples/*.mmd "$SHARE/examples/" 2>/dev/null || echo "note: examples not copied (none found next to the script)"
  cp "$HERE/kitty-open-actions.conf" "$SHARE/" 2>/dev/null || echo "note: kitty click rule template not copied (not found next to the script)"
  echo "installed $bin/mermaid-view (examples in $SHARE/examples)"
  case ":$PATH:" in *":$bin:"*) ;; *) echo "note: $bin is not on PATH; add it in your shell profile" ;; esac
}

cmd_autostart() { # for an optional SessionStart hook: needs kitty remote control (allow_remote_control + listen_on)
  viewer_alive >/dev/null && exit 0
  [ -n "${KITTY_LISTEN_ON:-}" ] && command -v kitten >/dev/null 2>&1 || exit 0
  # split: below on a tall window, beside on a wide one; --bias needs kitty 0.36+, so older kitty retries without it
  kitten @ launch --location=split --bias=30 --keep-focus --cwd=current mermaid-view watch >/dev/null 2>&1 \
    || kitten @ launch --location=split --keep-focus --cwd=current mermaid-view watch >/dev/null 2>&1 || true
}

case "${1:-help}" in
  new) shift; cmd_new "$@" ;;
  render) shift; cmd_render "$@" ;;
  show) shift; cmd_show "$@" ;;
  watch) shift; cmd_watch "$@" ;;
  status) cmd_status ;;
  open) shift; cmd_open "$@" ;;
  overlay) shift; cmd_overlay "$@" ;;
  demo) cmd_demo ;;
  doctor) cmd_doctor ;;
  install) cmd_install ;;
  autostart) cmd_autostart ;;
  help|-h|--help) sed -n '2,4p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command: $1 (try: mermaid-view help)" ;;
esac
