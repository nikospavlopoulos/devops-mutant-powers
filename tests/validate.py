#!/usr/bin/env python3
"""Structural validation for devops-mutant-powers. Run via tests/validate.sh.

Every failure has a stable id ("check:file[:detail]"). An optional tests/known-failures.txt ratchet (empty and
deleted at 1.0.0) may list ids as KNOWN during a staged migration; listed ids that no longer fail are STALE and
fail the run, so the ratchet only tightens.
"""
import json, os, re, subprocess, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PLUGIN = "devops-mutant-powers"
SELF_FILES = {"tests/validate.py", "tests/known-failures.txt", "tests/known-wrong-claims.txt", "scripts/upstream-drift.sh"}
HISTORY_FILES = {"README.md", "LICENSE", "CHANGELOG.md", "UPSTREAM.md"}
HISTORY_DIRS = ("docs/maintenance/", "private/")  # retrospective text may name the predecessor and removed harnesses
EXEC_PATTERNS = [r"^hooks/(session-start|run-hook\.cmd)$", r"^\.githooks/[^/]+$", r"^scripts/[^/]+\.sh$",
                 r"^skills/[^/]+/scripts/[^/]+$", r"^tests/.+\.sh$", r"^tooling/.+\.sh$"]
TEXT_EXT = (".md", ".json", ".sh", ".py", ".yaml", ".yml", ".toml", ".txt", ".js", ".ts", ".cjs", ".cmd", "")
DESC_MIN, DESC_MAX = 40, 500  # below the Agent Skills spec cap (1,024); mind Claude Code's listing budget
SKILL_MAX_BYTES = 20000  # a compaction keeps the first 5,000 tokens (about this many characters) of each invoked skill

PRIVATE = "private/"  # unpublishable material: exempt from every check except check_private_links
failures = {}


def fail(fid, msg):
    failures.setdefault(fid, msg)


def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True, check=True).stdout


IN_GIT = subprocess.run(["git", "-C", ROOT, "rev-parse", "--is-inside-work-tree"], capture_output=True, text=True).stdout.strip() == "true"


def files():
    """Every file; callers that check public content skip private/ (see PRIVATE and main)."""
    if IN_GIT:
        out = git("ls-files", "-co", "--exclude-standard")
        return sorted(f for f in out.splitlines() if f and os.path.isfile(os.path.join(ROOT, f)))
    # Snapshot mode (hooks validate an exported index/commit): walk the directory.
    found = []
    for d, dirs, fs in os.walk(ROOT):
        dirs[:] = [x for x in dirs if x != ".git"]
        found += [os.path.relpath(os.path.join(d, f), ROOT) for f in fs]
    return sorted(found)


def read(rel):
    try:
        with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
            return f.read()
    except (UnicodeDecodeError, OSError):
        return None


def is_history(rel):
    return rel in HISTORY_FILES or rel.startswith(HISTORY_DIRS)


def strip_fences(text):
    """Yield (lineno, line) outside fenced code blocks."""
    fence = None
    for i, line in enumerate(text.splitlines(), 1):
        m = re.match(r"^\s*(```+|~~~+)", line)
        if m:
            fence = None if fence and m.group(1)[0] == fence[0] else (fence or m.group(1))
            continue
        if not fence:
            yield i, line


def frontmatter(text):
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---", 4)
    if end < 0:
        return None
    block, data, key = text[4:end].splitlines(), {}, None
    for line in block:
        m = re.match(r"^([A-Za-z_-]+):\s*(.*)$", line)
        if m:
            key, val = m.group(1), m.group(2).strip()
            data[key] = "" if val in (">", "|", ">-", "|-") else val.strip("\"'")
        elif key and line.startswith((" ", "\t")):
            data[key] = (data[key] + " " + line.strip()).strip()
    return data


