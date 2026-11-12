# Refactors and State — Moves, Imports, Backups, Locks

Load this before any apply that rewrites resource addresses: a rename, a module split, a `count` → `for_each`
switch, a `terraform state mv`, or the adoption of an object made in a console. Done right, these
change only how state binds code to real objects. Done wrong, the plan destroys and re-creates them. The playbook:
freeze other applies, back up state, prove from the saved plan JSON that nothing changes, approve that exact file,
apply, verify, and write the rollback path down first. Every apply, state write, `force-unlock` and backend version
restore below needs the owner's explicit approval; when asked how to check, print the commands. Version numbers are
Terraform's; for OpenTofu, check its own changelog.

## 1. Version floors — read `required_version` first

| Feature | Terraform | Below the floor |
|---|---|---|
| `moved` block | 1.1 | `terraform state mv` (approval, coordinated — §2) |
| `import` block; `plan -generate-config-out` (experimental) | 1.5 | CLI `terraform import` (approval — §5) |
| `removed` block · `for_each` in `import` | 1.7 | `terraform state rm` — forgets the binding, destroys nothing (approval) · one `import` block per object |
| `moved` between resource types (only pairs the provider documents) | 1.8 | `state rm` the old + `import` the new (approval) |
| S3 backend lock file (`use_lockfile`) | 1.10 | DynamoDB lock table |
| `ephemeral` variables and outputs · write-only `*_wo` arguments | 1.10 · 1.11 | the value is stored in state and plan |
| `identity` instead of `id` in `import` (where the provider supports it, e.g. the AWS provider) | 1.12 | `id` string |

## 2. Renames and restructures: `moved`

`moved { from = <old address>  to = <new address> }`: before planning, Terraform looks for an object at `from` in
state and re-binds it to `to`. Nothing is destroyed.

| Change | `moved` block(s) |
|---|---|
| rename a resource | `from = aws_instance.a` · `to = aws_instance.b` |
| rename a module call | `from = module.a` · `to = module.b` — every instance of the call moves |
| into or out of a child module | full addresses, e.g. `from = aws_vpc.main` · `to = module.net.aws_vpc.main`; a module may only declare moves for its own objects and its children's, so write the block in the parent |
| `count` → `for_each` | one block per old index: `from = aws_instance.web[0]` · `to = aws_instance.web["a"]` |
| add `count` to a single resource | Terraform would propose `[0]` by itself; write `to = aws_instance.web[0]` explicitly anyway |
| different resource type | Terraform 1.8+, and only for pairs the provider documents |
| managed resource → data source | not possible |

- **Chain, don't rewrite:** a later rename adds `b → c` next to `a → b`, so a state still at `a` finds its way.
- **Shared or published modules keep every historical `moved` block.** Removing one is a breaking change: a caller
  that has not applied the move yet plans to delete the object instead of moving it. In a private module, remove them
  only when you are certain every user has applied the new version.
- **`terraform state mv` is the imperative path** (approval; the only one before 1.1). It rewrites state outside any
  reviewed plan, and until the matching code change lands, anyone else's plan may propose destroy + create — freeze
  other applies first.
  `-dry-run` lists the matching instances without changing state. `-backup`/`-backup-out` act only on a local state
  file, so with a remote backend take the backup with `state pull` (§4).

## 3. Prove a pure refactor from the saved plan

The plan's summary line does not tell you which objects moved, and a destroy hidden among forty moves is easy to miss.
Prove it from the JSON instead. Ship a refactor alone; make real changes in a separate plan.

```bash
cd <root>    # CHANGE: the root module; print workspace, backend key and account first (SKILL.md Core Rule 8)
terraform plan -refresh-only -input=false              # drift first — resolve it as its own change, not inside the refactor
terraform plan -input=false -lock-timeout=5m -out=tfplan
terraform show -json tfplan > plan.json

# Move list: compare pairs and count with the moves you intended
jq -r '.resource_changes[] | select(.previous_address) | "MOVED  \(.previous_address) -> \(.address)"' plan.json
# Imports riding along (a pure refactor has none)
jq -r '.resource_changes[] | select(.change.importing) | "IMPORT \(.address)"' plan.json
# Proof: exit 0 = every managed resource change is ["no-op"]; anything else fails it
jq -e '[.resource_changes[] | select(.mode == "managed" and .change.actions != ["no-op"])] | length == 0' plan.json
# The same rule through the repository gate (data-source reads pass; keep ALLOW_UNPROTECTED_DELETE=false)
ALLOWED_ACTIONS='no-op' bash tooling/iac/terraform/plan-gate.sh plan.json
```

`previous_address` appears only when an address changed (for example through a `moved` block); `change.importing`
appears only when the object is being imported. The gate hides no-op rows, so the move list above is what the
reviewer reads. `plan.json` holds sensitive values in cleartext — treat it like the plan file.

## 4. Checklist: an apply that rewrites addresses

