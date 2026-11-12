# DevOps Brainstorming

**In plain terms:** in infrastructure, what your human partner wants lands on systems that already exist and already
have owners. Read those first, size the work by what could break rather than by how small the diff looks, and let
them describe the goal in their own words before you hand them choices.

Adjacent skills: an approved written design goes to `devops-mutant-powers:writing-plans`; proving the built change
works for users is `devops-mutant-powers:verification-before-completion`. The bootstrap's Operating Principles
(`devops-mutant-powers:using-devops-mutant-powers`) hold throughout; this file does not repeat them.

## 1. Look before you ask

Read the repository on your own before your first message, so the first question is a sharp one (for the repository
this replaces the skill's "offer recon": reading files changes nothing, and the hard gate allows it):

- **The owner of each resource you would touch:** GitOps (a Flux Kustomization or HelmRelease, an Argo CD
  Application), an operator, IaC (infrastructure as code: Terraform, Pulumi), or a human. A change made past the
  owner gets reverted or drifts.
- **The existing stack:** the GitOps tool, Kustomize or Helm, how secrets reach workloads, CI, monitoring.
- **Environments:** which directories, branches or workspaces map to staging and production, and what deploys from
  where.

Live or external reads are recon you offer, not do: `kubectl` against a cluster, cloud APIs, `terraform plan` (it
reads the live remote objects and holds a state lock by default, so nobody else can take the lock while it runs). Say
what you would look at and against which target; they decide.

## 2. Size by blast radius, not by line count

| Size | When |
|---|---|
| A quick, clear task | only if it is reversible, confined to the working tree and not production |
| A small change, described in chat | at least this for anything that touches shared or production systems |
| A written design | migrations, cutovers, decommissions, data moves, access-model changes |

A one-line change to a shared ingress, a production alert route or a CronJob schedule is not a quick task. When in
doubt, size up. If it grows mid-task, stop, step up a size and say so.

## 3. Quick tasks and "skip the questions"

The task is the file edit in the working tree. These still wait for an explicit yes, every time:

- committing or pushing to a branch something deploys from. In GitOps a push to the watched branch is the deploy:
  Flux, or Argo CD with automated sync, fetches it and applies it without anyone else acting.
- apply, reconcile, restart, rotate, delete.

Skipping the questions never skips that. Make the edit, show the diff, list the steps that would change live state,
and ask.

## 4. Infrastructure ground to cover

The territory lives in [devops-ground-to-cover.md](devops-ground-to-cover.md), shared with `grilling`: read it before
your first message. It is never read out as a checklist; find what you can in the repository first.

## 5. How it gets made in infrastructure

The existing stack decides by default: Flux or Argo CD, Kustomize or Helm, SOPS (Secrets OPerationS) or External
Secrets Operator, Terraform or Pulumi. Read it, do not ask it. A new tool (a second GitOps controller, a new secrets
backend, a different IaC tool) is your human partner's decision. Say your defaults out loud ("I'll follow the
existing Helm releases") and mark each in the design as your call.

## 6. Describe first, then choose

- **Intent** (what, why, for whom): open questions, one per message, until they have described it.
- **Decisions** (how it gets made, which of several real paths): 2-4 options built from what recon found, not generic
  ones; the recommended one first with a one-line reason; a free-text slot ("Other, or amend one"); multi-select when
  options combine. After their answer, ask "What did I miss?".
- **Weigh privately first.** Drop weak options and any that contradict what they told you before you show the rest.
- **The picker.** In Claude Code use the question picker (`AskUserQuestion`; its "Other" row for a typed answer is
  added automatically, and multi-select is a per-question setting) only when nothing else is in the reply and there
  are four or fewer short decisions: it can hide the text before it. Otherwise, and in other harnesses, a numbered
  list ending with "or tell me your own".

Example, after recon found SOPS-encrypted Secrets for the other apps and a database operator that generates
application credentials:

```text
How should the new service get its database password?
1. A SOPS-encrypted Secret beside the others (recommended: same path and review flow as every other app)
2. The Secret the database operator generates, referenced by name
3. Other, or amend one
```

## 7. The written design: infrastructure additions

Beyond the sections in SKILL.md, cover:

- the environments and the order the change goes through them
- rollback and restore, with the point of no return marked
- the proof path: the command or check that shows it works for users
- the owner of every resource touched
- secrets and access: what is needed, where it lives, who gets it (names only, never values)
- the change window and the approver
- how the change is watched while it rolls out (which dashboard or alert), and by whom
- the restore point before each irreversible step, and when a restore from it was last tested

Diagrams go in as Mermaid source with no init line, so GitHub renders them with its defaults.

When the written design is ready, end the hand-over with one line: say "grill me" to stress-test it
(`../../grilling/SKILL.md`).

## 8. Builder check for infrastructure

Fill the domain in `../builder-check-prompt.md` as "a site reliability engineer who will carry out this change in
production and cannot reach the author". Append to the dispatch prompt:

```text
Read only the design document and files in the repository. Do not run kubectl, flux, helm, terraform, a cloud CLI
or any other command against a cluster or cloud account, not even a dry run. Run every shell with
KUBECONFIG=/nonexistent.
```

## 9. Spikes only on throwaway targets

A spike runs on something you can delete without asking anyone: a kind (Kubernetes in Docker) or k3d cluster, a lab
namespace set aside for experiments, a scratch cloud account. A spike that needs shared or production systems is not
a spike: it is a change, sized as in section 2 and gated like one.

## 10. Showing

A diagram only when the `visual` skill's criteria hold: offered as one closing statement in a reply that asks
nothing, drawn on a yes; the browser companion only when asked. How, and when the first render needs a yes (it
downloads the renderer): `../../visual/SKILL.md`.

## Verified References

- <https://code.claude.com/docs/en/tools-reference#askuserquestion-tool-behavior> — `AskUserQuestion` asks
  multiple-choice questions; the person picks an option or types their own text through the `Other` row.
- <https://code.claude.com/docs/en/agent-sdk/user-input> — each question carries 2-4 options and a `multiSelect` flag
  that allows several selections.
- <https://fluxcd.io/flux/components/source/gitrepositories/> — `.spec.ref.branch` names the branch; it is fetched every
  `.spec.interval`, and a new revision produces a new artifact.
- <https://fluxcd.io/flux/components/kustomize/kustomizations/> — every `.spec.interval` the controller fetches the
  source, builds it and applies it to the cluster, correcting drift.
- <https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/> — with automated sync, Argo CD syncs an application
  when the manifests in Git differ from the live state.
- <https://developer.hashicorp.com/terraform/cli/commands/plan> — plan reads the current state of existing remote
  objects; `-lock=false` exists because plan holds a state lock by default.
- <https://developer.hashicorp.com/terraform/language/state/locking> — a held lock prevents others from acquiring it.
- <https://kind.sigs.k8s.io/> — kind runs local Kubernetes clusters using Docker containers as nodes.
- <https://k3d.io/stable/> — k3d runs single- and multi-node k3s clusters in Docker for local development.