def check_skills(skill_dirs):
    for d in skill_dirs:
        rel = f"skills/{d}/SKILL.md"
        text = read(rel)
        if text is None:
            fail(f"frontmatter:{rel}", "missing SKILL.md")
            continue
        size = os.path.getsize(os.path.join(ROOT, rel))  # bytes: stricter than characters for non-ASCII text
        if size >= SKILL_MAX_BYTES:
            fail(f"skill-size:{rel}", f"{rel} is {size} bytes (limit: under {SKILL_MAX_BYTES}); move content the "
                 "skill needs only sometimes into its references/")
        m = re.search(r"^description:[ \t]*(.*)$", text, re.M)
        if m and m.group(1)[:1] not in "\"'|>" and re.search(r": | #", m.group(1)):
            fail(f"desc-yaml:{rel}", f"{rel} description has an unquoted ': ' or ' #' (invalid YAML: harnesses may "
                 "drop the description or the skill); quote the value")
        fm = frontmatter(text)
        if not fm or not fm.get("name") or not fm.get("description"):
            fail(f"frontmatter:{rel}", "missing name/description frontmatter")
            continue
        if fm["name"] != d:
            fail(f"frontmatter-name:{rel}", f"name '{fm['name']}' != directory '{d}'")
        dl = len(fm["description"])
        if not DESC_MIN <= dl <= DESC_MAX:  # routing lives in descriptions; the spec caps them at 1,024
            fail(f"desc-len:{rel}", f"{rel} description is {dl} chars (allowed {DESC_MIN}-{DESC_MAX})")


def check_bootstrap_routing(skill_dirs):
    """The bootstrap routes like obra's: skill descriptions carry the triggers; its examples must name real skills."""
    boot = [d for d in skill_dirs if d == f"using-{PLUGIN}"]
    if len(boot) != 1:
        fail("bootstrap:skills", f"expected exactly one using-* bootstrap skill, found {boot}")
        return
    rel = f"skills/{boot[0]}/SKILL.md"
    text = read(rel) or ""
    if len(text.splitlines()) > 120:
        fail(f"bootstrap-size:{rel}", f"{len(text.splitlines())} lines (budget 120)")
    for _, line in strip_fences(text.split("\n---\n", 1)[-1]):
        for tok in re.findall(r"`([^`]+)`", line):
            name = tok.split(":", 1)[1] if tok.startswith(PLUGIN + ":") else tok
            if re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)+|[a-z]{4,}", name) and name not in skill_dirs:
                fail(f"trigger:{name}", f"{rel} routes to '{name}' but skills/{name}/ does not exist")


def resolve(rel_file, target):
    target = target.split("#", 1)[0]
    if not target:
        return True
    base = os.path.dirname(os.path.join(ROOT, rel_file))
    cands = [os.path.normpath(os.path.join(base, target))]
    m = re.match(r"^(skills/[^/]+)/", rel_file)
    if m:  # inside a skill, paths are conventionally relative to the skill root
        cands.append(os.path.normpath(os.path.join(ROOT, m.group(1), target)))
    if re.match(r"^(tooling|docs|skills|scripts|tests|hooks|commands|agents|evals)/", target):
        cands.append(os.path.join(ROOT, target))
    return any(os.path.exists(c) for c in cands)


MD_LINK = re.compile(r"\]\(([^)\s]+)\)")
HTML_SRC = re.compile(r"""(?<![\w-])(src|srcset)\s*=\s*["']([^"']+)["']""")


def html_targets(line):
    """Paths in HTML src/srcset attributes outside inline code spans (GitHub renders the HTML, not the spans)."""
    out = []
    for attr, value in HTML_SRC.findall(re.sub(r"`[^`]*`", "", line)):
        out += [c.split()[0] for c in value.split(",") if c.strip()] if attr == "srcset" else [value]
    return out