| # | Step | Evidence |
|---|---|---|
| 1 | **Freeze** other applies to this state for the whole window: continuous integration (CI) mutex (`resource_group` in GitLab) plus a notice to everyone who applies. A state lock covers one operation, not your window | announced window |
| 2 | **Name the target** — workspace, backend key, account/subscription, region; `terraform version` equals CI's | printed |
| 3 | **Drift first** — `plan -refresh-only` shows nothing unexplained | clean or explained |
| 4 | **Back up** — `terraform state pull > <secure-dir>/<root>-<date>.tfstate` with CI's Terraform version (`state pull` converts the copy to the local CLI's state format); `terraform state list > <secure-dir>/before.txt`; backend version history confirmed on (below) | backup file, versioning on |
| 5 | **Plan once, prove it** (§3) — move list matches intent, zero non-`no-op` managed changes, no imports | proof output |
| 6 | **Approve that file** — a human reviews the move list and proof for *this* `tfplan` and approves; the manual CI job applies exactly it (`references/terraform-plan-gate.md`) | approval recorded |
| 7 | **Verify** — `terraform state list` diffed against `before.txt` shows only the intended renames; a fresh plan should report no changes (`-detailed-exitcode` → 0) — expected because the applied plan was all `no-op`, not a documented guarantee, so investigate any diff; the service still works | diff, exit 0 |
| 8 | **Close** — lift the freeze; delete the backup when the rollback window ends | done |

**Backend version history** — the real recovery path. State holds sensitive values, so backups never go into the repo
or into CI artifacts many people can read.
- S3 backend: bucket versioning is "highly recommended" for state recovery —
  `aws s3api get-bucket-versioning --bucket <state-bucket> --profile <p>` → `"Status": "Enabled"`.
- GCS (Google Cloud Storage) backend: Object Versioning on the bucket, same recommendation.
- GitLab-managed state: versions are kept by serial; an old one downloads through the API
  (`GET /api/v4/projects/<id>/terraform/state/<name>/versions/<serial>`) or `glab`, not the UI.

**Rollback path** — write it down before step 6:
- **The apply worked, but you want the old addresses back:** treat it as another refactor. Terraform documents no
  undo for a move; reverting the commit and adding inverse `moved` blocks (new → old address) follows from how
  `moved` works, not from a documented procedure — so prove that plan the same way (§3) before approving it.
- **State is damaged or wrong:** restore the backend's previous version (approval), e.g. S3 — copy the old object
  version back in place:
  `aws s3api copy-object --bucket <state-bucket> --key <key> --copy-source '<state-bucket>/<key>?versionId=<id>' --profile <p>`.
  An old version does not know objects created after it; those become unmanaged. Restore only to a point that matches
  real infrastructure.
- **`terraform state push <backup>` is refused by design** when the remote serial is higher or the lineage differs.
  Any write since the backup raises the remote serial, so after an apply expect the refusal. `-force` disables both
  checks and overwrites the remote state: last resort, explicit approval, other applies frozen.

## 5. Adopt existing objects: `import` blocks

```hcl
import {
  to = aws_s3_bucket.logs   # CHANGE: address of a resource block you wrote
  id = "<import-id>"        # CHANGE: format from the resource's Import docs; must be known at plan time
}
```

