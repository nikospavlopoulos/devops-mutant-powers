#!/usr/bin/env python3
"""Write or check the Contents block at the top of Markdown documents.

usage: scripts/docs/toc.py --write FILE...    insert or refresh the block
       scripts/docs/toc.py --check FILE...    exit 1 when a block is missing or stale
       scripts/docs/toc.py --anchors FILE...  exit 1 when a heading's anchor starts or ends with a hyphen
The block lists every ## heading with its ### headings nested under it, linked by GitHub's heading anchors. It sits
between <!-- toc --> and <!-- /toc --> lines, right before the first ## heading. A file with fewer than two ##
headings gets no block.
"""
import re, sys, unicodedata

START, END, TITLE = "<!-- toc -->", "<!-- /toc -->", "## Contents"


def plain(text):
    """The text GitHub renders for a heading: link text, no tags, no code ticks, no bold or italic markers."""
    t = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text.strip())
    t = re.sub(r"<[^>]+>", "", t).replace("`", "")
    return re.sub(r"(\*\*|\*)(.+?)\1", r"\2", t)  # a space beside a removed tag stays, as on GitHub


def slug(text):
    """GitHub's anchor: lower case, punctuation dropped, each space a hyphen."""
    s = plain(text).lower()
    s = "".join(c for c in s if c.isalnum() or c in "-_ " or unicodedata.category(c).startswith("M"))
    return s.replace(" ", "-")


def headings(lines):
    """(index, level, text) for every ATX heading outside fenced code."""
    fence, out = None, []
    for i, line in enumerate(lines):
        m = re.match(r"^\s*(```+|~~~+)", line)
        if m:
            fence = None if fence and m.group(1)[0] == fence[0] else (fence or m.group(1))
            continue
        h = None if fence else re.match(r"^(#{1,6})\s+(.*?)\s*#*\s*$", line)
        if h:
            out.append((i, len(h.group(1)), h.group(2)))
    return out


def strip_block(lines):
    if START not in lines or END not in lines:
        return lines
    a, b = lines.index(START), lines.index(END)
    rest = lines[:a] + lines[b + 1:]
    if 0 < a < len(rest) and rest[a - 1] == "" and rest[a] == "":
        del rest[a]  # the blank line the block added after itself
    return rest


def link_text(text):
    t = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)
    return t.replace("[", r"\[").replace("]", r"\]")


def build(lines):
    """The file's lines with a current block (or with none when it has fewer than two ## headings)."""
    base = strip_block(lines)
    hs = headings(base)
    if sum(1 for _, level, _ in hs if level == 2) < 2:
        return base
    seen, entries = {"contents": 1}, []  # the block's own heading takes the "contents" anchor
    for _, level, text in hs:
        s = slug(text)
        n = seen.get(s, 0)
        seen[s] = n + 1
        if level in (2, 3):
            entries.append(("  " if level == 3 else "") + f"- [{link_text(text)}](#{s if n == 0 else f'{s}-{n}'})")
    first = next(i for i, level, _ in hs if level == 2)
    lead = [] if first == 0 or base[first - 1] == "" else [""]
    return base[:first] + lead + [START, "", TITLE, ""] + entries + ["", END, ""] + base[first:]


def bad_anchors(lines):
    """(line number, anchor) for headings whose anchor starts or ends with '-': a space beside inline HTML."""
    return [(i + 1, slug(text)) for i, _, text in headings(lines) if slug(text)[:1] == "-" or slug(text)[-1:] == "-"]


def main(argv):
    if len(argv) >= 2 and argv[0] == "--anchors":
        bad = 0
        for path in argv[1:]:
            for n, anchor in bad_anchors(open(path, encoding="utf-8").read().split("\n")):
                print(f"  FAIL {path}:{n}: heading anchor '#{anchor}' starts or ends with a hyphen (a space beside inline HTML)")
                bad += 1
        return 1 if bad else 0
    if len(argv) < 2 or argv[0] not in ("--write", "--check"):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    stale = 0
    for path in argv[1:]:
        lines = open(path, encoding="utf-8").read().split("\n")
        new = build(lines)
        if new == lines:
            continue
        if argv[0] == "--write":
            open(path, "w", encoding="utf-8").write("\n".join(new))
            print(f"contents written: {path}")
        else:
            print(f"  FAIL {path}: Contents block missing or stale (run scripts/docs/toc.py --write {path})")
            stale += 1
    if argv[0] == "--check":
        print(f"toc: {len(argv) - 1} file(s), " + ("ALL OK" if not stale else f"{stale} to refresh"))
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