def check_private_links(all_files):
    """No file outside private/ may link to a path that resolves under private/."""
    priv = os.path.join(ROOT, "private")
    for rel in all_files:
        if rel.startswith(PRIVATE) or not rel.endswith(".md"):
            continue
        for n, line in enumerate((read(rel) or "").splitlines(), 1):
            for t in MD_LINK.findall(line) + html_targets(line):
                t = t.split("#", 1)[0]
                if not t or re.match(r"^(https?:|mailto:|data:|//|<|\$|~)", t):
                    continue
                for base in (os.path.dirname(os.path.join(ROOT, rel)), ROOT):
                    p = os.path.normpath(os.path.join(base, t))
                    if p == priv or p.startswith(priv + os.sep):
                        fail(f"private-link:{rel}", f"{rel}:{n} links into private/ -> {t}")
                        break


PUBLIC_FILE_LIMIT = 512  # files outside private/ are what a release exports; test-export-list.sh checks the export


def check_public_file_count(all_files):
    if len(all_files) > PUBLIC_FILE_LIMIT:
        fail("public-file-count", f"{len(all_files)} files outside private/ (limit {PUBLIC_FILE_LIMIT}); move "
             "unpublishable material under private/")


def check_links(all_files):
    md = [f for f in all_files if f.endswith(".md") and (f.startswith(("skills/", "docs/", "commands/", "agents/"))
                                                       or re.match(r"^tooling/.+/README\.md$", f)
                                                       or f in ("README.md", "AGENTS.md", "CLAUDE.md", "UPSTREAM.md", "CHANGELOG.md", "evals/README.md"))]
    for rel in md:
        text = read(rel) or ""
        for n, line in strip_fences(text):
            if "validate:ignore-links" in line:
                continue
            targets = re.findall(r"\]\(([^)\s]+)\)", line) + html_targets(line)
            for code in re.findall(r"`([^`\s]+)`", line):
                if re.match(r"^\.{1,2}/[^<>*{}$]+$", code) or \
                   re.match(r"^(references|scripts|templates|prompts)/[^<>*{}$]+\.(md|sh|py|js|json|ya?ml|txt)$", code) or \
                   re.match(r"^(tooling|docs|tests|hooks)/[^<>*{}$]+\.[a-z]+$", code) or \
                   re.match(r"^tooling/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*/?$", code):  # template dirs, no extension
                    targets.append(code)
            for t in targets:
                if re.match(r"^(https?:|mailto:|data:|//|#|<|\$|~)", t) or "*" in t:
                    continue
                if not resolve(rel, t):
                    fail(f"link:{rel}:{t}", f"{rel}:{n} broken link -> {t}")


XREF = re.compile(r"(?<![A-Za-z0-9_.-])(devops-mutant-powers|superpowers):([a-z0-9][a-z0-9-]*)")
OLD = re.compile(r"(?<![-A-Za-z0-9_./])superpowers-devops")  # owner/name slugs are upstream references


OLDNAME = re.compile(r"nikos-superpowers-devops|nikos_superpowers_devops|NikosSuperpowersDevops|"
                     r"Nikos Superpowers DevOps|NIKOS-SUPERPOWERS-DEVOPS")  # the pre-2.0 name, banned outside private/


def check_names(all_files, skill_dirs):
    for rel in all_files:
        if rel in SELF_FILES or not rel.endswith(TEXT_EXT):
            continue
        text = read(rel)
        if text is None:
            continue
        for n, line in enumerate(text.splitlines(), 1):
            for prefix, skill in XREF.findall(line):
                if prefix == PLUGIN:
                    if skill not in skill_dirs and not os.path.exists(os.path.join(ROOT, "commands", skill + ".md")):
                        fail(f"xref:{rel}:{skill}", f"{rel}:{n} {prefix}:{skill} does not resolve")
                # `superpowers:<skill>` is an upstream (obra/superpowers) cross-reference and stays
            if OLD.search(line) and not is_history(rel) and not XREF.search(line.replace(PLUGIN, "")):
                fail(f"oldname:{rel}", f"{rel}:{n} still names 'superpowers-devops'")
            if OLDNAME.search(line):
                fail(f"oldname:{rel}", f"{rel}:{n} still names the predecessor plugin 'nikos-superpowers-devops'")
            if re.search(r"(?i)\bgemini\b", line) and not re.search(r"~/\.gemini|\.gemini/", line) and not is_history(rel):
                fail(f"gemini:{rel}", f"{rel}:{n} mentions Gemini outside Antigravity's ~/.gemini paths")
            if re.match(r"^(<<<<<<<|>>>>>>>) ", line):
                fail(f"conflict:{rel}", f"{rel}:{n} conflict marker")


