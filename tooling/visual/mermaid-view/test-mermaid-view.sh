#!/usr/bin/env bash
# Offline tests for mermaid-view (stub renderer and display). MERMAID_VIEW_LIVE=1 also renders the examples for real.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MV="$HERE/mermaid-view.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export MERMAID_VIEW_DIR="$tmp/visual" MERMAID_VIEW_INTERVAL=0
fails=0
pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; fails=$((fails + 1)); }

# Stub renderer: copies the prepared source to the output (so the init line can be checked); fails on INVALID.
cat > "$tmp/render" <<EOF
#!/usr/bin/env bash
echo call >> "$tmp/render.calls"
grep -q INVALID "\$1" && { echo "Parse error on line 2: INVALID" >&2; for i in 1 2 3 4 5 6 7 8 9 10; do echo "    at frame\$i (mermaid.js:1:1)" >&2; done; exit 1; }
cp "\$1" "\$2"
EOF
printf '#!/usr/bin/env bash\necho "DISPLAYED $*" >> "%s/shown.log"\n' "$tmp" > "$tmp/display"
chmod +x "$tmp/render" "$tmp/display"
export MERMAID_VIEW_RENDERER="$tmp/render" MERMAID_VIEW_DISPLAY="$tmp/display" MERMAID_VIEW_OPENER="$tmp/display"

