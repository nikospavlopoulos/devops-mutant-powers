# Shell hardening: no silent success

Silent success — exit 0 while the work did not happen — is the most common batch-job failure. Nearly every case
is a shell construct that discards a status, a default that hides a missing value, or a check never tested on the
absent case. The template `tooling/scripts/strict-shell-template.sh` implements everything below.

## The header

```bash
#!/usr/bin/env bash
set -Eeuo pipefail        # E: ERR trap inherited by functions/subshells; e: exit on failure; u: unset = error; pipefail
shopt -s inherit_errexit  # bash >= 4.4: $(...) keeps -e (otherwise bash clears -e in command substitutions)
export LC_ALL=C           # stable number formats and byte-order sorting
```

Run it as `bash script.sh` (or a `#!/usr/bin/env bash` shebang with bash in the image). A `sh`/`zsh` invocation silently
changes the rules below.

## Where `set -e` does NOT stop the script

The bash manual's exceptions, plus the masking patterns that follow from them (each reproduced locally):

| Construct | What happens | Use instead |
|---|---|---|
| Command in `if`/`while`/`until` condition, `&&`/`\|\|` list (except the last), negated with `!` | Failure ignored by design | Fine for real conditions; never wrap work in them |
| Function called as a condition (`if do_work; then`) | `-e` is ignored for **everything inside** the function | Call it as a plain statement; branch on a value it sets |
| `cond && action` as the last line of a function | When `cond` is false the function returns 1 and the **caller** exits | `if cond; then action; fi` |
| `local x=$(cmd)` / `export x=$(cmd)` | Status of `local`/`export` (0) replaces `cmd`'s | `local x; x=$(cmd)` |
| `printf '%s' "$(cmd)"` | Substitution inside another command's args: status lost | Assign first: `v=$(cmd)` |
| `cmd1 \| cmd2` without pipefail | Status = last command only | `set -o pipefail`; per-stage: `"${PIPESTATUS[@]}"` |
| `while read ... done < <(cmd)` | Process-substitution status is not checked | Write `cmd` output to a file first, then read the file |
| `f() { work; echo done; }` | Trailing `echo` makes the function return 0 | Let the real command be last, or `return` explicitly |

`$?` after a pipeline is the last command's status; `PIPESTATUS` holds every stage of the most recent foreground
pipeline and is overwritten by the next command — copy it immediately: `rc=("${PIPESTATUS[@]}")`.

## Traps

| Trap | Use |
|---|---|
| `ERR` (+ `set -E`) | Log `$?`, `$LINENO`, `$BASH_COMMAND` of the failing command; fires once per failing level (a stack-like trail) |
| `EXIT` | One place for: FAILED marker, notification, hold-on-failure, temp cleanup. Capture `$?` on its first line |
| `TERM` / `INT` | Required when bash is PID 1 in a container (default-action signals are ignored there); forward to the child, exit 143/130 |

Bash runs a trap only after the current **foreground** command finishes; `wait` on a background job returns at once
(status > 128) and the trap runs. Long steps therefore run as `tool & wait "$!"` — including the script's own walks
(`find` over millions of files, per-directory listings): a foreground walk delays the TERM trap until it ends — on a
big tree past the grace period, so SIGKILL lands before any `FAILED` marker — and prints no heartbeat meanwhile.

## Shells that are not bash

| Shell | Gotcha | Consequence |
|---|---|---|
| BusyBox ash (Alpine, distroless debug) | No arrays, no `PIPESTATUS` (`bad substitution`); `pipefail` supported in BusyBox 1.37 here | Test `sh -c 'set -o pipefail'` in the **exact** image; or install bash |
| dash (Debian/Ubuntu `/bin/sh`) | No arrays/`PIPESTATUS`; `pipefail` only in builds carrying the 2024 patch (Debian `0.5.12-7`+); older ones (e.g. Debian 12) fail with `set: Illegal option -o pipefail` | Same: test in the image, do not assume |
| zsh (a workstation default) | Unquoted `$var` is **not** field-split (`SH_WORD_SPLIT` is off outside sh/ksh emulation): `cmd="echo a b"; $cmd` → `command not found: echo a b`; `PIPESTATUS` is `pipestatus` | Put commands in arrays (`cmd=(rclone copy ...); "${cmd[@]}"`) or functions; run scripts under bash |
| `/bin/sh -c` in `command:` | Whatever `sh` the image has | Name `bash` explicitly in the Job `command` |

Non-interactive shells have no job control; do not rely on `jobs`/`%1` in scripts — keep `$!` in a variable.