VERSION_REF = ".claude-plugin/plugin.json"
# Every manifest that may carry the plugin version; each is compared only when it exists and has one.
VERSIONED_MANIFESTS = (VERSION_REF, ".claude-plugin/marketplace.json", "plugin.json", "package.json",
                       ".cursor-plugin/plugin.json", ".codex-plugin/plugin.json", ".agents/plugins/marketplace.json")
JS_VERSION = re.compile(r"""\bversion\s*:\s*['"]([^'"]*)['"]""")


def check_json_and_versions(all_files):
    parsed = {}
    for rel in all_files:
        if not rel.endswith(".json"):
            continue
        try:
            parsed[rel] = json.loads(read(rel) or "")
        except json.JSONDecodeError as e:
            fail(f"json:{rel}", f"{rel}: invalid JSON ({e})")
    versions = {}
    for rel in VERSIONED_MANIFESTS:
        data = parsed.get(rel)
        if not isinstance(data, dict):
            continue
        if rel.endswith("marketplace.json"):  # versions live on the plugin entries
            for i, p in enumerate(data.get("plugins", [])):
                if isinstance(p, dict) and "version" in p:
                    versions[f"{rel}:plugins[{i}]"] = p["version"]
        elif "version" in data:
            versions[rel] = data["version"]
    for rel in all_files:  # OpenCode modules: a hard-coded version literal must match too
        if rel.startswith(".opencode/plugins/") and rel.endswith((".js", ".mjs", ".cjs", ".ts")):
            for m in JS_VERSION.finditer(read(rel) or ""):
                versions[f"{rel}:version"] = m.group(1)
    ref = versions.get(VERSION_REF)
    if not isinstance(ref, str) or not ref:
        fail(f"version-parity:{VERSION_REF}", f"{VERSION_REF} has no version (the reference for every other manifest)")
        return
    for where, v in sorted(versions.items()):
        if v != ref:
            fail(f"version-parity:{where}", f"{where} version {v!r} != {VERSION_REF} {ref!r}")


def check_modes_and_syntax(all_files):
    staged = {}
    for line in (git("ls-files", "-s") if IN_GIT else "").splitlines():
        mode, _, _, path = line.split(None, 3)
        staged[path] = mode
    for rel in all_files:
        if any(re.match(p, rel) for p in EXEC_PATTERNS):
            mode = staged.get(rel) or ("100755" if os.access(os.path.join(ROOT, rel), os.X_OK) else "100644")
            if mode != "100755":
                fail(f"mode:{rel}", f"{rel} must be executable in git (mode {mode})")
        text = read(rel)
        if text is None:
            continue
        first = text.split("\n", 1)[0]
        if rel.endswith(".sh") or re.match(r"^#!.*\b(bash|sh)\b", first):
            if rel == "hooks/run-hook.cmd":
                continue  # cmd/bash polyglot
            shell = "sh" if re.match(r"^#!\s*/bin/sh\b", first) else "bash"
            r = subprocess.run([shell, "-n", os.path.join(ROOT, rel)], capture_output=True, text=True)
            if r.returncode:
                fail(f"syntax:{rel}", f"{rel}: {shell} -n failed: {r.stderr.strip()[:200]}")
        elif rel.endswith(".py"):
            try:
                compile(text, rel, "exec")
            except SyntaxError as e:
                fail(f"syntax:{rel}", f"{rel}: {e}")


