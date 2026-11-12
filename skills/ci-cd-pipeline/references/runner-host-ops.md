# Runner Host Operations (self-hosted Docker-executor runners)

When jobs fail in ways the code cannot explain — random `no space left on device`, `apt-get` exit 100, `docker login`
timeouts, TLS errors only in CI — look at the runner host before the pipeline. Everything below that changes the host
(prune, daemon config, package upgrades, runner restart) is a live change on shared infrastructure: propose it, get
explicit human approval, and pause the runner in GitLab first so no job is cut off mid-run.

## 1. Host health first (read-only)

```bash
hostname; uptime
df -hT /var/lib/docker /var/lib/containerd /tmp / 2>/dev/null   # bytes per filesystem
df -i  /var/lib/docker /tmp /                                     # inodes: 100% IUse% with free bytes = inode exhaustion
docker system df                                                  # images / containers / volumes / build cache
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'          # blast radius: what else lives on this host
free -m
systemctl status gitlab-runner --no-pager
journalctl -u gitlab-runner --since "-2h" --no-pager | tail -n 100
```

Blast radius matters: a runner host that also runs a registry mirror, a database or monitoring agents turns "prune
everything" into an outage. List non-job containers before any cleanup.

## 2. Errors that are really a full disk

| Seen in the job log | Often actually | Check |
|---|---|---|
| `apt-get` / `apt` exits `100` | apt's generic error code — a full `/var/cache/apt` or `/tmp` as often as a repo problem | `df -h` in the job (`df -h /var/cache/apt /tmp`) |
| `no space left on device` while inodes or bytes look fine on `/` | the full filesystem is `/var/lib/docker` (overlay) or the job's `/tmp` | `df -hT` / `df -i` on the Docker data root |
| `failed to register layer` / `write /var/lib/docker/...` | image extraction out of space | `docker system df` |
| Cache restore/upload fails | cache dir or volume full | runner `cache_dir` / volume usage |

Masked-error map for the rest of the stack → `devops-mutant-powers:error-reading`.

## 3. Cleanup on a schedule, not in a panic

GitLab Runner ships `clear-docker-cache` (removes unused containers and volumes created by the runner; default
`prune-volumes`) and recommends running it regularly, e.g. weekly via cron. Images and build cache need their own
prune. A systemd timer with `Persistent=true` catches up after downtime:

```ini
# /etc/systemd/system/docker-prune.service
[Unit]
Description=Prune unused Docker images and build cache on the CI runner host

[Service]
Type=oneshot
# CHANGE: retention window; prune -a removes every image not used by a container (base images get re-pulled)
ExecStart=/usr/bin/docker image prune -a -f --filter until=168h
ExecStart=/usr/bin/docker buildx prune -f --filter until=168h

# /etc/systemd/system/docker-prune.timer
[Unit]
Description=Weekly Docker prune

[Timer]
# CHANGE: a window with no deploys (systemd has no inline comments — keep comments on their own line)
OnCalendar=Sun *-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable (approval): `systemctl daemon-reload && systemctl enable --now docker-prune.timer`; check with
`systemctl list-timers docker-prune.timer`. Add a disk-usage alert so the timer is not your only defence →
`devops-mutant-powers:monitoring-and-alerting`. Never `docker system prune --volumes` on a host where any
non-job container keeps data in a volume.

## 4. MTU: login and pull timeouts that only happen in CI

Docker networks do not discover the path MTU; unless `mtu` is configured they typically run at Ethernet's 1500. When
the host's uplink is smaller (VPN, overlay, some cloud networks), small requests work and large TLS records stall: `docker login` / `docker pull` / `git clone` hang or time out, `curl` to the
same host works from the runner host itself.

| Layer | Setting |
|---|---|
| Default bridge on the host | `"mtu": <value>` in `/etc/docker/daemon.json` (daemon restart — approval) |
| New networks created by the daemon | `"default-network-opts": {"bridge": {"com.docker.network.driver.mtu": "<value>"}}` (existing networks unchanged) |
| Per-job networks the runner creates | `network_mtu = <value>` under `[runners.docker]` in `config.toml` |
| Docker-in-Docker service | `services: [{ name: docker:dind, command: ["--mtu=<value>"] }]` — ≤ the runner's bridge MTU |

Find the real path MTU with `ip link` and a don't-fragment ping (`ping -M do -s <size> <host>`) — method and tunnel
specifics → `devops-mutant-powers:network-operations`.

## 5. Old images, old CA stores

Jobs on old base images fail TLS (`certificate verify failed`, `x509: certificate signed by unknown authority`)
against hosts that work everywhere else. Classic case: the DST Root CA X3 expiry (30 Sep 2021) broke clients that did
not trust ISRG Root X1 — and OpenSSL 1.0.x failed even when it did.

Fix the image (newer base, updated `ca-certificates`), never the check: no `curl -k`, `GIT_SSL_NO_VERIFY`,
`--insecure-registry` as a "temporary" fix. Private CA → add the CA to the image's trust store explicitly.

## 6. Upstream package repositories move

Releases that leave support are removed from the main Debian mirrors (only up to `oldstable` stays) and live on
`archive.debian.org`; other distributions do the same. Symptom: `apt-get update` 404 / "does not have a Release
file" on a job image or runner host that worked last month. Fix: move to a supported base. Pointing at the archive is
a time-boxed stopgap with a ticket — it gets no security updates. Image-side detail →
`devops-mutant-powers:container-operations`.

## 7. Notification and helper scripts must not swallow errors

```bash
set -euo pipefail                                    # shell hardening → devops-mutant-powers:batch-data-jobs
curl --fail-with-body -sS -X POST -H 'Content-Type: application/json' \
  --data @payload.json "$CHAT_WEBHOOK_URL"           # non-2xx → exit 22 and the error body is printed