echo "mermaid-view:"
f=$(bash "$MV" new "Cutover Timeline!")
case "$f" in "$MERMAID_VIEW_DIR"/*-cutover-timeline.mmd) pass "new prints a fresh path with a clean slug" ;; *) fail "new ($f)" ;; esac

old="$MERMAID_VIEW_DIR/20240101-000000-old.png"; kept="$MERMAID_VIEW_DIR/20240101-000000-recent.mmd"; mine="$MERMAID_VIEW_DIR/notes.png"
touch -d '302 days ago' "$old" "$mine"; touch -d '298 days ago' "$kept" # clear of a DST hour
bash "$MV" new prune >/dev/null
[ ! -e "$old" ] && pass "new prunes its own diagrams older than 300 days" || fail "old diagram kept"
[ -e "$kept" ] && [ -e "$mine" ] && pass "new keeps recent diagrams and files it did not create" || fail "prune removed too much"
HOUSE="^%%\{init: \{ 'theme': '(default|neutral|forest|base)', 'themeVariables': \{ 'fontSize': '14px' \}"
theme_of() { grep -m1 -oE "'theme': '[a-z]+'" "$1" | cut -d"'" -f4; }
printf 'flowchart LR\n  A --> B\n' > "$f"
out=$(bash "$MV" render "$f") && head -n1 "$out" | grep -qE "$HOUSE" \
  && pass "render adds the house-style init line with a house theme" || fail "render init line ($out)"
[ "$(grep -c '^%%{init' "$f")" = 1 ] && pass "render writes the init line back into a diagram in the folder" \
  || fail "init line not written back ($(head -n1 "$f"))"
printf "%%%%{init: { 'theme': 'neutral' } }%%%%\nflowchart LR\n  A --> B\n" > "$tmp/own.mmd"
bash "$MV" render "$tmp/own.mmd" "$tmp/own.png" >/dev/null && [ "$(grep -c '^%%{init' "$tmp/own.png")" = 1 ] \
  && pass "render keeps an existing init line (no duplicate)" || fail "render duplicate init"
printf 'flowchart LR\n  A --> B\n' > "$tmp/outside.mmd"; cp "$tmp/outside.mmd" "$tmp/outside.orig"
bash "$MV" render "$tmp/outside.mmd" "$tmp/outside.png" >/dev/null && cmp -s "$tmp/outside.mmd" "$tmp/outside.orig" \
  && pass "render leaves a source outside the diagrams folder unchanged" || fail "outside source modified"
t=$(bash "$MV" new titled); printf '\n\n---\ntitle: "Request path"\n---\nflowchart TD\n  A --> B\n' > "$t"
out=$(bash "$MV" render "$t") && [ "$(head -n1 "$out")" = "---" ] && sed -n 4p "$out" | grep -qE "$HOUSE" \
  && pass "render keeps a title header first and puts the init line right after it" || fail "title header ($(head -n4 "$out" | tr '\n' '|'))"
[ "$(head -n1 "$t")" = "---" ] && [ "$(grep -c '^%%{init' "$t")" = 1 ] \
  && pass "render drops leading blank lines and writes the init line after the title header" || fail "titled write-back"
a=$(bash "$MV" new rot-a); b=$(bash "$MV" new rot-b); printf 'flowchart TD\n  A --> B\n' | tee "$a" > "$b"
bash "$MV" render "$a" >/dev/null && bash "$MV" render "$b" >/dev/null && [ -n "$(theme_of "$a")" ] && [ "$(theme_of "$a")" != "$(theme_of "$b")" ] \
  && pass "two new diagrams in a row get different themes" || fail "theme rotation ($(theme_of "$a") $(theme_of "$b"))"
bash "$MV" render "$a" >/dev/null && [ "$(grep -c '^%%{init' "$a")" = 1 ] \
  && pass "a re-render keeps the theme written into the source" || fail "re-render duplicated the init line"
w=$(bash "$MV" new crlf); printf -- '--- \r\ntitle: "T"\r\n---\r\nflowchart TD\r\n  A --> B\r\n' > "$w"
out=$(bash "$MV" render "$w") && head -n1 "$out" | grep -qE '^---[[:space:]]*$' && sed -n 4p "$out" | grep -qE "$HOUSE" \
  && pass "a title header with CRLF line ends or a trailing space still comes first" || fail "CRLF title ($(head -n4 "$out" | od -c | head -3 | tr -s ' '))"
k=$(bash "$MV" new keepcfg); printf -- '---\nconfig:\n  theme: dark\n---\nflowchart TD\n  A --> B\n' > "$k"
out=$(bash "$MV" render "$k") && ! grep -q '^%%{init' "$out" \
  && pass "a theme set in the front matter is respected (no init line added)" || fail "front-matter config overridden"
x=$(bash "$MV" new compat); printf 'flowchart TD\n  A --> B\n' > "$x"
BASH_COMPAT=42 bash "$MV" render "$x" >/dev/null && head -n1 "$x" | grep -qE "$HOUSE" \
  && pass "theme rotation also writes a valid init line under bash 4.2 and older" || fail "old-bash init ($(head -n1 "$x"))"
s=$(bash "$MV" new order); printf 'flowchart TD\n  A --> B\n' > "$s"
p=$(bash "$MV" show "$s" 2>/dev/null) && [ "$p" -nt "$s" ] \
  && pass "the source is written back before rendering, so the PNG is newer" || fail "PNG older than its source"

printf 'flowchart LR\n  INVALID\n' > "$tmp/bad.mmd"
err=$(bash "$MV" render "$tmp/bad.mmd" 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$err" | grep -q 'Parse error' && pass "render fails with the renderer's error on bad Mermaid" \
  || fail "bad Mermaid (rc=$rc)"

png=$(bash "$MV" show "$f" 2>/dev/null)
[ "$png" = "${f%.mmd}.png" ] && [ -s "$png" ] && pass "show renders next to the source and prints the PNG path" || fail "show ($png)"

bash "$MV" status >/dev/null && fail "status says running with no viewer" || pass "status reports no viewer"
printf '%s\nkitty\n' "$$" > "$MERMAID_VIEW_DIR/.viewer"
bash "$MV" status >/dev/null && fail "status trusts a live pid that is not a viewer" || pass "status ignores a stale pid of another process"
rm -f "$MERMAID_VIEW_DIR/.viewer"
MERMAID_VIEW_INTERVAL=0.2 bash "$MV" watch >/dev/null 2>&1 & wpid=$!
sleep 1
bash "$MV" status >/dev/null && pass "status sees a running watch viewer" || fail "status running viewer"
kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
sleep 1; b=$(bash "$MV" new broken); printf 'flowchart LR\n  INVALID\n' > "$b"; : > "$tmp/render.calls"
MERMAID_VIEW_INTERVAL=0.2 bash "$MV" watch >/dev/null 2>&1 & wpid=$!
sleep 2; kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
n=$(wc -l < "$tmp/render.calls")
[ "$n" -eq 1 ] && pass "watch tries a broken diagram once until it changes" || fail "watch re-rendered a broken diagram $n times"
rm -f "$b"

sleep 1; g=$(bash "$MV" new second); printf 'flowchart TD\n  X --> Y\n' > "$g"
: > "$tmp/shown.log"
bash "$MV" watch --once >/dev/null
grep -q "DISPLAYED ${g%.mmd}.png" "$tmp/shown.log" && pass "watch renders and shows the newest diagram" || fail "watch newest ($(cat "$tmp/shown.log"))"
[ ! -e "$MERMAID_VIEW_DIR/.viewer" ] && pass "watch removes its alive-file on exit" || fail "watch alive-file left behind"

: > "$tmp/shown.log"; echo 80x24 > "$tmp/size"
MERMAID_VIEW_SIZE="$tmp/size" MERMAID_VIEW_INTERVAL=0.2 bash "$MV" watch >/dev/null 2>&1 & wpid=$!
sleep 1; grep -q "DISPLAYED ${g%.mmd}.png 80 22" "$tmp/shown.log" && pass "watch fits the diagram to the pane below its title line" \
  || fail "watch size ($(cat "$tmp/shown.log"))"
echo 100x32 > "$tmp/size"; sleep 1
grep -q "DISPLAYED ${g%.mmd}.png 100 30" "$tmp/shown.log" && pass "watch redraws after the pane is resized" || fail "watch resize ($(cat "$tmp/shown.log"))"
kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null

opened=$(bash "$MV" open "$g") && sleep 0.2 && grep -q "DISPLAYED $opened" "$tmp/shown.log" && pass "open hands the PNG to the opener" || fail "open"

: > "$tmp/shown.log"
printf 'x' | bash "$MV" overlay "$opened" >/dev/null; sleep 0.3
[ "$(grep -c "DISPLAYED $opened" "$tmp/shown.log")" = 1 ] && pass "overlay shows the image; another key closes without opening" \
  || fail "overlay close ($(cat "$tmp/shown.log"))"
: > "$tmp/shown.log"
printf 'o' | bash "$MV" overlay "$opened" >/dev/null; sleep 0.3
[ "$(grep -c "DISPLAYED $opened" "$tmp/shown.log")" = 2 ] && pass "overlay key o hands the image to the opener" \
  || fail "overlay open ($(cat "$tmp/shown.log"))"

HOME="$tmp/home" XDG_DATA_HOME="$tmp/data" bash "$MV" install >/dev/null 2>&1
[ -s "$tmp/data/devops-mutant-powers/mermaid-view/kitty-open-actions.conf" ] && pass "install copies the kitty click rule template" \
  || fail "kitty click rule template not installed"
HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/cfg" bash "$MV" doctor 2>/dev/null | grep -q 'kitty click rule: not set up' \
  && pass "doctor reports a missing kitty click rule" || fail "doctor missing-rule line"
mkdir -p "$tmp/cfg/kitty" && cp "$HERE/kitty-open-actions.conf" "$tmp/cfg/kitty/open-actions.conf"
HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/cfg" bash "$MV" doctor 2>/dev/null | grep -q 'kitty click rule: found' \
  && pass "doctor reports the kitty click rule when it is set up" || fail "doctor found-rule line"
HOME="$tmp/nohome" XDG_CONFIG_HOME="$tmp/cfg" bash "$MV" doctor 2>/dev/null | grep -q 'kitty click rule: found, but' \
  && pass "doctor reports a click rule whose mermaid-view is not installed" || fail "doctor missing-binary line"
# A stale copy on PATH: doctor and show warn when it is another file with an older or no VERSION.
mkdir -p "$tmp/oldbin" "$tmp/nover" "$tmp/samebin"
sed 's/^VERSION="[^"]*"/VERSION="1.0.0"/' "$MV" > "$tmp/oldbin/mermaid-view"
sed '/^VERSION=/d' "$MV" > "$tmp/nover/mermaid-view"
cp "$MV" "$tmp/samebin/mermaid-view"
mkdir -p "$tmp/newbin" "$tmp/linkbin"
sed 's/^VERSION="[^"]*"/VERSION="99.0.0"/' "$MV" > "$tmp/newbin/mermaid-view"; chmod +x "$tmp/newbin/mermaid-view"
ln -s "$MV" "$tmp/linkbin/mermaid-view"
chmod +x "$tmp/oldbin/mermaid-view" "$tmp/nover/mermaid-view" "$tmp/samebin/mermaid-view"
doc=$(PATH="$tmp/oldbin:$PATH" bash "$MV" doctor 2>/dev/null) # captured: grep -q would end doctor with SIGPIPE
grep -q '\[WARN\].*older than this one' <<<"$doc" \
  && pass "doctor warns about an older mermaid-view on PATH" || fail "doctor older-copy warning"
doc=$(PATH="$tmp/nover:$PATH" bash "$MV" doctor 2>/dev/null)
grep -q '\[WARN\].*no version' <<<"$doc" \
  && pass "doctor warns about a mermaid-view on PATH without a version" || fail "doctor no-version warning"
doc=$(PATH="$tmp/samebin:$PATH" bash "$MV" doctor 2>/dev/null)
grep -q '\[WARN\]' <<<"$doc" \
  && fail "doctor warned about a copy of the same version" || pass "doctor is quiet when the copy on PATH matches"
doc=$(PATH="$tmp/newbin:$PATH" bash "$MV" doctor 2>/dev/null)
grep -q '\[WARN\]' <<<"$doc" && fail "doctor warned about a newer copy" || pass "doctor is quiet when the copy on PATH is newer"
doc=$(PATH="$tmp/linkbin:$PATH" bash "$MV" doctor 2>/dev/null)
grep -q '\[WARN\]' <<<"$doc" && fail "doctor warned about a symlink to itself" || pass "doctor is quiet when PATH links to this file"
printf 'flowchart LR\n  A --> B\n' > "$tmp/skew.mmd"
err=$(PATH="$tmp/oldbin:$PATH" bash "$MV" show "$tmp/skew.mmd" 2>&1 >/dev/null)
printf '%s' "$err" | grep -q 'older than this one' && pass "show warns about an older mermaid-view on PATH" \
  || fail "show older-copy warning ($err)"

err=$(printf 'x' | bash "$MV" overlay "$tmp/missing.png" 2>&1) && fail "overlay of a missing file succeeded" \
  || { printf '%s' "$err" | grep -q 'press any key' && pass "overlay shows its error and waits for a key" || fail "overlay error ($err)"; }

if [ "${MERMAID_VIEW_LIVE:-0}" = 1 ]; then
  unset MERMAID_VIEW_RENDERER
  for ex in "$HERE"/examples/*.mmd; do
    o="$tmp/$(basename "${ex%.mmd}").png"
    if bash "$MV" render "$ex" "$o" >/dev/null && [ "$(head -c 8 "$o" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ]; then
      pass "live render $(basename "$ex") is a PNG"
    else fail "live render $(basename "$ex")"; fi
  done
fi

[ "$fails" -eq 0 ] && { echo "mermaid-view: ALL OK"; exit 0; }
echo "mermaid-view: $fails failure(s)"; exit 1
