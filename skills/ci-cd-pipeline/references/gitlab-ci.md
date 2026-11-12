# GitLab CI — Behaviour That Bites

Placeholders: `<project-id>` (numeric ID or URL-encoded path), `<pipeline-id>`, `<tag>`. Creating/deleting tags,
retrying deploy pipelines, editing CI/CD variables and pausing runners are live changes — propose them and wait for
explicit human approval. When asked "how do I check", print the commands; do not run them.

## 1. The pipeline runs the CI config of the commit it builds

`.gitlab-ci.yml` is a file in the commit. A pipeline for a branch, tag or MR uses the config **at that SHA** (plus
whatever `include:` resolves to at run time).

| Situation | Consequence | Do |
|---|---|---|
| Tagging an old commit to "redeploy" it | the pipeline uses that commit's *old* CI config (old images, old deploy script, removed jobs) | diff `.gitlab-ci.yml` (and includes) between the tagged SHA and the default branch before tagging |
| Fixing the CI on `main` after a tag pipeline failed | the tag still points at the old commit; its pipeline never sees the fix | cut a new tag on a commit that contains the fix |
| Retrying a failed job | runs with the same parameters and variables as the original | a retry only helps for transient failures (network, runner) |
| Retrying a trigger (bridge) job | the downstream pipeline uses the config **at retry time** | expect different behaviour from the original run |

## 2. Tags as deploy triggers

- Gate deploy jobs with `rules: - if: $CI_COMMIT_TAG` (or a version regex) and make the tag pattern **protected**, so
  only maintainers can create it and protected variables reach the job.
- A tag pipeline is immutable input: same SHA, same config. "Retry until green" on a tag only re-runs the same thing —
  if the cause is in the code or CI file, **re-cut** (new tag on a fixed commit).
- Order destructive steps last: build → push → deploy → verify → *then* delete old tags/releases/images. A pipeline
  that deletes the previous tag first leaves nothing to roll back to when deploy fails.
- Moving a tag (`git tag -f` + force-push) leaves releases, caches and anything that recorded the old SHA pointing at
  different code than the tag name says — prefer a new version.
- Retrying an older deploy job redeploys its commit — a rollback. **Prevent outdated deployment jobs** (Settings →
  CI/CD → General pipelines) makes an older deploy job fail when it starts after a newer one. Retrying a deploy job
  for a rollback stays allowed by default; clear **Allow job retries for rollback deployments** in sensitive projects,
  and a rollback becomes a new pipeline on the previous commit.
- `when: manual` is a button, not access control: by default anyone with at least the Developer role can modify
  environments. A protected environment (Premium/Ultimate) limits who may deploy — a disallowed user's deploy job
  fails — and is where deployment approvals are configured.

## 3. Runners and job routing

| Symptom | Cause | Check |
|---|---|---|
| Job stuck `pending` / "no active runners online" | no runner has **all** the job's `tags`, or runner offline/paused | job `tags:` vs runner tags (Settings → CI/CD → Runners) |
| Untagged job never starts | the runner has **Run untagged jobs** off | runner settings |
| Job runs on an MR/feature branch but deploy runner ignores it | **protected runner** — runs only protected branches/tags | expected; deploy from a protected ref |
| Job killed at an odd time | runner's maximum job timeout is shorter than the project's | runner timeout wins when shorter |

## 4. Variables

- **Protected** variables are injected only into pipelines on protected branches or protected tags. An empty
  `$DEPLOY_TOKEN` on a feature branch is by design, not a bug. (MR pipelines can optionally be allowed to see them —
  a deliberate security decision.)
- **Environment scope** limits a variable to jobs whose `environment:` matches; a typo in the environment name means
  an empty variable, not an error.
- **Per-branch values without duplicating jobs:** `workflow:rules:variables` (pipeline-wide) or `rules:variables`
  (one job):

```yaml
workflow:
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
      variables: { DEPLOY_ENV: "production" }   # CHANGE: env name
    - if: $CI_COMMIT_BRANCH
      variables: { DEPLOY_ENV: "staging" }
    - if: $CI_COMMIT_TAG || $CI_PIPELINE_SOURCE == "merge_request_event"   # CHANGE: keep every pipeline type you use
```

A pipeline that matches no `workflow:rules` entry is not created — drop the last rule and tag deploys and the MR gate
(§7) silently stop running.

