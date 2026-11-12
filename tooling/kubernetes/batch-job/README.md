# Batch transfer Job templates

One-shot copy of a volume to object storage (rclone) or to another volume (rsync), built so that a
"Completed" Job means the data is really there. Guidance and rationale: `skills/batch-data-jobs/`.

| File | What it is |
|---|---|
| `transfer-job.yaml` | ServiceAccount + scratch PVC + Job. Source PVC mounted read-only; nothing else holds it. |
| `transfer-job-rwo-affinity.yaml` | Same, for a ReadWriteOnce source held by a running pod: podAffinity to the holder's node, its tolerations, a compatible nodeSelector, smaller requests. |
| `../../scripts/strict-shell-template.sh` | The script the Job runs (mounted from the `transfer-script` ConfigMap). Phases: preflight, measure, transfer, verify, ownership, finalize. |

Every value you must edit carries a `# CHANGE:` comment. Applying anything to a shared cluster, creating
Secrets, and deleting Jobs or PVCs need explicit human approval.

## Image

The official `rclone/rclone` image is Alpine with `ENTRYPOINT ["rclone"]` and no bash, so the
script cannot run in it unchanged. Build a thin image on top of a pinned release and push it under
an immutable tag (or reference it by digest):

```dockerfile
FROM rclone/rclone:<pinned-version>
RUN apk add --no-cache bash rsync
```

The Job's `command` replaces the image ENTRYPOINT, so nothing else is needed.

## Script ConfigMap

Generate it from the template so the file you syntax-check is the file that runs:

```bash
kubectl --context <ctx> create configmap transfer-script -n <ns> \
  --from-file=transfer.sh=tooling/scripts/strict-shell-template.sh \
  --dry-run=client -o yaml > transfer-script.configmap.yaml
```

Mounting a file instead of an inline `bash -c` script also avoids kubelet expansion: Kubernetes
rewrites `$(VAR)` in `command`/`args` from the container env and turns `$$` into `$`.

## Offline gate (run before any apply)

```bash
# 1. YAML parses and contains what you expect
python3 -c 'import sys,yaml; [print(d["kind"], d["metadata"]["name"]) for d in yaml.safe_load_all(open(sys.argv[1]))]' transfer-job.yaml
# 2. the script parses
bash -n tooling/scripts/strict-shell-template.sh
# 3. schema, strict (unknown fields fail); use the cluster's minor version
kubeconform -strict -summary -kubernetes-version <x.y.z> transfer-job.yaml transfer-script.configmap.yaml
# 4. Jobs with an inline script: extract exactly what the container runs and parse it
python3 -c 'import sys,yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("kind") == "Job":
        print(d["spec"]["template"]["spec"]["containers"][0]["args"][-1])' job.yaml > /tmp/inline.sh && bash -n /tmp/inline.sh
```

With cluster access (read-only, no state change): `kubectl --context <ctx> -n <ns> apply --dry-run=server -f transfer-job.yaml`,
then diff the rendered Job against the last Job that is known to have worked:
`kubectl --context <ctx> -n <ns> get job <known-good> -o yaml`.

## Run and watch (after approval)

```bash
kubectl --context <ctx> -n <ns> apply -f transfer-script.configmap.yaml -f transfer-job.yaml
kubectl --context <ctx> -n <ns> get job,pod -l app.kubernetes.io/name=transfer -o wide
kubectl --context <ctx> -n <ns> describe pod -l app.kubernetes.io/name=transfer     # Pending: read the scheduler events
kubectl --context <ctx> -n <ns> logs -f job/<job-name>
kubectl --context <ctx> -n <ns> wait --for=condition=complete job/<job-name> --timeout=6h   # a Failed Job never turns complete
kubectl --context <ctx> -n <ns> get job <job-name> -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
```

`Complete` is necessary, not sufficient: confirm the destination marker is non-empty and the counts in
the run log (`/scratch/state/<JOB_NAME>/<RUN_ID>/run.log`) match before anyone consumes the data.

## Re-runs and cleanup

- The pod template of an existing Job cannot be edited. To retry: delete the old Job (approval), create it
  under a new `metadata.name`, keep `RUN_ID` to resume from markers, or set a new `RUN_ID` for a fresh run.
- `ttlSecondsAfterFinished` deletes the Job **and its pods**, so logs go with it; enable it only when logs are
  shipped elsewhere or the run log on the scratch PVC is enough.
- Scheduled runs: wrap the Job spec in a CronJob and take `RUN_ID` from the pod's `batch.kubernetes.io/job-name`
  label — a fixed `RUN_ID` makes every run after the first skip all phases and "succeed" with nothing copied
  (`skills/batch-data-jobs/references/job-template.md`, "Scheduled runs").
- Delete the scratch PVC (approval) only after the consumer has confirmed the data; it holds the evidence.
