---
name: ci-cd-pipeline
description: "Use when a CI/CD pipeline fails or hangs (GitLab CI, GitHub Actions, Jenkins): job stuck pending, empty protected variable, YAML/entrypoint errors, tag deploys, runner disk full, MTU timeouts. GitOps reconciliation after merge → gitops-flux; container build contract → container-operations."
---

# CI/CD Pipeline

**In plain terms:** a pipeline is a program that runs somebody else's computer with your secrets — so first prove
*which* config, *which* commit and *which* runner produced the result, then fix the cause instead of pressing retry.

Works in both modes: in repo mode read and edit the pipeline files and run the local gates; in chat mode work from the
pasted config and job log, and print API/CLI commands for the human.

## When to Use

- A job fails, hangs `pending`, or passes while the deploy never happened
- A variable is empty in one pipeline but not another; secrets missing on feature branches
- Tag/release pipelines: redeploying an old version, re-cutting a release, deleting tags
- `jobs:...script` lint errors, images whose ENTRYPOINT swallows the job, DinD vs socket builds
- Jobs fail only on CI: `no space left on device`, `apt-get` exit 100, `docker login` timeouts, TLS errors from old images
- Designing MR gates (type-check, build, manifest lint/policy, Terraform plan gate)
- Waiting for a pipeline result from a script or agent

**Not this skill:** what happens after the merge reaches a Flux-managed cluster → `devops-mutant-powers:gitops-flux`;
Dockerfile/image runtime contract (UID, entrypoint, read-only root FS) → `devops-mutant-powers:container-operations`;
plan/apply semantics → `devops-mutant-powers:infrastructure-provisioning`; token lifecycle →
`devops-mutant-powers:secrets-management`.

## Core Rules

1. **Identify the run before reading it.** Pipeline ID, ref, SHA, source (push/MR/tag/schedule) and runner. A green
   pipeline on the wrong ref proves nothing.
2. **The config is part of the commit.** A pipeline runs the CI file at the SHA it builds; tagging an old commit runs
   its old CI. Fixes on `main` never reach an existing tag — re-cut.
3. **Read the first error, not the last line.** The failing step is usually well above `exit code 1`.
4. **Retry only transient failures.** Network blips and runner loss — yes. Code, config, missing variables — retrying
   re-runs the same input.
5. **Secrets stay masked.** Never echo a variable to debug it; compare `sha256sum` or length. Protected variables are
   absent on unprotected refs by design.
6. **Gates block, humans override.** Lint, policy, plan gates fail the pipeline; bypassing one is an explicit,
   recorded human decision — never `allow_failure: true` to make it green.
7. **Production deploys are gated:** protected ref + manual job (or environment approval) + serialised
   (`resource_group` / concurrency group). Triggering, retrying or cancelling deploy pipelines needs human approval.
8. **Host before code for "random" CI-only failures:** disk, inodes, MTU, CA store on the runner host
   (`references/runner-host-ops.md`).
9. **Poll to a terminal state.** `success|failed|canceled|skipped` (or `manual` = a human must act). Never `sleep 300`
   and assume.

## Workflow — Red or Stuck Pipeline

| Step | Question | Evidence |
|---|---|---|
| 1 | Which run? ref, SHA, source, CI file at that SHA | pipeline page / `glab api projects/<project-id>/pipelines/<pipeline-id>` |
| 2 | Did the job start? | `pending` → runner tags / protected runner / offline (gitlab-ci §3) |
| 3 | First error in the log | the earliest failing command and its stderr |
| 4 | Config or input? | variables present (by length), image tag/digest, entrypoint, `rules` evaluated as expected |
| 5 | Host or network? | same failure on other runners? disk/inodes/MTU/CA (runner-host-ops) |
| 6 | Fix at the source | commit the CI/code change; for tags, cut a new tag |
| 7 | Prove the effect | deploy reached the target (image digest, version endpoint), not just a green badge → `devops-mutant-powers:verification-before-completion` |