**Host cron** (not a CronJob) adds its own environment: cron sets `SHELL=/bin/sh`, `HOME` and `LOGNAME` and reads
none of your login profile, so `PATH`, locale and aliases differ from your terminal; an unescaped `%` in the crontab
line becomes a newline (the rest goes to stdin); output is mailed to `MAILTO`/the owner — with no working mail
setup nobody reads it. Rules:

```bash
# m h dom mon dow  command — explicit interpreter, lock, log; the script sets PATH and LC_ALL itself
15 2 * * *  flock -n /run/lock/app-a-sync.lock bash /opt/jobs/app-a-sync.sh >>/var/log/app-a-sync.log 2>&1
```

`flock -n` exits 1 instead of starting a second, overlapping run. Alert on a missing success/heartbeat line, not only
on error lines (Visibility rules below).

## Locale

A decimal-comma locale corrupts numeric parsing and formatting. Reproduced with `LC_ALL=el_GR.utf8`:
`printf '%.2f' 3.14` → `printf: 3.14: invalid number` and prints `3,00`; `awk 'BEGIN{printf "%.2f", 3.14}'` prints `3,14`
with mawk, which the next tool parses wrong — and mawk reads the input string `"3.14"` as `3` (`"3.14"+1` → `4`), a
silent truncation with exit 0. gawk uses the locale's decimal point only with `--posix` or `-N`/`--use-lc-numeric`. Sort order also changes (`a A b B` vs `A B a b` under `C`). Export `LC_ALL=C` (or at
least `LC_NUMERIC=C`) at the top; cron and container entrypoints inherit whatever the host or image sets.

## Existence gates: test the ABSENT case

A gate that never fails is not a gate. Before trusting any "does X exist?" check, run it against a path that does
not exist and confirm it fails.

| Check | Absent-case behaviour | Safe form |
|---|---|---|
| `rclone lsjson --stat remote:bucket/missing` (S3/GCS/Azure Blob) | Returns an **empty directory**, exit 0 (bucket remotes cannot tell missing from empty) | Count objects; read the marker and require non-empty content |
| `rclone lsf` / `rclone size` on a missing prefix of a bucket remote | Empty listing / 0 objects, exit 0 | Compare counts against the measured source |
| Same commands on a local or SFTP path | `directory not found`, exit 3 | Do not generalise from a local test to S3 |
| `n=$(grep -c pat f \|\| echo 0)` | `grep -c` prints `0` **and** exits 1, so you get `0\n0` | `n=$(grep -c pat f) \|\| true` |
| `jq '.count // 0'` / `jq 'try .count catch 0'` | Missing field (`//`) or wrong input type (`try`) → `0`, exit 0; a whole CSV of zeros looks valid | `jq -e '.count'` (exit 1 on null/false, 4 on no result) and fail |
| `[ -e "$marker" ]` | True for a zero-byte marker written by a crashed run | `[ -s "$marker" ]` |
| A trailing `echo ok` after `pg_restore`/`rclone` | Masks the real exit status | Check the tool's status, then log |
| `psql -f script.sql` | A failing statement is printed, psql carries on and exits **0** | `psql -X -v ON_ERROR_STOP=1 -f ...` (exit 3 on a script error) |
| `psql -v n="$N" -c 'select :n'` | `-c` sends the string straight to the server, skipping psql's `:var` interpolation: the server sees a literal `:n` | Interpolate via `-f file` or a quoted here-doc on stdin: `psql -v n="$N" <<'SQL'` |

## Visibility rules

- **Never discard stderr** on work commands (`2>/dev/null` deletes the only explanation). Discard it only for a named,
  benign race (killing an already-exited helper), with a comment.
- `|| true` only on lines whose failure is explicitly acceptable; never on the work itself.
- **Heartbeat**: long steps print a line every N seconds (template: `HEARTBEAT_SECONDS`). Silence then means "hung" or
  "killed", not "busy". For cron, alert on a missing heartbeat or success line, not only on error lines
  (`devops-mutant-powers:monitoring-and-alerting`).
- **Elapsed time** on the final line. A run that "fails" or "succeeds" in under a second did not process data: missing
  binary, bad mount, wrong path, empty source.
- **Notifications must fail loudly.** A `notify()` that swallows curl errors hid a DNS failure for days in practice.
  Log a WARN with the cause class (DNS/egress/Secret), never the webhook URL (it usually embeds a token), and make it
  fatal where alerting is the whole point (`NOTIFY_REQUIRED=1`). Fall back curl → wget (BusyBox images ship wget).
- **Empty input is an error by default.** A wrong mount or path looks exactly like "0 files to copy, success".

## Configuration and `nounset`

