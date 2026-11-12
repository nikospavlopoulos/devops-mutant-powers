# Common Rationalizations

Excuses that lead to failing or unsafe manifests, each with the reality behind it. Load when reviewing a plan or a
reply for shortcuts. Topic tables live in the matching reference: `references/probes-and-readiness.md`,
`references/immutable-fields.md`, `references/resource-sizing.md`, `references/policy-and-linting.md` and
`references/autoscaling.md`.

| Excuse | Reality |
|---|---|
| "Kubernetes accepts most YAML, I'll just apply it" | Silent runtime failures are the norm — `diff`/`--dry-run=server` first. |
| "kubeconform passed" | It cannot see `memory: 750mi`, admission policies or immutable fields. Server dry-run can. |
| "This is a simple Deployment" | Simple manifests still need security context, requests, probes. |
| "`:latest` is fine for dev" | Mutable tags break rollback and mix versions across replicas. |
| "The default SA is fine" | Dedicated SA + least privilege; the default SA is shared by every pod. |
| "NetworkPolicy is optional" | Flat networking: every pod reaches every pod. |
| "Liveness should check the DB" | A DB blip restarts every replica at once — cascading failure. |
| "`kubectl edit` the selector/roleRef" | Immutable. Plan a recreate (`references/immutable-fields.md`). |
| "Kyverno enforces readOnlyRootFilesystem" | Check the live policy and its failure action; PSS does not require it. |
| "Use `command` to tweak the start" | It replaces the entrypoint. Use `args`, or fix the image. |