- `id` and `identity` (a map of the provider's identity attributes) are mutually exclusive; `for_each` imports many
  objects with one block; `provider` selects an aliased provider.
- The plan reports `N to import`; state is written only at apply. Make the first apply of an imported object a
  no-op: if the plan also wants to update or replace it, fix the configuration first.
- No configuration yet: `terraform plan -generate-config-out=generated.tf` (experimental; fails if the file exists;
  can emit conflicting arguments) — review and edit the output like any code before you commit it.
- CLI `terraform import <address> <id>` writes into state as soon as it runs, with no reviewed plan → approval; use it
  only below 1.5.
- One remote object, one address: Terraform expects each object to be bound to a single resource address. Importing
  it into a second address or a second state creates two owners.

## 6. `-target`

Terraform documents resource targeting for exceptional circumstances only, not routine use, because it can lead to
undetected configuration drift. If you must use it: approval, write down why, then run a full untargeted plan and
review it before you close the change. Never in the CI apply job. "I only want to apply this part" is a design signal:
split the configuration into smaller roots that can be applied independently.

## 7. Locks

- Every operation that can write state takes the lock automatically; if locking fails, Terraform does not continue.
  Wait with `-lock-timeout=5m`; `-lock=false` is not recommended (others may write the same state concurrently).
- `Error acquiring the state lock`: find the holder first — a running or hung CI job on this state, a colleague's
  apply — before you think about unlocking.
- `terraform force-unlock <LOCK_ID>` (approval): only for **your own** lock whose automatic release failed. It
  changes no infrastructure, but unlocking a lock someone else still holds allows two writers. The lock ID comes from
  the error output.
- S3 backend: `use_lockfile = true` locks with an S3 object `<key>.tflock` and needs `s3:GetObject`, `s3:PutObject`
  and `s3:DeleteObject` on it. DynamoDB locking (`dynamodb_table`) is deprecated; both can be set together while you
  migrate (locks are then taken from both).

## Verified References

- <https://developer.hashicorp.com/terraform/language/modules/develop/refactoring> — `moved` needs 1.1; module renames move all instances; a module may only move its own and its children's objects; `count`/`for_each` key moves; implicit move to `[0]`; chain blocks; removing a `moved` block is breaking (old configurations plan a delete), safe in private modules only after every user applied; no move to a data source; cross-type moves per provider docs
- <https://developer.hashicorp.com/terraform/language/block/moved> — `from`/`to`; objects renamed in state before planning, not destroyed
- <https://raw.githubusercontent.com/hashicorp/terraform/v1.8/CHANGELOG.md> — 1.8.0: `moved` between resources of different types when the provider supports it
- <https://raw.githubusercontent.com/hashicorp/terraform/v1.7/CHANGELOG.md> — 1.7.0: `removed` block; `for_each` in `import`
- <https://raw.githubusercontent.com/hashicorp/terraform/v1.10/CHANGELOG.md> — 1.10.0: S3 native state locking (both sources when combined with DynamoDB); ephemeral values
- <https://developer.hashicorp.com/terraform/cli/commands/state/mv> — `state mv` changes bindings outside a plan; tell others first or their plan may destroy + create; `-dry-run`; `-backup`/`-backup-out` local state only
- <https://developer.hashicorp.com/terraform/cli/commands/state/rm> — removes the binding without destroying; `removed` blocks as the alternative
- <https://developer.hashicorp.com/terraform/internals/json-format> — `previous_address` only when the address changed (e.g. `moved`); `change.importing` only when importing
- <https://developer.hashicorp.com/terraform/cli/commands/state/pull> — converts the pulled copy to the local CLI's state format, outputs to stdout
- <https://developer.hashicorp.com/terraform/cli/commands/state/push> — refused on differing lineage or higher destination serial; `-force` disables both checks and overwrites
- <https://developer.hashicorp.com/terraform/cli/commands/state/list> — one address per line, filterable by address or `-id`
- <https://developer.hashicorp.com/terraform/language/backend/s3> — bucket versioning highly recommended; `use_lockfile`, `<key>.tflock`, required S3 actions; DynamoDB locking deprecated; both configurable during migration
- <https://developer.hashicorp.com/terraform/language/backend/gcs> — Object Versioning highly recommended; state locking supported
- <https://docs.gitlab.com/user/infrastructure/iac/terraform_state/> — state versions by serial, API download path, no UI download
- <https://docs.aws.amazon.com/cli/latest/reference/s3api/get-bucket-versioning.html> — `Status` `Enabled`/`Suspended`
- <https://docs.aws.amazon.com/AmazonS3/latest/userguide/RestoringPreviousVersions.html> — restore by copying a previous version in place (`copy-object --copy-source …?versionId=`)
- <https://docs.aws.amazon.com/cli/latest/reference/s3api/copy-object.html> — `--copy-source` with `?versionId=`; global `--profile`
- <https://developer.hashicorp.com/terraform/cli/commands/show> — with `-json`, sensitive values are shown in plain text
- <https://docs.gitlab.com/ci/resource_groups/> — `resource_group` keeps a deployment job from running concurrently across pipelines
- <https://developer.hashicorp.com/terraform/language/block/import> — `to`, `id` (known at plan), `identity` (exclusive with `id`), `for_each`, `provider`
- <https://developer.hashicorp.com/terraform/tutorials/state/state-import> — import blocks need Terraform 1.5+; `Plan: 1 to import …`; state changed during apply; make the first operation a no-op
- <https://developer.hashicorp.com/terraform/language/import/generating-configuration> — experimental since 1.5; existing file → error; possible conflicting arguments; review the output
- <https://developer.hashicorp.com/terraform/cli/commands/import> — CLI import writes into state at the given address; one remote object bound to one address
- <https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/route53_record.html.markdown> — `identity` in `import` from Terraform 1.12 (AWS provider example)
- <https://developer.hashicorp.com/terraform/language/manage-sensitive-data> — `ephemeral` 1.10+, write-only 1.11+; `sensitive` values still stored in state and plan
- <https://developer.hashicorp.com/terraform/cli/commands/plan> — `-target` for exceptional circumstances, drift risk, split large configurations; `-refresh-only`; `-detailed-exitcode`
- <https://developer.hashicorp.com/terraform/language/state/locking> — automatic locking, stop on failure, `-lock=false` not recommended, force-unlock only your own failed lock, lock ID as nonce
- <https://developer.hashicorp.com/terraform/cli/commands/force-unlock> — `force-unlock LOCK_ID`; does not modify infrastructure
