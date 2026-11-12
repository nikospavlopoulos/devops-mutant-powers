---
name: configuration-management
description: Use when writing or running Ansible, Puppet, Chef or Salt playbooks/manifests — check/noop runs, idempotency, fleet rollout, host drift, UNREACHABLE, Missing sudo password, couldn't resolve module/action, undefined variable, Duplicate declaration, dependency cycle, Could not find class. Terraform → infrastructure-provisioning.
---

# Configuration Management

**In plain terms:** configuration management (CM) tools such as Ansible, Puppet, Chef and Salt describe the end
state of hosts in a repository and converge the hosts to it. A run is trusted only when it was previewed, landed
on one canary host first, the service on that host works, and a second run changes nothing.

## When to Use

- Writing or reviewing Ansible playbooks and roles, Puppet manifests, modules and Hiera data, Chef cookbooks, Salt states
- A run fails: `UNREACHABLE!`, `Missing sudo password`, `couldn't resolve module/action`, `'<name>' is undefined`,
  `Duplicate declaration`, `Found 1 dependency cycle`, `Could not find class`
- "It worked on one host, roll it to all" — a package, file, service or kernel setting for a host group
- A task or resource reports a change on every run; a handler restarts a service every time
- A host differs from the repo (a hand edit), or a secret must go into playbooks, Hiera or pillar

**Not this skill:** machines, networks, load balancers, cloud firewalls or DNS made with Terraform/OpenTofu or
Pulumi → `devops-mutant-powers:infrastructure-provisioning` (it creates the machine, CM converges what runs
inside; a change needing both is two reviewed changes, provision then configure); connections that fail or hang,
firewall paths, tunnels → `devops-mutant-powers:network-operations`; secret stores, rotation, leaks →
`devops-mutant-powers:secrets-management`; who may log in where → `devops-mutant-powers:access-management`.

## Core Rules

1. **Desired state, not scripts.** Use the module or resource that knows the end state. Raw commands (Ansible
   `command`/`shell`, Puppet `exec`, Chef `execute`, Salt `cmd.run`) are a last resort with a guard so a re-run does
   nothing: `creates`/`removes`/`changed_when`, `onlyif`/`unless`/`refreshonly`, `not_if`/`only_if`, `onchanges`.
2. **Idempotency is proved, not claimed.** Run it again with no repo change: the second run reports zero changes —
   Ansible recap `changed=0` (the Molecule `idempotence` step checks this), `puppet agent -t` exit code `0` not `2`,
   a second Salt `state.apply` with no changes. Anything that changes twice is a bug.
3. **Preview first, and know its blind spots.** `ansible-playbook --check --diff`, `puppet agent -t
   --noop`, `chef-client --why-run`, Salt `state.apply … test=True`. A clean preview is evidence, not proof: Ansible
   skips `command`/`shell` without `creates`/`removes`; Puppet noop sends no refresh events (yet still runs `exec`
   `onlyif`/`unless`); Chef why-run never reaches the providers; none shows whether the service works afterwards.
4. **Limit the blast radius.** Print the target set first (`--list-hosts`, the matched minion list), then one canary
   host, then batches with a failure threshold (Ansible `serial` + `max_fail_percentage`, Salt `-b`, a Puppet test
   environment for a few nodes), then the fleet. Never make the first real run against `all` or `'*'`.
5. **The repo is the source of truth.** A hand edit on a host is drift: the next run reverts it, or, if nothing
   manages that setting, it survives unseen. The durable fix is a change in the repo, reviewed and rolled out.
   Deleting code does not undo what it created — declare the absent state (`ensure => absent`, `state: absent`).
6. **Secrets never in plain vars, diffs, logs or chat.** Ansible Vault (data at rest only) plus `no_log: true` and
   `diff: false` where the value flows; Puppet hiera-eyaml and `show_diff` off for secret files; Chef `sensitive
   true`; Salt pillar, never on the command line (every minion receives it). Compare values by hash or length.
7. **Every command names its target:** inventory (`-i`) and `--limit`, the Puppet node and `--environment`, the Salt
   target expression. A command without a target is not ready to run.
8. **Production runs need the owner's explicit approval** — after the dry run and the canary, and again before
   each widening step. Approval-gated: any run without check/noop/why-run/`test=True`, `puppet agent --disable`/
   `--enable`, an r10k or Code Manager deploy to production, `ansible-vault rekey`, `--force-handlers`, `check_mode:
   false` on a task. When asked how to check, print the commands for the human; do not run them. This holds when the person
   asking will run it themselves: name the approval or the change window the production run needs.
9. **Gate before merge:** syntax and lint (`--syntax-check`, `ansible-lint`, `pdk validate`, Cookstyle) plus a
   converge test on a throwaway virtual machine (VM) or container (Molecule, `pdk test unit`, Test Kitchen).
10. **Rollback is another forward run.** No CM tool has an undo. Write the rollback before the change (the previous
    commit plus any explicit absent states), and send it through the same canary path.

## Workflow

| Step | Do | Evidence |
|---|---|---|
| 1. Scope | hosts, resources, what restarts (handlers, `notify`/`subscribe`, `watch`), rollback | written list + target listing |
| 2. Static | syntax check, lint, unit/converge tests on a throwaway host | clean output in continuous integration (CI) |
| 3. Preview | dry run with diff on **one** host; then fleet-wide for drift | only expected changes; else stop |
| 4. Canary | real run on one host (approval) | run green **and** the service answers through its real path |
| 5. Batches | `serial`/`-b`/environment promotion, failure threshold (approval) | health check per batch |
| 6. Converged | run again | zero changes |
| 7. Durable | change merged; every hand edit reverted or codified | repo diff; drift preview clean |