def check_wrong_claims(all_files):
    path = os.path.join(ROOT, "tests", "known-wrong-claims.txt")
    if not os.path.exists(path):
        return
    rules = []
    for line in open(path, encoding="utf-8"):
        if line.strip() and not line.startswith("#"):
            rx, _, reason = line.rstrip("\n").partition("\t")
            rules.append((re.compile(rx), reason))
    for rel in all_files:
        if rel in SELF_FILES or not rel.startswith(("skills/", "docs/", "tooling/", "commands/", "agents/")):
            continue
        text = read(rel) or ""
        for rx, reason in rules:
            if rx.search(text):
                fail(f"wrong-claim:{rel}:{rx.pattern}", f"{rel}: {reason}")


PLACEHOLDER = re.compile(r"(?<!\\)\$[0-9]")


def check_placeholders(all_files):
    """Claude Code replaces $0, $1, ... in skill and command bodies with invocation arguments, even inside code blocks."""
    for rel in all_files:
        if not (re.fullmatch(r"skills/[^/]+/SKILL\.md", rel) or re.fullmatch(r"commands/[^/]+\.md", rel)):
            continue
        for n, line in enumerate((read(rel) or "").splitlines(), 1):
            if PLACEHOLDER.search(line):
                fail(f"placeholder:{rel}:{n}", f"{rel}:{n} has an unescaped $<digit> that Claude Code substitutes with an argument")


TOOL_MARKUP = re.compile(r"^</(content|invoke|parameter)>\s*$")


def check_tool_markup(all_files):
    """A file written through an agent's tool call must not end with that call's closing markup."""
    for rel in all_files:
        if not rel.endswith(".md"):
            continue
        for n, line in enumerate((read(rel) or "").splitlines(), 1):
            if TOOL_MARKUP.match(line):
                fail(f"tool-markup:{rel}:{n}", f"{rel}:{n} has leftover tool-call markup '{line.strip()}'")


def check_mermaid_view_plugin():
    """mermaid-view names its folders after the plugin; a rename must not leave them behind."""
    rel = "tooling/visual/mermaid-view/mermaid-view.sh"
    m = re.search(r'^PLUGIN="([^"]+)"', read(rel) or "", re.M)
    try:
        manifest = json.loads(read(".claude-plugin/plugin.json") or "{}")
    except json.JSONDecodeError:
        return  # check_json_and_versions reports it
    name = manifest.get("name")
    if not m:
        fail(f"mermaid-view-plugin:{rel}", f"{rel} has no PLUGIN=\"...\" setting")
    elif m.group(1) != name:
        fail(f"mermaid-view-plugin:{rel}", f"{rel} PLUGIN={m.group(1)!r} != .claude-plugin/plugin.json name {name!r}")
    v = re.search(r'^VERSION="([^"]+)"', read(rel) or "", re.M)  # lets doctor/show spot a stale copy on PATH
    if not v or v.group(1) != manifest.get("version"):
        fail(f"mermaid-view-version:{rel}", f"{rel} VERSION={v.group(1) if v else None!r} != .claude-plugin/plugin.json "
             f"version {manifest.get('version')!r} (bump it with the manifests)")


def check_antigravity_rule():
    """rules/devops-mutant-powers.md is generated from the bootstrap skill; it must not drift."""
    gen, rule = os.path.join(ROOT, "scripts", "build-antigravity-rule.sh"), os.path.join(ROOT, "rules", f"{PLUGIN}.md")
    if not os.path.exists(gen):
        return
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, "rule.md")
        r = subprocess.run(["bash", gen, out], capture_output=True, text=True)
        if r.returncode:
            fail("agy-rule-build:scripts/build-antigravity-rule.sh", f"rule generator failed: {r.stderr.strip()[:200]}")
            return
        want = open(out, encoding="utf-8").read()
    have = open(rule, encoding="utf-8").read() if os.path.exists(rule) else ""
    if want != have:
        fail(f"agy-rule-drift:rules/{PLUGIN}.md", f"rules/{PLUGIN}.md is stale — run scripts/build-antigravity-rule.sh")
    if not have.startswith("---\ntrigger: always_on\n"):
        fail(f"agy-rule-trigger:rules/{PLUGIN}.md", "Antigravity bootstrap rule must start with 'trigger: always_on' frontmatter")


