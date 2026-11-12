# Secret and vulnerability scanning

Configs for gitleaks (secrets) and Trivy (dependencies, image packages, secrets), plus a GitLab CI include that runs
both. Handling a real finding (rotate first, then clean up): `skills/secrets-management/SKILL.md`.

| File | What it is |
|---|---|
| `trivy.yaml` | Trivy config: fail (`exit-code: 1`) on HIGH/CRITICAL findings that have a fix (`ignore-unfixed`), vuln + secret scanners, telemetry and update check off. Copy to the repo root as `trivy.yaml` |
| `gitleaks.example.toml` | gitleaks config: `[extend] useDefault = true` plus a narrow `[[allowlists]]` (fixture paths, exact placeholders). Copy to `.gitleaks.toml` |
| `gitlab-ci-scan.yml` | GitLab CI include: `secret-scan` (gitleaks; MR commit range, else the working tree) and `dependency-scan` (`trivy fs`), images pinned by tag and digest, stage `scan` |

No GitHub Actions scan workflow ships. If you add one, pin every action by full commit SHA: in March 2026
attackers force-pushed `aquasecurity/trivy-action` and `setup-trivy` tags and published a malicious Trivy v0.69.4
binary and 0.69.4–0.69.6 images (CVE-2026-33634). A commit SHA or image digest cannot be re-pointed that way.

## Commands (current syntax)

```bash
# gitleaks >= 8.19: git / dir / stdin (detect and protect still work but are hidden)
gitleaks git --redact -v .                          # full history
gitleaks dir --redact -v .                          # working tree or any directory
gitleaks git --pre-commit --staged --redact -v .    # staged changes (pre-commit hook)
gitleaks detect --no-git --source . --redact        # same as dir, for gitleaks < 8.19

# Trivy reads ./trivy.yaml; an explicit --config path that is missing is fatal
trivy fs --config trivy.yaml .
trivy image --config trivy.yaml registry.example.com/team-a/app-a@sha256:<digest>

# trufflehog v3: --results replaces the now-hidden --only-verified
trufflehog git file://. --results=verified,unknown --fail          # exit 183 when results are found
trufflehog filesystem . --results=verified,unknown --fail
```

trufflehog verifies a candidate by calling the provider's API with it; add `--no-verification` where that must not
happen. Accepted Trivy findings go in `.trivyignore` with a reason and `exp:YYYY-MM-DD`; accepted gitleaks findings
go in `.gitleaksignore` by fingerprint.

## Version notes

- gitleaks < 8.25 ignores `[[allowlists]]` silently (findings are reported, nothing is hidden); there, rename it to
  a single `[allowlist]` table.
- Do not set Trivy's `ignorefile` to the default `.trivyignore`: an explicitly set ignore file that is missing
  aborts the scan.

## Checks

```bash
# trivy.yaml: run it from a directory that holds the config (exit 1 on a fixable HIGH or CRITICAL finding)
docker run --rm -v "$PWD:/src" -w /src aquasec/trivy:0.75.0 fs --config trivy.yaml .

# gitleaks.example.toml: load the config against an empty directory (exit 0 means it parses)
gitleaks detect --no-git --source <empty-dir> --config tooling/security/scanning/gitleaks.example.toml --redact

# gitlab-ci-scan.yml: parse it, then lint it in GitLab's CI Lint with your pipeline
python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' tooling/security/scanning/gitlab-ci-scan.yml
```
