#!/usr/bin/env python3
"""Audit a skill that was split into a small core + references: nothing may be lost or changed by the split.

usage: scripts/skills/slim-audit.py <skill> [--base REF]   (REF defaults to HEAD; run before committing the split)
Fails (exit 1) if, compared with REF:
  - the frontmatter changed (it decides triggering), or
  - the "## Core Rules" or "## Output Contract" section is not word for word the same.
Warns for every removed line (25+ characters, normalised whitespace) that appears neither in the new SKILL.md nor
in any file under skills/<skill>/references/. Each warning must be explained: reworded, condensed or an exact duplicate.
"""
import glob, os, re, subprocess, sys

args = sys.argv[1:]
base = "HEAD"
if "--base" in args:
    i = args.index("--base"); base = args[i + 1]; del args[i:i + 2]
skill = args[0]
root = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
rel = f"skills/{skill}/SKILL.md"
old = subprocess.run(["git", "-C", root, "show", f"{base}:{rel}"], capture_output=True, text=True, check=True).stdout
new = open(os.path.join(root, rel), encoding="utf-8").read()
fail = 0


def frontmatter(t): return t.split("\n---\n", 1)[0]


def section(t, name):
    m = re.search(rf"^## {re.escape(name)}[^\n]*\n(.*?)(?=^## |\Z)", t, re.S | re.M)
    return m.group(1).strip() if m else None


if frontmatter(old) != frontmatter(new):
    print("FAIL frontmatter changed"); fail = 1
for name in ("Core Rules", "Output Contract"):
    if section(old, name) != section(new, name):
        print(f"FAIL section '{name}' differs (must be word for word)"); fail = 1
norm = lambda x: re.sub(r"\s+", " ", x).strip()
pool = norm(new) + " " + " ".join(norm(open(f, encoding="utf-8").read())
                                  for f in glob.glob(os.path.join(root, f"skills/{skill}/references/*.md")))
missing = []
for line in old.splitlines():
    text = norm(re.sub(r"^\s*(?:[-*]|\d+\.)\s+", "", line))
    if len(text) < 25 or text.startswith(("|---", "```", "#")):
        continue
    if text not in pool:
        missing.append(line.strip()[:160])
if missing:
    print(f"WARN {len(missing)} removed line(s) not found verbatim — explain each (reworded, condensed or duplicate):")
    for m in missing: print("  -", m)
print(f"SKILL.md chars {len(old)} -> {len(new)} ({(len(new) - len(old)) * 100 // max(len(old), 1)}%)")
sys.exit(fail)
