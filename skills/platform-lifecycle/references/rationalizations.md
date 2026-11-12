# Common Rationalizations

Load this file when reviewing a plan or a reply for shortcuts: each row pairs an excuse heard during migrations,
drains, node fixes and decommissions with why it fails. The condensed form is the LLM Mistakes Checklist in
`SKILL.md`; the mechanics behind each row live in the reference it names. PDB = PodDisruptionBudget, IaC =
infrastructure as code.

| Excuse | Reality |
|---|---|
| "The runbook / last month's notes list the nodes" | Notes drift. Query live state; a plan from a stale list drains the wrong node. |
| "Drain them all in parallel, PDBs protect us" | PDBs only cover workloads that have them, and parallel drains move pods onto nodes you are about to drain. Cordon all, drain one, health block. |
| "Drain is stuck — add `--disable-eviction`" | That bypasses every PDB. Read *which* PDB returns 429 and why (`references/node-operations.md` §1). |
| "Drain first, Longhorn will sort the replicas out" | A drain blocks on the instance-manager while the node holds a last healthy replica. Evict storage first, wait for zero replicas, then drain. |
| "I fixed it on the two nodes that broke" | The other nodes have the same config and break next week. Codify it and apply it to the whole node class. |
| "The drop-in file is there, so the kubelet uses it" | CLI flags beat drop-ins and the kubelet reads config only at start. Prove it with `/configz` on every node. |
| "Migrate the simple apps first to build confidence" | Simple apps prove nothing about the platform gaps. Canary the hardest one while rollback is cheap. |
| "New cluster is green, delete the old one today" | Green is a component claim. Keep the old system serving as the control group until the user path is proven over a full cycle. |
| "`kubectl delete node` removes the server" | It removes an API object. A running kubelet re-registers it; the VM, disks, IPs, DNS and IaC state all remain. |
| "We'll clean up leftovers later" | Orphaned Retain volumes bill, stale IaC recreates deleted servers on the next apply. The leftovers checklist is part of the change. |
| "VACUUM the k3s database, it's just SQLite" | It needs up to 2× the file size in free disk, the API is down meanwhile, and without a backup of the db directory *and* the token it is unrecoverable. |
| "Restarting k3s is harmless, the containers keep running" | The containers do, the API does not: recent kine VACUUMs `state.db` on every start, so on a bloated server a routine restart is a long outage (`references/node-operations.md` §5). |

## Verified References

- <https://longhorn.io/docs/1.13.0/references/settings/> — node drain policy `block-if-contains-last-replica` (default) blocks drains holding the last healthy replica
- <https://longhorn.io/docs/1.13.0/maintenance/maintenance/> — drain policy works by blocking eviction of the instance-manager pod; removing a node = disable scheduling, evict replicas, detach, then delete
- <https://github.com/k3s-io/kine/blob/master/pkg/drivers/sqlite/sqlite.go> — kine runs a startup `VACUUM` before serving (from v0.14.15)
- Drain and PDB behaviour, kubelet config precedence and Node self-registration are sourced in `references/commands.md`;
  the SQLite VACUUM disk need and the k3s token backup in `references/node-operations.md` §5