MARK_BEGIN, MARK_END = "BEGIN-" + "INTERNAL", "END-" + "INTERNAL"  # built in pieces: this file is exported


def check_internal_markers(all_files):
    """The begin and end internal markers come in pairs: never nested, never left open (Copybara removes each block)."""
    for rel in all_files:
        text = read(rel)
        if text is None:
            continue
        open_at = None
        for n, line in enumerate(text.splitlines(), 1):
            if MARK_BEGIN in line:
                if open_at:
                    fail(f"internal-marker:{rel}", f"{rel}:{n} internal block opened inside the one opened at line {open_at}")
                open_at = n
            if MARK_END in line:
                if not open_at:
                    fail(f"internal-marker:{rel}", f"{rel}:{n} internal block closed but never opened")
                open_at = None
        if open_at:
            fail(f"internal-marker:{rel}", f"{rel}:{open_at} internal block opened but never closed")


def check_agent_tools(all_files):
    """An agent's tools and disallowedTools are YAML lists: Claude Code also takes a comma string, Antigravity does not."""
    for rel in all_files:
        if not (rel.startswith("agents/") and rel.endswith(".md")):
            continue
        text = read(rel) or ""
        if not text.startswith("---\n") or text.find("\n---", 4) < 0:
            continue
        for n, line in enumerate(text[4:text.find("\n---", 4)].splitlines(), 2):
            m = re.match(r"^(tools|disallowedTools):(.*)$", line)
            value = re.sub(r"(^|\s)#.*$", "", m.group(2)).strip() if m else ""  # a YAML comment is not a value
            if value and not re.fullmatch(r"\[[^\[\]]*\]", value):  # exactly one [A, B] list
                fail(f"agent-tools:{rel}", f"{rel}:{n} '{m.group(1)}' must be a YAML list (one '- Tool' per line, or [A, B])")


BINARY_EXT = (".png", ".jpg", ".jpeg", ".gif", ".ico", ".webp", ".pdf", ".zip", ".gz", ".jar", ".woff", ".woff2")


def check_encoding(all_files):
    """Every public file except known binary types is UTF-8: read() skips a file it cannot decode, so name it here."""
    for rel in all_files:
        if rel.lower().endswith(BINARY_EXT):
            continue
        try:
            with open(os.path.join(ROOT, rel), "rb") as f:
                f.read().decode("utf-8")
        except UnicodeDecodeError as e:
            fail(f"encoding:{rel}", f"{rel}: not valid UTF-8 (byte {e.start})")
        except OSError:
            continue


SUITES = (r"^tests/(scan|hooks|scripts)/test-[^/]+\.sh$", r"^tooling/[^/]+/[^/]+/test-[^/]+\.sh$")  # run-quick.sh's globs


def check_suite_docs(all_files):
    """Every offline suite tests/run-quick.sh runs is named in docs/testing.md, so its table stays complete."""
    doc = read("docs/testing.md") or ""  # a missing page fails every suite, never passes silently
    for rel in all_files:
        if any(re.match(p, rel) for p in SUITES) and f"`{rel}`" not in doc:
            fail(f"suite-doc:{rel}", f"{rel} is not listed in docs/testing.md (Offline self-test suites)")


def run_helper(check, script, args):
    """Run a helper script and return its FAIL lines; a non-zero exit with none means it did not finish (a failure)."""
    r = subprocess.run([sys.executable, "-I", script, *args], cwd=ROOT, capture_output=True, text=True, errors="replace")
    found = [l.strip()[5:] for l in r.stdout.splitlines() if l.strip().startswith("FAIL ")]
    if r.returncode != 0 and not found:
        last = next((l.strip() for l in reversed((r.stderr or r.stdout).splitlines()) if l.strip()), "no output")
        fail(f"{check}:helper", f"{check}: {os.path.relpath(script, ROOT)} did not finish (exit {r.returncode}): {last}")
    return found


