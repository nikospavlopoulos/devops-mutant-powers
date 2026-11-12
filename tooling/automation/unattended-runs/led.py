#!/usr/bin/env python3
"""Ledger helper for unattended runs: one durable Markdown file that says where the run is and what to do next.

usage: led.py [--ledger PATH] next TEXT | log TEXT | decision TEXT | blocked TEXT | state KEY VALUE | show
The ledger path comes from --ledger, else $LEDGER. Sections it edits: "## State" (lines "- KEY: VALUE"),
"## Next action" (replaced), "## Log", "## Decisions", "## Blocked" (appended, timestamped). See ledger-template.md.
"""
import datetime, os, re, sys

args = sys.argv[1:]
path = os.environ.get("LEDGER")
if args[:1] == ["--ledger"]:
    path, args = args[1], args[2:]
if not path or not args:
    raise SystemExit(__doc__)
cmd = args[0]
now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
s = open(path, encoding="utf-8").read()


def append(section, line):
    global s
    head = f"## {section}\n"
    i = s.index(head) + len(head)
    j = s.find("\n## ", i)
    j = len(s) if j == -1 else j + 1
    body = s[i:j].rstrip("\n")
    s = s[:i] + (body + "\n" if body.strip() else "") + line + "\n\n" + s[j:]


if cmd == "next":
    i = s.index("## Next action\n") + len("## Next action\n")
    j = s.index("\n## ", i) + 1
    s = s[:i] + args[1] + "\n\n" + s[j:]
elif cmd in ("log", "decision", "blocked"):
    append({"log": "Log", "decision": "Decisions", "blocked": "Blocked"}[cmd], f"- {now} {args[1]}")
elif cmd == "state":
    line = f"- {args[1]}: {args[2]}"  # function replacement: backslashes in VALUE stay literal
    s, n = re.subn(rf"^- {re.escape(args[1])}:.*$", lambda _: line, s, count=1, flags=re.M)
    if not n:
        raise SystemExit(f"no state key {args[1]!r} in {path}")
elif cmd != "show":
    raise SystemExit(__doc__)
if cmd == "show":
    print(s, end="")
else:
    tmp = path + ".tmp"
    open(tmp, "w", encoding="utf-8").write(s)
    os.replace(tmp, path)  # atomic: a crash never leaves half a ledger
    print(f"ledger: {cmd} ok")
