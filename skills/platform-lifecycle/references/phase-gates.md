# Phase Gates — Full Table

Load this file when writing or reviewing the phase plan for a migration, a node removal or a cluster retirement:
what each phase does, the gate that ends it and where the human stops. `SKILL.md` keeps the condensed ladder and
the fixed health block; the per-app method is `references/workload-migration.md`, the per-node and per-cluster steps
are `references/decommission.md`. Abbreviations: PV/PVC = PersistentVolume/PersistentVolumeClaim, IaC = infrastructure
as code, CMDB = configuration management database.

| Phase | Do (read-only unless approved) | Gate (must be able to fail) | Stop |
|---|---|---|---|
| 0. Inventory | Nodes, roles, versions, pods per node, PV node affinity, VolumeAttachments, storage replicas, LoadBalancer Services, DNS records, IaC resources, owners (`references/decommission.md` §1, `references/workload-migration.md` §1) | Inventory diffed against IaC and against a second source (cloud console, CMDB); unexplained items = 0 | yes |
| 1. Plan | Ordered steps, verb contract, rollback per step, the point of no return, health block, owner per step | Human reads the plan back; every step has an undo or is marked irreversible | yes |
| 2. Protect | Backups/snapshots incl. the datastore and its token (`references/decommission.md` §2), PV `Retain`, Flux `prune: disabled` on PVCs, park apps not moving | Restore of one backup actually tested; Retain visible on every data PV | yes |
| 3. Canary | Hardest workload first — migrate, or drain the first node | Readiness spectrum up to the user path; old system still serving | yes |
| 4. Bulk | Remaining workloads / nodes, one unit at a time | Health block green after *each* unit | after each unit |
| 5. Point of no return | Delete the old cluster/servers/volumes (approval) | Old system idle for the agreed window; no traffic in its access logs | yes |
| 6. Close | Leftovers checklist, IaC matches reality, handoff | `plan` shows no drift; leftovers list empty or ticketed | done |

The readiness spectrum used by the canary gate is `references/workload-migration.md` §8; the leftovers checklist is
`references/decommission.md` §6; the gates before destroying a whole cluster are `references/decommission.md` §7.

## Verified References

- Sources for each gate's mechanics (PV `Retain`, Flux `prune: disabled`, datastore snapshots, quorum) are listed in
  `references/decommission.md`; readiness and parity sources in `references/workload-migration.md`.