def check_heading_anchors(all_files):
    """No README or docs heading gets an anchor starting or ending with '-' (scripts/docs/toc.py --anchors)."""
    pages = [f for f in all_files if f == "README.md" or (f.startswith("docs/") and f.endswith(".md"))]
    if not pages:
        return
    script = os.path.join(ROOT, "scripts", "docs", "toc.py")
    if not os.path.exists(script):
        fail("heading-anchor:script", "scripts/docs/toc.py is missing (heading anchors not checked)")
        return
    for line in run_helper("heading-anchor", script, ["--anchors", *pages]):
        fail(f"heading-anchor:{line.split(':', 1)[0]}", line)


def check_contents(all_files):
    """Every page in docs/ with two or more ## sections opens with a current Contents block (scripts/docs/toc.py)."""
    docs = [f for f in all_files if f.startswith("docs/") and f.endswith(".md")]
    if not docs:
        return
    script = os.path.join(ROOT, "scripts", "docs", "toc.py")
    if not os.path.exists(script):
        fail("contents:script", "scripts/docs/toc.py is missing")
        return
    for line in run_helper("contents", script, ["--check", *docs]):
        fail(f"contents:{line.split(':', 1)[0]}", line)


def check_mermaid(all_files):
    """Mermaid diagram style for the public docs (GitHub's defaults); same rules as scripts/docs/check-mermaid.py."""
    md = [f for f in all_files if f.endswith(".md") and not f.startswith(("evals/", "tests/"))]
    md = [f for f in md if "```mermaid" in (read(f) or "")]
    if not md:
        return
    script = os.path.join(ROOT, "scripts", "docs", "check-mermaid.py")
    if not os.path.exists(script):
        fail("mermaid:script", "scripts/docs/check-mermaid.py is missing")
        return
    for line in run_helper("mermaid", script, md):
        where = line.split(":", 2)
        fail(f"mermaid:{where[0]}:{where[1] if len(where) > 1 else ''}", line)


def main():
    every = files()
    all_files = [f for f in every if not f.startswith(PRIVATE)]
    skill_dirs = sorted(d for d in os.listdir(os.path.join(ROOT, "skills")) if os.path.isdir(os.path.join(ROOT, "skills", d)))
    check_skills(skill_dirs)
    check_bootstrap_routing(skill_dirs)
    check_private_links(every)
    check_public_file_count(all_files)
    check_links(all_files)
    check_names(all_files, skill_dirs)
    check_json_and_versions(all_files)
    check_modes_and_syntax(all_files)
    check_wrong_claims(all_files)
    check_placeholders(all_files)
    check_tool_markup(all_files)
    check_mermaid_view_plugin()
    check_antigravity_rule()
    check_encoding(all_files)
    check_suite_docs(all_files)
    check_mermaid(all_files)
    check_contents(all_files)
    check_internal_markers(all_files)
    check_agent_tools(all_files)
    check_heading_anchors(all_files)

    known = set()
    kpath = os.path.join(ROOT, "tests", "known-failures.txt")
    if os.path.exists(kpath):
        known = {l.strip() for l in open(kpath, encoding="utf-8") if l.strip() and not l.startswith("#")}
    if "--emit-known" in sys.argv:
        print("\n".join(sorted(failures)))
        return 0
    new = sorted(f for f in failures if f not in known)
    stale = sorted(k for k in known if k not in failures)
    for fid in sorted(failures):
        print(("  KNOWN " if fid in known else "  FAIL  ") + failures[fid])
    for fid in stale:
        print(f"  STALE {fid} (fixed — remove it from tests/known-failures.txt)")
    print(f"validate: {len(failures)} failing ({len(failures) - len(new)} known), {len(stale)} stale")
    if new or stale:
        print("FAILED")
        return 1
    print("ALL OK" if not failures else "OK (known failures remain — ratchet)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
