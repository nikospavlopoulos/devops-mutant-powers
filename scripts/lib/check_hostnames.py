#!/usr/bin/env python3
"""Hostname rule for scan-sensitive.sh: only reserved, allowlisted or path-scoped repo hosts may appear.

usage: check_hostnames.py ROOT DIFF_FILE|'' LABEL      (check a unified diff, or the working tree when DIFF_FILE is '')
       check_hostnames.py ROOT --collect PATH...       (print registrable domains found under PATHs)
       check_hostnames.py ROOT --identity              (print this repo's hosts, SSH aliases and paths as JSON)
"""
import os, re, subprocess, sys

# Unambiguous TLDs only: file extensions and method names (.info, .sh, .md, .me) would cause false positives.
TLDS = "com net org io dev gr eu cloud app ai uk de fr nl local internal lan corp arpa gov edu google us co cy".split()
HOST_RE = re.compile(r"(?<![A-Za-z0-9_.-])((?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+(?:%s))(?![A-Za-z0-9_-]|\.[A-Za-z])" % "|".join(TLDS), re.I)  # not a file name such as CLAUDE.local.md
SECOND_LEVEL = {"co.uk", "ac.uk", "com.gr", "gov.gr", "org.gr", "edu.gr", "com.au", "co.jp"}  # scan-allow: public-suffix constants
RESERVED_SUFFIXES = (".example", ".test", ".invalid", ".localhost", "example.com", "example.net", "example.org")
REPO_URL_PATHS = {"README.md", "private/docs/setup-new-machine.md", "package.json", ".claude-plugin/marketplace.json"}
SKIP_FILES = {"scripts/scan-allowed-domains.txt", ".gitleaksignore"}
SKIP_PREFIX = "private/"  # never exported, so the public-hostname rule does not apply


def registrable(host):
    parts = host.lower().split(".")
    if len(parts) >= 3 and ".".join(parts[-2:]) in SECOND_LEVEL:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:])


def load_allowed(root):
    allowed = set()
    path = os.path.join(root, "scripts", "scan-allowed-domains.txt")
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            line = line.split("#", 1)[0].strip().lower()
            if line:
                allowed.add(line)
    return allowed


def _parse_repo_url(url):
    """(host, path) from https://host/path(.git), ssh://user@host/path or user@host:path; path without .git."""
    url = url.strip()
    m = re.match(r"^(?:https?|ssh|git)://(?:[^@/]+@)?([^/:]+)(?::\d+)?/(.+?)(?:\.git)?/?$", url) or \
        re.match(r"^(?:[^@/]+@)?([^:/]+):(?!//)(.+?)(?:\.git)?/?$", url)
    return (m.group(1).lower(), m.group(2)) if m else (None, None)


def repo_identity(root):
    """Hosts, SSH aliases and path of this repo, from package.json and origin (works for alias, HTTPS and local clones)."""
    urls = []
    try:
        urls.append(subprocess.run(["git", "-C", root, "remote", "get-url", "origin"], capture_output=True, text=True, check=True).stdout.strip())
    except Exception:
        pass
    try:
        import json
        pkg = json.load(open(os.path.join(root, "package.json"), encoding="utf-8"))
        repo = pkg.get("repository")
        urls += [repo.get("url", "") if isinstance(repo, dict) else (repo or ""), pkg.get("homepage") or ""]
    except Exception:
        pass
    hosts, aliases, paths = set(), set(), set()
    for url in urls:
        host, path = _parse_repo_url(url) if url else (None, None)
        if not host:
            continue
        paths.add(path)
        (hosts if "." in host else aliases).add(host)
    # Aliases the allowed docs use for this repo path (git@alias:path), and their documented HostName.
    for rel in ("README.md", "private/docs/setup-new-machine.md"):
        try:
            text = open(os.path.join(root, rel), encoding="utf-8").read()
        except OSError:
            continue
        for p in paths:
            aliases.update(a.lower() for a in re.findall(r"git@([A-Za-z0-9_-]+):%s(?:\.git)?\b" % re.escape(p), text))
        for a, h in re.findall(r"^\s*Host\s+(\S+)\s*\n\s*HostName\s+(\S+)", text, re.M):
            if a.lower() in aliases and h.lower() in hosts:
                hosts.add(h.lower())
    for a in list(aliases):
        real = subprocess.run(["ssh", "-G", a], capture_output=True, text=True).stdout
        for line in real.splitlines():
            if line.startswith("hostname ") and line.split()[1].lower() != a:
                hosts.add(line.split()[1].lower())
    for line in subprocess.run(["git", "config", "--get-regexp", r"^url\..*\.insteadof$"], capture_output=True, text=True).stdout.splitlines():
        hosts.update(h.lower() for h in re.findall(r"[A-Za-z0-9.-]+\.[A-Za-z]{2,}", line))
    return hosts, aliases, sorted(paths)


