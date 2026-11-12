# Argo Rollouts — Paused, Degraded, Aborted, and Reading an Analysis

Load this when a Rollout is `Paused`, `Degraded` or aborted, an AnalysisRun failed or is `Inconclusive`, or someone
wants to promote, abort, retry or undo. It explains why a Rollout stopped, how to judge whether a failed analysis
was a real failure or a "false negative" from the AnalysisRun measurements, and which commands change state.
Facts are for Argo Rollouts v1.10 (current at the time of writing).

**Targets.** `kubectl argo rollouts` and `kubectl` always carry `--context <ctx>` and `-n <ns>`. Promote, abort,
retry, undo, restart and the matching Argo CD resource actions change live state: each needs the owner's explicit
approval.

## 1. Model in one screen

- A **Rollout** is a Deployment-like resource with a `canary` or `blueGreen` strategy. Argo Rollouts never reads or
  writes Git; under Argo CD the Rollout manifest is owned by an Application like any other object.
- **Canary:** `steps` of `setWeight`, `pause` (with `duration`, or indefinite — then it waits for a promote),
  `setCanaryScale` (only with a traffic router) and analysis. Without `trafficRouting` the weight is approximated by
  replica counts (10 replicas at 10% → 1 canary pod, 9 stable). No `steps` = rolling-update behaviour.
  `maxSurge`/`maxUnavailable` default to 25%.
- **Blue-green:** `activeService` (required), optional `previewService`, `autoPromotionEnabled` (default `true`),
  `autoPromotionSeconds`, `prePromotionAnalysis` (decides whether traffic switches), `postPromotionAnalysis` (a
  failure aborts and switches traffic back to stable), `scaleDownDelaySeconds` (default 30), `previewReplicaCount`.
- **Spec defaults:** `progressDeadlineSeconds` 600; `progressDeadlineAbort` false (exceeding the deadline marks the
  Rollout failed but does not abort unless set); `abortScaleDownDelaySeconds` 30; `revisionHistoryLimit` 10;
  `rollbackWindow` unset; `workloadRef` + `scaleDown: never|onsuccess|progressively` when migrating from a Deployment.

## 2. Why is it Paused?

`status.pauseConditions[].reason` says who paused it:

| Reason | Meaning | Who resumes |
|---|---|---|
| `CanaryPauseStep` | a canary `pause` step | the `duration` elapsing, or `promote` (approval) for an indefinite pause |
| `BlueGreenPause` | blue-green waiting before promotion (`autoPromotionEnabled: false`, or `autoPromotionSeconds` set) | `promote` (approval); `autoPromotionSeconds` resumes it only while `autoPromotionEnabled` is not `false` |
| `InconclusiveAnalysisRun` / `InconclusiveExperiment` | analysis neither passed nor failed | a human: promote or abort, after §4 |
| (none, `spec.paused: true`) | paused by hand or created paused | the owner of that edit |

The controller writes `status.phase: Paused` with that reason (or `manually paused`) as `status.message`; Argo CD
shows the phase as `Suspended` with the same message, and so does the Application unless another child is worse.
That is a wait state, not a failure.

## 3. Why is it Degraded or aborted?

The controller sets `status.phase: Degraded` when a condition is `InvalidSpec` or has reason `RolloutAborted`
(`Rollout aborted update to revision N`) or `ProgressDeadlineExceeded`; `status.message` is `<reason>: <message>`,
and Argo CD shows both. For an analysis-triggered abort the controller also reports `AnalysisRunFailed`
(`AnalysisRun '…' owned by the Rollout '…' failed.`).

After an abort the previous ReplicaSet is active again, but `spec.template` still holds the new version. If the
Rollout leaves the aborted state it tries the new version again; changing `spec.template` back to the previous
version fully reverts it. Under GitOps, that means: Git still says "new version", the cluster runs the old one, the
Application stays `Degraded`, and the fix is a commit — roll forward with a fix, or revert the commit.

## 4. Reading an AnalysisRun before any promote or retry