## Error → layer (detail and fixes: the tool's reference file)

| Message | Layer | First check |
|---|---|---|
| `UNREACHABLE!` … `Failed to connect to the host via ssh:` | connection | name/route/port, `ansible_user`, key or agent, changed host key |
| `Missing sudo password`, `Incorrect sudo password`, `Timeout (…s) waiting for privilege escalation prompt` | privilege escalation | `-K`, sudoers, `become_method` |
| `couldn't resolve module/action '<name>'` | parse | collection not installed, typo, no fully qualified collection name |
| `'<name>' is undefined` | templating | precedence, scope, `default()`/`mandatory` |
| `Duplicate declaration: … is already declared at …; cannot redeclare` | Puppet compile | one owner for the resource |
| `Could not find class <name> for <node>` | Puppet compile | module missing from that environment, autoload path |
| `Found 1 dependency cycle:` | Puppet apply | remove one relationship edge |

## LLM Mistakes Checklist

- Proposing `ansible-playbook site.yml`, `puppet agent -t` on every node or `salt '*' state.apply` as the first run —
  no preview, no canary, no `--limit`.
- Reading a green `--check` recap as proof that `command`/`shell` tasks are fine — they were skipped.
- `command`/`shell` without `changed_when` or `creates`: "changed" on every run, handlers fire every run.
- `ignore_errors: true` to turn a red run green — and it does not catch undefined-variable or connection errors.
- Fixing one host by SSH-editing a file, `sysctl -w` or a hand firewall rule instead of the repo.
- A secret in plain `group_vars`, in `-e` on the command line, in Salt `pillar=` on the command line, or `no_log` missing on
  a loop over credentials.
- Assuming a failed Puppet compile stops the node: daemon runs default to `usecacheonfailure = true` and apply the
  last cached catalog (report `cached_catalog_status: on_failure`), so new code never lands (`-t` disables this).
- "Fixing" a Puppet `Duplicate declaration` by renaming one copy: the namevar (a file's `path`) is still duplicated
  and still fails. Give the resource one owner.
- Treating a failed later task as harmless: notified handlers do not run on that host, so the config changed but the
  service was not restarted.

## Output Contract

1. **Diagnosis tied to evidence** — the exact message, task or resource, host, and layer (connection, privilege,
   parse/compile, apply, handler/refresh); anything not seen marked unverified, with a confidence.
2. **Read-only commands with an explicit target** (inventory and `--limit`, Puppet node and environment, Salt
   target) — previews, `--list-hosts`, `puppet lookup --explain` — printed for the human when asked how to check.
3. **The fix in the repo** — which role, module, cookbook, state or data file; guards on raw commands; secrets via
   Vault, eyaml or pillar; every real run held for explicit approval — ask the owner for the go-ahead (or a change
   window) before the first real run — staging and canary first.
4. **Proof through the real path** — on the canary host the service actually behaves correctly (the real request,
   login or job, not only a green recap; the tasks that matter ran, not skipped), and a second run reports zero
   changes.
5. **Durability and follow-ups** — merged; every hand edit found on a host named as drift and reconciled through the
   repo (adopted or removed), none left; no disabled agent or skipped batch; owner and next action for anything open.

## References — load only the 1–2 files that match the task

- `references/ansible.md` — targeting, `serial`, check/diff limits, `changed_when`, variable precedence, handlers,
  `become`, collections, Vault/`no_log`, ansible-lint, Molecule, errors
- `references/puppet.md` — compile vs apply, noop and exit codes, relationships and refresh, autoloading, `exec`,
  Hiera and `puppet lookup`, environments and r10k, reports, PDK, errors
- `references/chef.md` — run-lists, Policyfiles, attribute precedence, guards, notifications, why-run, Test Kitchen
- `references/salt.md` — `state.apply`, `test=True`, targeting and batches, pillar vs grains, requisites
- Proof that the change works → `devops-mutant-powers:verification-before-completion`

## Verified References (full claim text: the reference file that uses each link)

- Ansible: <https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_checkmode.html> (preview
  limits, `diff: false`) · <https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/command_module.html>
  (skipped in check mode) · <https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_error_handling.html>
  (`max_fail_percentage`, handlers after a failure, `ignore_errors` limits) ·
  <https://docs.ansible.com/projects/ansible/latest/vault_guide/vault.html> (data at rest only)
- Puppet Core 9.1.0: <https://help.puppet.com/core/current/Content/PuppetCore/Markdown/agent.htm> (`-t`, `--noop`,
  exit codes) · <https://help.puppet.com/core/current/Content/PuppetCore/Markdown/configuration.htm>
  (`usecacheonfailure`) · <https://help.puppet.com/core/current/Content/PuppetCore/lang_resources.htm> (removed code
  is ignored, not removed)
- Chef Infra Client 19: <https://docs.chef.io/client/19/reference/ctl_chef_client/> (why-run) · Salt:
  <https://docs.saltproject.io/en/latest/topics/pillar/index.html> (command-line pillar reaches all minions)
- Error strings: <https://raw.githubusercontent.com/ansible/ansible/devel/lib/ansible/plugins/connection/ssh.py> ·
  <https://raw.githubusercontent.com/puppetlabs/puppet/main/locales/puppet.pot>
