#!/usr/bin/env python3
"""3-way drift report (and optional merge) between this repo and two upstream obra/superpowers tags.

The rename map is applied to the extracted base/theirs trees first, so renamed names never show up as conflicts.
usage: upstream_drift.py REPO UPSTREAM_CLONE BASE_TAG THEIRS_TAG OUT_DIR [--merge] [--paths skills,hooks]
"""
import filecmp, io, os, re, shutil, subprocess, sys, tarfile

PLUGIN = "devops-mutant-powers"
BOOT_UP, BOOT_OURS = "using-superpowers", f"using-{PLUGIN}"
TEXT_RULES = [
    # upstream namespace -> ours; skips obra/superpowers, diagnosing-superpowers, .superpowers/, ~/.config/superpowers
    (re.compile(r"(?<![A-Za-z0-9_./-])superpowers:"), f"{PLUGIN}:"),
    (re.compile(r"(?<![A-Za-z0-9_-])using-superpowers(?![A-Za-z0-9_-])"), BOOT_OURS),
]


def extract(clone, tag, dest):
    data = subprocess.run(["git", "-C", clone, "archive", tag], capture_output=True, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(data)) as t:
        t.extractall(dest, filter="data")


def rename_tree(root):
    up = os.path.join(root, "skills", BOOT_UP)
    if os.path.isdir(up):
        os.rename(up, os.path.join(root, "skills", BOOT_OURS))
    for d, _, files in os.walk(root):
        for fn in files:
            p = os.path.join(d, fn)
            try:
                text = open(p, encoding="utf-8").read()
            except (UnicodeDecodeError, OSError):
                continue
            new = text
            for rx, rep in TEXT_RULES:
                new = rx.sub(rep, new)
            if new != text:
                open(p, "w", encoding="utf-8").write(new)


def state(a, b):
    if os.path.isfile(a) and os.path.isfile(b):
        return "=" if filecmp.cmp(a, b, shallow=False) else "M"
    if os.path.isfile(a):
        return "D"
    if os.path.isfile(b):
        return "A"
    return "."


def rel_files(*roots, sub):
    out = set()
    for r in roots:
        top = os.path.join(r, sub)
        for d, _, files in os.walk(top):
            out.update(os.path.relpath(os.path.join(d, f), r) for f in files)
    return sorted(out)


ACTIONS = {"=M": "take-upstream", "=D": "upstream-deleted", "MM": "MERGE", "M=": "keep-ours", "MD": "CONFLICT-ours-edited-upstream-deleted",
           "DM": "decide-ours-deleted-upstream-changed", "D=": "keep-deleted", ".A": "new-upstream", "A.": "ours-only", "DD": "both-deleted",
           "AA": "both-added", "==": None}


def main():
    repo, clone, base_tag, theirs_tag, out = sys.argv[1:6]
    merge = "--merge" in sys.argv
    subs = ["skills", "hooks"]
    if "--paths" in sys.argv:
        subs = sys.argv[sys.argv.index("--paths") + 1].split(",")
    base, theirs = os.path.join(out, "base"), os.path.join(out, "theirs")
    for p in (base, theirs):
        shutil.rmtree(p, ignore_errors=True)
        os.makedirs(p)
    extract(clone, base_tag, base)
    extract(clone, theirs_tag, theirs)
    rename_tree(base)
    rename_tree(theirs)
    merged = os.path.join(out, "merged")
    rows, conflicts = [], 0
    for sub in subs:
        for rel in rel_files(base, theirs, repo, sub=sub):
            b, t, o = (os.path.join(x, rel) for x in (base, theirs, repo))
            key = state(b, o) + state(b, t)
            act = ACTIONS.get(key, "?")
            if not act:
                continue
            note = ""
            if merge and act == "MERGE":
                dest = os.path.join(merged, rel)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                shutil.copyfile(o, dest)
                r = subprocess.run(["git", "merge-file", "-L", "ours", "-L", "base", "-L", "theirs", dest, b, t], capture_output=True)
                n = r.returncode if r.returncode > 0 else 0
                conflicts += n
                note = f"{n} conflict(s)" if n else "clean"
            elif merge and act in ("take-upstream", "new-upstream"):
                dest = os.path.join(merged, rel)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                shutil.copyfile(t, dest)
            rows.append((rel, key, act, note))
    w = max((len(r[0]) for r in rows), default=10)
    for rel, key, act, note in rows:
        print(f"{rel:<{w}}  {key}  {act}  {note}".rstrip())
    if merge:
        print(f"\nmerge outputs: {merged}  (total conflict hunks: {conflicts})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