def origin_hosts(root):
    hosts, aliases, _ = repo_identity(root)
    return hosts | aliases


def allowed_host(host, allowed):
    h = host.lower().rstrip(".")
    if h.endswith(RESERVED_SUFFIXES) or h == "localhost":
        return True
    if h == "cluster.local" or h.endswith(".svc.cluster.local"):
        return True
    return any(h == a or h.endswith("." + a) for a in allowed)


def iter_tree(root):
    out = subprocess.run(["git", "-C", root, "ls-files", "-co", "--exclude-standard", "-z"], capture_output=True, check=True).stdout
    for rel in filter(None, out.decode().split("\0")):
        if rel in SKIP_FILES or rel.startswith(SKIP_PREFIX):
            continue
        p = os.path.join(root, rel)
        try:
            with open(p, encoding="utf-8") as f:
                for i, line in enumerate(f, 1):
                    yield rel, i, line
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue


def iter_diff(path):
    rel, lineno = None, 0
    for raw in open(path, encoding="utf-8", errors="replace"):
        if raw.startswith("+++ "):
            rel = raw[4:].strip()
            rel = None if rel == "/dev/null" else rel[2:] if rel.startswith("b/") else rel
        elif raw.startswith("@@"):
            m = re.search(r"\+(\d+)", raw)
            lineno = int(m.group(1)) if m else 0
        elif raw.startswith("+") and rel and rel not in SKIP_FILES and not rel.startswith(SKIP_PREFIX):
            yield rel, lineno, raw[1:]
            lineno += 1
        elif not raw.startswith("-"):
            lineno += 1


def main():
    root = sys.argv[1]
    if sys.argv[2] == "--collect":
        found = set()
        for top in sys.argv[3:]:
            for d, _, files in os.walk(top):
                if "/.git" in d:
                    continue
                for fn in files:
                    try:
                        for line in open(os.path.join(d, fn), encoding="utf-8"):
                            found.update(registrable(h) for h in HOST_RE.findall(line))
                    except (UnicodeDecodeError, OSError):
                        pass
        print("\n".join(sorted(found)))
        return 0
    if sys.argv[2] == "--identity":
        import json
        hosts, aliases, paths = repo_identity(root)
        print(json.dumps({"hosts": sorted(hosts), "aliases": sorted(aliases), "paths": paths}))
        return 0
    diff, label = sys.argv[2], sys.argv[3]
    allowed = load_allowed(root)
    repo_hosts = {h for h in origin_hosts(root) if "." not in h or not allowed_host(h, allowed)}  # allowlisted public hosts stay public
    repo_domains = {registrable(h) for h in repo_hosts if "." in h}
    aliases = {h for h in repo_hosts if "." not in h}
    lines = iter_diff(diff) if diff else iter_tree(root)
    bad, waived = [], 0
    for rel, n, line in lines:
        if "scan-allow:" in line:
            waived += 1
            continue
        if rel not in REPO_URL_PATHS and any(re.search(r"(?<![A-Za-z0-9-])%s(?![A-Za-z0-9-])" % re.escape(a), line, re.I) for a in aliases):
            bad.append(f"  {rel}:{n}  repo SSH alias outside allowed files")
        for host in HOST_RE.findall(line):
            h = host.lower()
            if registrable(h) in repo_domains or h in repo_hosts:
                if rel not in REPO_URL_PATHS:
                    bad.append(f"  {rel}:{n}  repo host outside allowed files")
                continue
            if not allowed_host(h, allowed):
                bad.append(f"  {rel}:{n}  unlisted host {h}")
    if waived:
        print(f"scan: {waived} line(s) waived via scan-allow ({label})")
    if bad:
        print(f"scan: hostname rule ({label}) — use example.com / RFC 2606 names, or add a PUBLIC domain to scripts/scan-allowed-domains.txt:")
        print("\n".join(bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