- Never `echo` a secret to debug it; compare `printf %s "$VAR" | sha256sum` or `${#VAR}` against the expected value.
- Token classes, expiry and rotation → `devops-mutant-powers:secrets-management`.

## 5. YAML and image traps

| Trap | Symptom | Fix |
|---|---|---|
| Colon (or `{`, `[`, `#`, `&`, `*`…) inside a `script:` line | CI lint rejects the job's `script`, or the line is parsed as a YAML map | single-quote the whole line: `- 'curl -H "Content-Type: application/json" ...'` or use a `- |` block |
| Image with an `ENTRYPOINT` (terraform, kubectl, some linters) | job exits at once, printing the tool's usage text | `image: { name: <image>, entrypoint: [""] }` |
| `when: manual` outside `rules` | pipeline shows *passed* while the deploy never ran (`allow_failure: true` default) | put `when: manual` inside `rules` (default `allow_failure: false` → pipeline blocks as "manual") |
| `needs:` omitted for a fast path | job waits for the whole previous stage | `needs: [<job>]` runs as soon as those jobs finish (and fetches their artifacts) |
| Concurrent deploys | two pipelines deploy at once and interleave | `resource_group: <env>` serialises them |

## 6. Building images in CI

| Method | How | Watch out |
|---|---|---|
| Docker-in-Docker | `services: [docker:dind]`, runner `privileged = true` | needs privileged; set `--mtu` on the dind service when the host network MTU is below 1500 (`references/runner-host-ops.md` §4) |
| Host socket binding | mount `/var/run/docker.sock` | containers are **siblings** on the host; `-v "$PWD":/src` mounts the **host** path, not the job's; concurrent jobs clash on names; anyone with the job owns the host (root-equivalent) |
| Daemonless builders (BuildKit rootless, Kaniko-style) | build without a daemon | check the tool's own docs for cache and auth |

Image content (UID, entrypoint, read-only root FS, runtime contract) → `devops-mutant-powers:container-operations`.

## 7. Merge-request gate

Run the cheap, decisive checks on `merge_request_event`: lint, type-check, unit tests, **a production build**
(catches dev-only imports and missing env at build time), and the render/policy gates below. Require a successful
pipeline before merge in the project's merge checks so a red MR cannot be merged by accident.

```yaml
mr-checks:
  stage: test
  image: node:22-alpine                    # CHANGE: toolchain image, pinned
  script:
    - npm ci
    - npm run typecheck                    # CHANGE: project scripts
    - npm run build
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
```

## 8. Manifest gates in CI (same versions as local pre-commit)

```yaml
manifest-gates:
  stage: test
  image: <tools-image>@sha256:<digest>     # CHANGE: image with kustomize, kubeconform, kube-linter, kyverno at pinned versions
  variables:                               # CRs fail "could not find schema" without a CRD schema source (or a vendored copy)
    CRD_SCHEMAS: 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
  script:
    - kustomize build overlays/staging > rendered.yaml            # CHANGE: overlay path
    - kubeconform -strict -summary -schema-location default -schema-location "$CRD_SCHEMAS" rendered.yaml
    - kube-linter lint rendered.yaml
    - kustomize build overlays/staging | kyverno apply policies/ --resource -   # exits 1 on policy failures
```

Pin each tool to the same release locally (pre-commit) and in CI — a linter upgrade that adds checks turns CI red on
unchanged code. What each gate catches, Kyverno Audit vs Enforce, and linter-only vs admission rules →
`devops-mutant-powers:kubernetes` (its policy-and-linting reference); Flux render/prune gate →
`devops-mutant-powers:gitops-flux`. Terraform: plan → gate → manual apply →
`devops-mutant-powers:infrastructure-provisioning` (its terraform-plan-gate reference).

## 9. Build-time vs runtime config (SPAs)

Bundlers inline env vars at build time — Vite statically replaces `import.meta.env.VITE_*` in the bundle. Building
once per environment breaks "build once, promote the same image". Instead:

1. Build with placeholders (`VITE_API_URL=__API_URL__`) or load a small `config.js` at runtime.
2. At container start, substitute placeholders from env into the served files (an entrypoint script writing to a
   writable path such as an `emptyDir`), then exec the web server.
3. Verify in the running container: `grep -r __API_URL__` on the served directory must return nothing.

Never put secrets in SPA config — everything shipped to the browser is public. Entrypoint and read-only-root-FS
contract → `devops-mutant-powers:container-operations`.