```bash
kubectl --context <ctx> -n <ns> get analysisruns.argoproj.io
kubectl --context <ctx> -n <ns> get analysisruns.argoproj.io <run> -o json | jq '{
  phase: .status.phase, message: .status.message,
  metrics: [.status.metricResults[] | {name, phase, count, failed, inconclusive, error, consecutiveError, message,
            last: [.measurements[]? | {phase, value, message}][-3:]}] }'
# The conditions that produced those phases
kubectl --context <ctx> -n <ns> get analysisruns.argoproj.io <run> -o json \
  | jq '.spec.metrics[] | {name, successCondition, failureCondition, failureLimit, inconclusiveLimit,
                           consecutiveErrorLimit, count, interval}'
```

Run phases: `Pending`, `Running`, `Successful`, `Failed`, `Error`, `Inconclusive`. A failed run aborts the Rollout
(canary weight back to 0); an inconclusive run pauses it. Judge the run from its measurements, never from its phase
alone:

| What the measurements show | What it means | Next step |
|---|---|---|
| real values that breach the condition | a true failure of the new version | keep it aborted; fix forward or revert in Git |
| `value: NaN` and only a `successCondition` | the provider returned no number (for example a ratio over zero requests); a NaN fails a bare `successCondition` | the template decides NaN handling (`isNaN(result)`), so fix the template in Git, generate real traffic, then retry (approval) |
| metric `Error`, `consecutiveError` at the limit (default 4) | the query or provider failed — no evidence about the app either way | fix the provider config or query in Git; do not read it as a pass |
| one failed measurement failed the metric | `failureLimit` defaults to 0 (no failure tolerated); `inconclusiveLimit` defaults to 0 | if tolerance was intended, set it in the template in Git |
| values that describe the wrong workload | the query is not scoped to the canary (wrong args or labels) | fix the template's args in Git |
| a failed metric marked `dryRun` | it does not affect the Rollout | not the cause — look at the other metrics |
| `Inconclusive` measurements | both conditions set and neither true, or no condition at all (a NaN with both set lands here) | a human reads the values, then promote or abort (approval); tighten the conditions in Git |

A "false negative" is proven only when the measurements show the new version met the intended criteria and the
template encoded them wrongly. Then the durable fix is a template change in Git followed by a retry (approval).
`promote --full` skips analysis, pauses and steps: it is the owner's risk acceptance, not a fix.

## 5. Read-only commands

```bash
kubectl argo rollouts get rollout <rollout> --context <ctx> -n <ns>
kubectl argo rollouts status <rollout> --context <ctx> -n <ns> --watch=false
kubectl --context <ctx> -n <ns> get rollouts.argoproj.io <rollout> -o json | jq '{
  phase: .status.phase, message: .status.message, abort: .status.abort,
  pauses: .status.pauseConditions, conditions: [.status.conditions[]? | {type, reason, message}] }'
```

`status` without `--watch=false` waits until the Rollout finishes or `--timeout` passes (0 = forever) — always give
an agent a bound.

## 6. Approval-gated commands

```bash
# (approval) Next step of a paused canary, or a paused blue-green pre-promotion
kubectl argo rollouts promote <rollout> --context <ctx> -n <ns>
# (approval) Skip ALL remaining analysis, pauses and steps — owner's explicit risk acceptance only
kubectl argo rollouts promote <rollout> --full --context <ctx> -n <ns>
# (approval) Stop progressing; the previous ReplicaSet becomes active
kubectl argo rollouts abort <rollout> --context <ctx> -n <ns>
# (approval) Restart an aborted rollout — after the cause is fixed (§4)
kubectl argo rollouts retry rollout <rollout> --context <ctx> -n <ns>
```

(approval) `kubectl argo rollouts undo <rollout> --context <ctx> -n <ns> [--to-revision N]` rolls the live Rollout
back to an earlier revision. On an Argo CD-managed Rollout that live change differs from Git, so (inferred) it is
drift that `selfHeal` reverts — revert the commit instead. Argo CD exposes the same levers as resource actions —
`resume`, `abort`, `retry`, `promote-full`, `skip-current-step`, `pause`, `restart` (`argocd app actions run …`,
approval) — each enabled only in the matching state (e.g. `retry` only when aborted).

## 7. GitOps interplay

- Re-applying an older template is treated as a new spec change — all steps and analysis run again — unless the
  target revision is inside `rollbackWindow`, or the old blue-green ReplicaSet is still scaled up, or the canary had
  not finished and the target is its stable ReplicaSet (fast-tracked).