- `${VAR:-default}` everywhere hides a renamed variable: the old name silently takes the default. Keep one config
  block, validate required values explicitly (non-empty, numeric, allowed set) before any data is touched, and exit with
  a distinct code (template: 2, mapped to `FailJob`).
- `bash -n` cannot see a renamed or unset variable, and `set -u` fires only when that line **runs** — usually the
  failure path (traps, `notify`, cleanup), so the next real failure crashes its own reporting. After a rename, grep for
  the old name and force one failure locally (bad `DST`, missing source) to execute those paths.
- Validate numbers before `(( ))`: bash arithmetic evaluates a non-numeric string as a variable name.
- Values used in paths (`JOB_NAME`, `RUN_ID`) must not contain `/` or start with `.`.
- Secrets never in argv (visible in `ps`, `/proc/<pid>/cmdline`, and the template's `exec:` log line): env from a
  Secret or a mounted file. Compare secrets by `sha256sum`/length, never print them.

## Marker protocol

1. Write output to `<name>.part` on the **same filesystem** as the final name.
2. Verify it (non-empty, tool-specific validation, counts).
3. `mv -f <name>.part <name>` — `rename(2)` replaces atomically; across filesystems `mv` degrades to copy+delete.
4. Write the completion marker (`_SUCCESS` / `.complete`) **last**, with content (counts, run id, timestamp).
5. Consumers wait for the marker and require it **non-empty** (`[ -s ]`, or non-empty `rclone cat`).
6. Resumable phases: `<phase>.done` markers under a per-run state directory keyed by `RUN_ID`. Same id = resume; new
   id = fresh run. A shared, id-less state directory turns the next run into an instant "success" that copied nothing.
7. Clear a stale destination marker before the transfer starts, or a consumer reads half-written data under an old
   `_SUCCESS`. Better: one destination prefix per run.

Consumer side — a bounded wait for **content**, where timing out is a failure, never a silent skip:

```bash
deadline=$(( $(date +%s) + 3600 ))                                   # CHANGE: maximum wait
until m=$(rclone cat dst:example-bucket/app-a/run-001/_SUCCESS) && [[ -n $m ]]; do   # local: [[ -s $marker ]]
  (( $(date +%s) < deadline )) || { echo "ERROR: no non-empty marker after 3600s" >&2; exit 1; }
  sleep 30
done
echo "marker: $m"                                                    # log what you trusted (run id, counts)
```

Dump-specific validation (TOC listing, decompress test) for `pg_dump` output → `devops-mutant-powers:postgres-operations`.

## Verified References

Sources for the claims in this file (`../SKILL.md` lists the ones its core rests on, compactly):

- <https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html> — `-e` exceptions, `pipefail`, `-E` errtrace; `-n` reads without executing; `-u` errors only during parameter expansion (so only on lines that run)
- <https://www.gnu.org/software/bash/manual/html_node/Signals.html> — traps deferred during foreground commands; `wait` returns > 128 and the trap runs
- <https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html> — `PIPESTATUS` semantics
- <https://zsh.sourceforge.io/Doc/Release/Options.html> — `SH_WORD_SPLIT` off by default outside sh/ksh emulation
- <https://jqlang.org/manual/> — `-e`/`--exit-status` codes
- <https://man7.org/linux/man-pages/man2/rename.2.html> — atomic replacement; `EXDEV` across mount points
- <https://rclone.org/commands/rclone_lsjson/> — `--stat` returns an empty directory for missing paths on bucket backends
- <https://bugs.debian.org/1071238> — dash without the patch: `set: Illegal option -o pipefail`; fixed by the upstream pipefail patch
- <https://metadata.ftp-master.debian.org/changelogs/main/d/dash/unstable_changelog> — Debian dash `0.5.12-7` (May 2024) "Implement pipefail option"
- <https://man7.org/linux/man-pages/man1/gawk.1.html> — `-N`/`--use-lc-numeric` forces the locale decimal point when parsing input
- <https://www.postgresql.org/docs/current/app-psql.html> — exit status 0/1/2/3 and 3 only with `ON_ERROR_STOP`; processing continues after an error by default; `-c` must contain no psql-specific features; interpolation syntax `:name`/`:'name'`
- <https://github.com/postgres/postgres/blob/master/src/bin/psql/startup.c> — a `-c` SQL string goes directly to `SendQuery` (no psql lexer, so no variable interpolation)
- <https://man7.org/linux/man-pages/man5/crontab.5.html> — cron sets `SHELL=/bin/sh`, `HOME`, `LOGNAME`; `%` becomes newline/stdin; `MAILTO` semantics
- <https://man7.org/linux/man-pages/man1/flock.1.html> — `-n` fails instead of waiting; conflict exit status defaults to 1 (`-E`)