## Pipeline Design Principles

1. **Fast feedback:** lint → type-check → unit test → build → integration → deploy.
2. **Build once, promote the same artifact** (image digest) through environments; runtime config at container start,
   not per-environment builds (SPA case: gitlab-ci §9).
3. **Same tool versions locally and in CI** (pre-commit and CI pin identical releases).
4. **Secrets from the secret store or masked/protected variables** — never in the repo or the log.
5. **Idempotent deploys** and an explicit rollback path (previous digest/tag kept until the new one is verified).
6. **Destructive steps last** (old tag/image/release cleanup after verification).

## GitLab CI

Depth: `references/gitlab-ci.md`. Most common causes:

| Symptom | Cause | Fix |
|---|---|---|
| Job stuck `pending` | no runner has all the job's `tags`; untagged job on a runner without "Run untagged jobs"; protected runner on an unprotected ref | align tags / runner settings / ref protection |
| `$VAR` empty on a feature branch | protected variable, unprotected ref | expected; use a non-protected, low-privilege variable for MR jobs |
| Job exits immediately with the tool's usage text | image `ENTRYPOINT` | `image: { name: ..., entrypoint: [""] }` |
| Script line parsed wrongly | `:` or other YAML special characters | single-quote the line or use `- |` |
| Pipeline "passed", deploy never ran | `when: manual` outside `rules` → `allow_failure: true` | `when: manual` inside `rules` |
| Redeploy of an old tag behaves differently | old CI config at that SHA | diff the CI file; re-cut on a fixed commit |
| `artifacts` not found in a later job | producer didn't declare `artifacts:` or expired; `needs` without artifacts | declare paths, check `expire_in` |
| Cache never restored | `cache:key` differs between jobs, or the job ran on another runner (cache is local per runner by default) | same `cache:key`; distributed (S3-type) cache for multi-runner setups |

## GitHub Actions

| Issue | Fix |
|---|---|
| `Context access might be invalid` | check secret/variable name spelling and scope |
| `Resource not accessible by integration` | add a `permissions:` block granting the token what the step needs |
| `Process completed with exit code 1` | read that step's full log output |
| Workflow not triggering | check `on:` triggers match the branch/event and path filters |

Debug logging: set the secret or variable `ACTIONS_STEP_DEBUG=true` (step logs) or `ACTIONS_RUNNER_DEBUG=true` (runner
diagnostics); a secret takes precedence over a variable of the same name.

## Jenkins

| Issue | Fix |
|---|---|
| Build never starts | check agent availability and labels |
| Credentials not found | verify the credential ID in the Jenkins credentials store |
| Workspace dirty | add `cleanWs()` at the start of the pipeline |

## Quick Commands

```bash
# GitLab: latest pipeline for a ref, its jobs, then one job's log tail
glab api "projects/<project-id>/pipelines/latest?ref=<ref>" | jq '{id, status, sha, source, ref}'
glab api "projects/<project-id>/pipelines/<pipeline-id>/jobs" | jq -r '.[] | "\(.status)\t\(.stage)\t\(.name)\t\(.runner.description // "-")"'
glab api "projects/<project-id>/jobs/<job-id>/trace" | tail -n 80

# CI file at the SHA a tag points to vs the default branch
git diff "$(git rev-list -n1 <tag>)" origin/main -- .gitlab-ci.yml

# Variable present without printing it
printf %s "$VAR" | sha256sum; echo "${#VAR}"

# Runner host (read-only): disk, inodes, Docker usage
df -hT /var/lib/docker /; df -i /var/lib/docker /; docker system df
```

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "Just retry it" | Retries re-run the same commit, config and variables. Find the cause unless it's clearly transient. |
| "Retag the old commit to redeploy" | It runs the old CI config. Diff it first, or deploy the old digest through the current pipeline. |
| "Echo the token so we can see it's set" | It lands in the job log forever. Compare length or hash. |
| "Mark the lint job `allow_failure` for now" | "For now" is permanent. Fix the finding or record a scoped exception. |
| "Delete the old tag first, then push the new one" | If the new deploy fails, there is nothing to roll back to. Destructive steps last. |
| "CI passes, so production has it" | A green pipeline is not a deployed digest. Check what's running. |
| "The runner is flaky" | Flaky runners have causes: disk, inodes, MTU, CA store. Check the host. |

