# Commands — Job Triage, Destination Truth, Offline Gate

Copy-paste commands for checking a transfer Job and what its destination really holds. Every command names its
target: `--context <ctx> -n <ns>` on `kubectl`, the exact remote, bucket and prefix on `rclone`. Everything here is
read-only or offline; applying or deleting Jobs, PVCs or Secrets, scaling a holder down, or writing to shared
buckets needs explicit human approval and is marked "(approval)" where the other references show it. Asked "how to
check"? Print these for the human; do not run them. Topic-specific commands live in the other references
(placement and sidecar checks in `references/job-template.md`, data profiling and `tar` streaming in
`references/transfer-tools.md`).

```bash
# Job, its pods and conditions (read-only)
kubectl --context <ctx> -n <ns> get job <job> -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
kubectl --context <ctx> -n <ns> get pods -l batch.kubernetes.io/job-name=<job> -o wide
kubectl --context <ctx> -n <ns> logs <pod> --timestamps | grep -E 'measured|skip:|ERROR|WARN|SUCCESS|FAILED'
kubectl --context <ctx> -n <ns> describe pod <pod>              # Pending/evicted: scheduler and kubelet events
# Holder of a RWO volume: node, real labels (for podAffinity), taints
kubectl --context <ctx> -n <ns> get pod -o wide --show-labels | grep <holder>
kubectl --context <ctx> describe node <node> | grep -A3 Taints
# Destination truth, from a pod that has the rclone remote configured
rclone size --json dst:<bucket>/<prefix>                        # count + bytes; a missing prefix also says 0
rclone lsf -R --files-only dst:<bucket>/<prefix>/<dir> | wc -l  # per-directory count
rclone cat dst:<bucket>/<prefix>/_SUCCESS                        # must print content; empty = not done
# Offline, before any apply
bash -n tooling/scripts/strict-shell-template.sh
kubeconform -strict -summary -kubernetes-version <x.y.z> tooling/kubernetes/batch-job/transfer-job.yaml
```