- With Rollouts in place, Argo CD's own rollback is normally not needed: Rollouts reverts the cluster, Argo CD sees
  Git and the Rollout spec agree, and the next version is a roll-forward commit.

## Verified References

- <https://argo-rollouts.readthedocs.io/en/stable/features/canary/> — steps, indefinite pause + promote, `setCanaryScale` needs a traffic router, replica-ratio weights, no steps = rolling update, 25% defaults
- <https://argo-rollouts.readthedocs.io/en/stable/features/bluegreen/> — `activeService` required, auto-promotion default, `autoPromotionSeconds` ignored when `autoPromotionEnabled: false`, pre/post-promotion analysis, `scaleDownDelaySeconds` 30, `previewReplicaCount`
- <https://argo-rollouts.readthedocs.io/en/stable/features/specification/> — `progressDeadlineSeconds` 600, `progressDeadlineAbort` false, `abortScaleDownDelaySeconds` 30, `revisionHistoryLimit` 10, `rollbackWindow`, `workloadRef` scale-down modes
- <https://argo-rollouts.readthedocs.io/en/stable/features/analysis/> — failed run aborts (weight to 0), inconclusive pauses, inconclusive when neither condition holds or none is set, `failureLimit` default 0, NaN/Inf handling with `isNaN`, `dryRun` metrics do not affect the Rollout, post-promotion "fails or errors" aborts, secrets same namespace
- <https://argo-rollouts.readthedocs.io/en/stable/features/rollback/> — older template re-runs steps and analysis; the two fast-track exceptions; `rollbackWindow` fast-tracks
- <https://argo-rollouts.readthedocs.io/en/stable/FAQ/> — Rollouts never touches Git; roll forward under GitOps; Argo CD marks a paused Rollout suspended; Argo CD rollback normally unnecessary
- CLI: <https://argo-rollouts.readthedocs.io/en/stable/generated/kubectl-argo-rollouts/kubectl-argo-rollouts_promote/> (`--full` skips analysis, pauses, steps; `--context`, `-n`) · <https://argo-rollouts.readthedocs.io/en/stable/generated/kubectl-argo-rollouts/kubectl-argo-rollouts_abort/> (previous ReplicaSet active, `spec.template` still new) · <https://argo-rollouts.readthedocs.io/en/stable/generated/kubectl-argo-rollouts/kubectl-argo-rollouts_retry/> · <https://argo-rollouts.readthedocs.io/en/stable/generated/kubectl-argo-rollouts/kubectl-argo-rollouts_status/> (`--watch`, `--timeout`, 0 = forever) · <https://argo-rollouts.readthedocs.io/en/stable/generated/kubectl-argo-rollouts/kubectl-argo-rollouts_get_rollout/> · <https://argo-rollouts.readthedocs.io/en/stable/generated/kubectl-argo-rollouts/kubectl-argo-rollouts_undo/>
- Source (v1.10.0): <https://github.com/argoproj/argo-rollouts/blob/v1.10.0/pkg/apis/rollouts/v1alpha1/types.go> (pause reasons, phases, `abort`) · <https://github.com/argoproj/argo-rollouts/blob/v1.10.0/pkg/apis/rollouts/v1alpha1/analysis_types.go> (run phases, `inconclusiveLimit` 0, `consecutiveErrorLimit` 4, metric result fields) · <https://github.com/argoproj/argo-rollouts/blob/v1.10.0/utils/conditions/conditions.go> (`RolloutAborted`, `ProgressDeadlineExceeded`, `InvalidSpec`, `AnalysisRunFailed` messages) · <https://github.com/argoproj/argo-rollouts/blob/v1.10.0/utils/rollout/rolloututil.go> (`status.phase`/`message`: Degraded conditions, `manually paused`, pause reason) · <https://github.com/argoproj/argo-rollouts/blob/v1.10.0/rollout/pause.go> (blue-green auto-promotion only when `autoPromotionEnabled` is not false)
- Argo CD side: <https://github.com/argoproj/argo-cd/blob/v3.5.4/resource_customizations/argoproj.io/Rollout/health.lua> (surfaces `status.phase`/`message`, `Paused` → `Suspended`; condition fallback for old Rollouts) · <https://github.com/argoproj/argo-cd/blob/v3.5.4/resource_customizations/argoproj.io/Rollout/actions/discovery.lua> (resource actions and when each is enabled)
