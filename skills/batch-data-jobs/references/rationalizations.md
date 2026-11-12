# Common Rationalizations — Full Table

`SKILL.md` keeps a distilled checklist. This is the full table: review a plan, a script or a reply against it before
sending, and when someone pushes for a shortcut. The last column names the reference that holds the detail.

| Excuse | Reality | Detail |
|---|---|---|
| "The Job is Completed, so the copy worked" | `Complete` = the container exited 0. Silent-success scripts exit 0 too. Check marker, counts, tool report. | `references/job-template.md` ("Completed" is not "done") |
| "I checked the object exists with `lsjson --stat`/`lsf`" | On bucket remotes a missing path returns an empty directory with exit 0. Count, or read the marker's content. | `references/shell-hardening.md` (Existence gates) |
| "`set -e` is on, failures will stop it" | Not inside `if f`, `&&` lists, `local x=$(...)`, pipes without pipefail, or process substitution. | `references/shell-hardening.md` (Where `set -e` does NOT stop) |
| "emptyDir is fine for scratch, it's one run" | Eviction or a node drain deletes it mid-run; ephemeral-storage overuse is itself an eviction trigger. | `references/job-template.md` (Pod spec choices) |
| "`sync` keeps the destination tidy" | `sync` deletes destination files absent from the source; one wrong source path empties the bucket. | `references/transfer-tools.md` §3 |
| "TTL keeps the namespace clean" | TTL deletes the Job's pods and their logs — the evidence you need for a failed run. | `references/job-template.md` (Job spec fields) |
| "Retries will sort out transient errors" | Default `backoffLimit` is 6 with back-off growing to 6 min; a config error just fails six times, slowly. Exit with a distinct code and `FailJob` it. | `references/job-template.md` (Job spec fields) |
| "It's just a quick `kubectl cp`" | Needs `tar` in the image, no resume, no verification; the docs point to `kubectl exec` + tar for symlinks and file modes. | `references/transfer-tools.md` §8 |
| "The notify call is best-effort" | A swallowed notify error is how a broken webhook stays unnoticed for days. Log it loudly; make it fatal when alerting is the point. | `references/shell-hardening.md` (Visibility rules) |
| "It works in my terminal" | Your terminal may be zsh (no word splitting), a different locale, a different PATH. Run it under bash, `LC_ALL=C`, in the image. | `references/shell-hardening.md` (Shells that are not bash, Locale) |
| "The CronJob reuses the tested Job spec, so it's fine" | A fixed `RUN_ID` makes every later run skip all phases and exit 0; default `concurrencyPolicy: Allow` overlaps runs. `RUN_ID` from the Job name, `Forbid`. | `references/job-template.md` (Scheduled runs) |