```

- `curl` without `--fail`/`--fail-with-body` exits 0 on HTTP 4xx/5xx — a dead webhook looks like success.
- `|| true` after a notifier hides a broken alert path for months. If a notification must not fail the deploy, put it
  in its own job with `allow_failure: true` so the failure stays visible as a warning.
- Webhook URLs and tokens are secrets: CI/CD variables (masked, protected), never in the repo or job log.

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "apt exit 100 — the mirror is down" | Check `df` first; 100 is apt's generic error. |
| "Run `docker system prune -af --volumes`, it's just a runner" | Check what else runs there; volumes may be someone's data. |
| "Login timeouts are the registry's problem" | Same command works from the host but not in the job → MTU. |
| "Add `-k` until the image is rebuilt" | Temporary insecure flags become permanent. Rebuild the image. |
| "The notifier returned 0, so the alert went out" | Without `--fail` curl returns 0 on a 404. |

## Verified References

- <https://docs.gitlab.com/runner/executors/docker/> — `clear-docker-cache` removes unused runner containers/volumes, default `prune-volumes`, run weekly via cron; `network_mtu`; `--mtu` on the dind service; `pull_policy` values
- <https://docs.docker.com/engine/manage-resources/pruning/> — `docker image prune -a`, `--filter until=24h`, `docker buildx prune`
- <https://docs.docker.com/reference/cli/docker/buildx/prune/> — `--filter until=<duration>` keeps records used within the duration
- <https://docs.docker.com/engine/network/drivers/bridge/> — `mtu` for the default bridge in `daemon.json`
- <https://docs.docker.com/reference/cli/dockerd/> — `default-network-opts` with `com.docker.network.driver.mtu`; applies to new networks only
- <https://man7.org/linux/man-pages/man5/systemd.timer.5.html> — `OnCalendar=`; `Persistent=true` runs a missed trigger after downtime
- <https://man7.org/linux/man-pages/man7/systemd.syntax.7.html> — only lines starting with `#` or `;` are comments in unit files
- <https://manpages.debian.org/bookworm/apt/apt-get.8.en.html> — apt-get returns 100 on error
- <https://www.debian.org/doc/manuals/debian-faq/ftparchives> — old releases are removed from the main archive and mirrors; archived releases live on archive.debian.org
- <https://letsencrypt.org/docs/dst-root-ca-x3-expiration-september-2021/> — DST Root CA X3 expired 30 Sep 2021; clients without ISRG Root X1 fail; OpenSSL 1.0.x affected
- <https://curl.se/docs/manpage.html> — `--fail` exits 22 on HTTP ≥ 400; `--fail-with-body` also outputs the body (7.76.0+)