## 10. Waiting for a pipeline (never sleep-and-guess)

Pipeline `status`: `created`, `waiting_for_resource`, `preparing`, `waiting_for_callback`, `pending`, `running`,
`success`, `failed`, `canceling`, `canceled`, `skipped`, `manual`, `scheduled`. Terminal: `success|failed|canceled|skipped`.
`manual` means a human must press Play — stop and report, do not keep polling.

```bash
P=<project-id>; ID=<pipeline-id>                      # or: glab api "projects/$P/pipelines/latest?ref=<ref>"
for i in $(seq 1 120); do                              # bounded: 120 × 15 s = 30 min
  s=$(glab api "projects/$P/pipelines/$ID" | jq -r .status)
  case $s in
    success|failed|canceled|skipped) echo "pipeline $ID: $s"; break ;;
    manual) echo "pipeline $ID waits for a manual job"; break ;;
    *) sleep 15 ;;
  esac
done
glab api "projects/$P/pipelines/$ID/jobs" | jq -r '.[] | "\(.status)\t\(.stage)\t\(.name)"'   # which job, which stage
```

`glab api` sends `-f/-F` fields as a JSON body (and switches to POST); with a raw body via `--input file.json`, set
`-H 'Content-Type: application/json'` explicitly rather than relying on a default.

## Verified References

- <https://docs.gitlab.com/ci/yaml/> — `script` special characters need single quotes; `image:entrypoint: [""]`; `needs`; `rules` + `when: manual` default `allow_failure: false` vs `true` outside rules; `tags` select runners having all tags; `rules:variables`, `workflow:rules:variables`; `resource_group`
- <https://docs.gitlab.com/ci/yaml/workflow/> — pipelines matching no `workflow:rules` do not run; branch + MR pipelines can duplicate (`CI_OPEN_MERGE_REQUESTS`)
- <https://docs.gitlab.com/ci/jobs/> — retried jobs keep parameters and variables; retried trigger jobs use the configuration at retry time
- <https://docs.gitlab.com/ci/variables/> — protected variables only on protected branches/tags; MR pipelines can optionally access them
- <https://docs.gitlab.com/ci/runners/configure_runners/> — runner must have all job tags; "Run untagged jobs"; protected runners; runner max timeout wins when shorter
- <https://docs.gitlab.com/user/project/repository/tags/> — `CI_COMMIT_TAG`; tag pipelines are created only when a tag targets a commit
- <https://docs.gitlab.com/ci/environments/deployment_safety/> — older deploy jobs fail with outdated-job prevention on; rollback retries enabled by default, can be disabled (rollback = new pipeline on a previous commit); environments modifiable by the Developer role by default
- <https://docs.gitlab.com/ci/pipelines/settings/> — "Prevent outdated deployment jobs" and "Allow job retries for rollback deployments" under Settings → CI/CD → General pipelines
- <https://docs.gitlab.com/ci/environments/protected_environments/> — only allowed users deploy, others' deploy jobs fail; approvals configured on protected environments; Premium/Ultimate
- <https://docs.gitlab.com/ci/docker/using_docker_build/> — socket binding: sibling containers, volume mounts resolved on the host, concurrency conflicts, privilege escalation; DinD needs privileged mode
- <https://docs.gitlab.com/runner/executors/docker/> — `network_mtu` in `config.toml`; `--mtu` on the `docker:dind` service
- <https://docs.gitlab.com/api/pipelines/> — pipeline status values; `GET /projects/:id/pipelines/:pipeline_id`; `/pipelines/latest?ref=`
- <https://docs.gitlab.com/cli/api/> — `glab api` field flags build a JSON body and switch to POST; `--input` sends a raw body; `-H` adds headers
- <https://github.com/yannh/kubeconform> — resources without a schema fail by default; `-schema-location default` plus the datreeio CRDs-catalog template validates CRs
- <https://kyverno.io/docs/subprojects/kyverno-cli/> — `kustomize build ... | kyverno apply <policy> --resource -`; apply exits 1 on failures
- <https://github.com/stackrox/kube-linter/blob/main/docs/README.md> — `kube-linter lint <path>`; pin a release tag to avoid unexpected breakage
- <https://vite.dev/guide/env-and-mode> — `import.meta.env` constants are statically replaced at build time; `VITE_*` values are bundled into the source