## LLM Mistakes Checklist

- Retrying an old deploy job or re-running an old run to "fix" production: it redeploys that commit (GitHub re-runs
  keep `GITHUB_SHA`/`GITHUB_REF`) — a rollback needing approval. GitLab guards: gitlab-ci §2.
- Treating `when: manual` as access control: limit deployers with a GitLab protected environment or GitHub required
  reviewers (both plan-dependent).

## Output Contract

1. **Diagnosis tied to evidence** — the run (Core Rule 1), its first error, the CI config at that SHA; anything not
   seen marked unverified, with a confidence.
2. **Read-only checks with explicit IDs** (project, pipeline/job ID, runner host); printed for the human when asked.
3. **The fix in the pipeline definition, via a merge request**; protected variables, refs, environments, runner
   settings and any deploy trigger, retry or cancel only with the owner's explicit approval — staging first.
4. **Shipped = built** — the build's recorded digest (buildx `--metadata-file` → `containerimage.digest`) = deployed
   = running `imageID` (for a multi-platform image, match the index entry for the node's platform); a green badge is
   not proof.
5. **Durable** — merged; tags re-cut, not moved; no `allow_failure`, skipped gate or widened variable scope left;
   owner and next action for anything open.

## References

- `references/gitlab-ci.md` — config-at-SHA, tag deploys, outdated/rollback deploy jobs, protected environments, runner routing, protected/per-branch variables, YAML/entrypoint traps, DinD vs socket, MR gate, manifest gates, SPA runtime config, polling to a terminal state
- `references/runner-host-ops.md` — host health first, disk-full disguises, scheduled prune, Docker/DinD MTU, old CA stores, moved package repos, notifiers that swallow errors
- Terraform plan gate → `devops-mutant-powers:infrastructure-provisioning` (its terraform-plan-gate reference)
- Templates: `tooling/ci/gitlab-ci/README.md`, `tooling/ci/github-actions/README.md`, `tooling/security/scanning/README.md`, `tooling/ci/starters/README.md`

## Verified References

- <https://docs.gitlab.com/ci/yaml/> — `tags`, `rules`, `when: manual` and `allow_failure` defaults, `image:entrypoint`, `needs`, `resource_group`, script quoting
- <https://docs.gitlab.com/ci/jobs/> — retried jobs run with the same parameters and variables
- <https://docs.gitlab.com/ci/variables/> — protected variables only on protected branches/tags
- <https://docs.gitlab.com/ci/caching/> — cache stored on the runner's machine by default; distributed cache shares it across runners
- <https://docs.gitlab.com/ci/runners/configure_runners/> — runner tag matching, "Run untagged jobs", protected runners
- <https://docs.gitlab.com/api/pipelines/> — pipeline status values and endpoints
- <https://docs.gitlab.com/api/jobs/> — `GET /projects/:id/pipelines/:pipeline_id/jobs`, `GET /projects/:id/jobs/:job_id/trace`, job `runner.description`
- <https://docs.github.com/en/actions/how-tos/monitor-workflows/enable-debug-logging> — `ACTIONS_STEP_DEBUG` / `ACTIONS_RUNNER_DEBUG` as secret or variable; secret wins
- <https://docs.gitlab.com/ci/environments/protected_environments/> — limits who deploys; Premium/Ultimate
- <https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs> — re-runs keep `GITHUB_SHA`/`GITHUB_REF`
- <https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments> — required reviewers; plan limits
- <https://docs.docker.com/reference/cli/docker/buildx/build/> — `--metadata-file` → `containerimage.digest`
