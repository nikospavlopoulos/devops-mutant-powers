# Ansible — Targeting, Previews, Idempotency, Secrets, Errors

Load this when you write, review or run Ansible playbooks and roles, or when a run fails. It covers how to pick and
widen the target set, what check and diff mode can and cannot show, how to keep raw commands idempotent, the
variable precedence traps, handlers, privilege escalation (`become`), collections, Vault and `no_log`, the test
gate (ansible-lint, Molecule) and the common error messages by layer. Facts come from the current Ansible docs
("latest") and the ansible-core `devel` source; every run without `--check` is approval-gated, and when asked how
to check, print the commands for the human.

## 1. Targeting and blast radius

- Patterns: `webservers:!atlanta` (exclude), `webservers:&staging` (intersection), `,` or `:` between names (the
  comma is preferred with ranges and IPv6). Quote negations in single quotes: `--limit 'all:!web03.example.com'`.
- `--limit` narrows the play's hosts; `--limit @hosts.txt` reads them from a file. With `RETRY_FILES_ENABLED = True`
  a `.retry` file is written after a run and `--limit @site.retry` re-targets the failed hosts.
- `--list-hosts` prints the matched hosts and runs nothing; `--list-tasks` lists the tasks. A pattern that matches
  nothing only warns: `[WARNING]: Could not match supplied host pattern, ignoring: …` — read the warning.
- Every command carries the inventory and the limit:

```bash
ansible-playbook -i inventories/prod/hosts.yml site.yml --limit web01.example.com --list-hosts
ansible-playbook -i inventories/prod/hosts.yml site.yml --limit web01.example.com --check --diff
ansible-playbook -i inventories/prod/hosts.yml site.yml --limit web01.example.com      # (approval)
```

## 2. Rolling out in batches

- `serial` takes a number, a percentage or a list; with a list such as `[1, 5, 10]` every later batch uses the last
  value until hosts run out. The whole play runs on one batch before the next starts.
- `max_fail_percentage` applies per batch and must be **exceeded**, not reached: with `serial: 10` and
  `max_fail_percentage: 30`, a fourth failure in a batch aborts the rest of the play.
- `any_errors_fatal: true` finishes the failing task on the current batch, then stops the play on all hosts.
- Default concurrency is 5 forks (`-f`); `throttle` only lowers concurrency for a task or block and must be below
  `forks` or `serial`. Under `serial`, `run_once` runs once **per batch**, not once per play.

```yaml
- hosts: webservers
  serial: [1, 5, 10]           # canary, small batch, then 10 at a time
  max_fail_percentage: 0       # any failure in a batch stops the rollout
  tasks: [...]
```

## 3. Check and diff mode — what the preview cannot see

- `--check` predicts *some* changes. Modules without check-mode support report nothing and do nothing.
- `ansible.builtin.command` and `shell`: check mode works only when `creates` or `removes` is set; otherwise the task
  is **skipped**. Their diff support is none.
- Tasks whose conditions use registered results from earlier tasks produce no output in check mode.
- `check_mode: false` on a task makes it really run and change the host even under `--check` — approval-gated;
  `check_mode: true` always simulates; `ansible_check_mode` lets a task skip itself during a preview.
- `--diff` can print secrets — set `diff: false` on tasks that template secret files. Diff output is large; use it
  with `--limit` on one host.
- Check mode across the fleet doubles as a drift test: a reported change means a host differs from the repo (or a
  task is not idempotent).

## 4. Raw commands and idempotency

- Prefer a module; `command` is safer than `shell` (no shell metacharacter parsing). For a reboot use
  `ansible.builtin.reboot`, not a command.
- Guards: `creates: /path` (skip if it exists), `removes: /path` (run only if it exists), or register the result
  and set `changed_when` / `failed_when`. A **list** of conditions is joined with `and`; for "any of", write one
  string with `or`. A read-only command gets `changed_when: false`.

```yaml
- name: Initialise the data directory once
  ansible.builtin.command:
    cmd: /usr/local/bin/app-init --data /srv/app
    creates: /srv/app/.initialised
```

- ansible-lint flags the gaps: `no-changed-when` (command/shell, handlers included, without `changed_when` or
  `creates`/`removes`), `risky-shell-pipe`, `command-instead-of-module`.

## 5. Variable precedence pitfalls

The documented order has 22 levels; condensed, lowest first: command-line values (not variables), **role defaults**, inventory
group vars, `group_vars/all`, `group_vars/*`, host vars, facts, play vars/`vars_prompt`/`vars_files`, **role vars**,
block vars, task vars, `include_vars`, registered vars and `set_fact`, role and include params, **extra vars** (`-e`,
always win).

- A value "set in `group_vars`" that never applies is usually shadowed by role `vars/` (level 15), `set_fact`, or a
  `-e` in a wrapper script. Put overridable values in role `defaults/`.
- The docs' rule: define each variable in one place.
- By default an undefined variable fails the task. `{{ x | default(5) }}` supplies a fallback; `{{ x | mandatory }}`
  makes the requirement explicit.

## 6. Handlers

- A handler runs only if the notifying task reported **changed**; notified many times, it runs once.
- Handlers run after `pre_tasks`, after `roles`/`tasks`, and after `post_tasks` — in the order they are defined in
  `handlers`, not the order of `notify`. `meta: flush_handlers` runs the notified ones now; `listen` lets several
  handlers share one topic.
- If a later task fails on a host, that host's notified handlers do **not** run: the file changed, the service was
  never restarted. The next run then finds the file already correct, reports `ok` and notifies nothing, so the
  restart stays missing (an inference from handlers running only on `changed`). `--force-handlers` /
  `force_handlers: true` runs them anyway (approval on production); an unreachable host can still skip them.
- Avoid variables in handler names: if the variable is undefined, the whole play fails.

## 7. Privilege escalation (`become`)

- `become_user` does not turn on `become`; set `become: true` too, in the same place (ansible-lint
  `partial-become`). `-K` / `--ask-become-pass` prompts for the password (used for all hosts); `-b` does not prompt.
- A play that seems to hang is usually waiting at the escalation prompt: stop it and rerun with `-K`.
- Becoming an unprivileged user can fail with `Failed to set permissions on the temporary files Ansible needs to
  create when becoming an unprivileged user` — install the package that provides `setfacl`, or use pipelining (not
  for `copy`/`fetch`/`template`), or avoid becoming an unprivileged user. `world_readable_temp` is a security risk.

## 8. Collections

- Use fully qualified collection names (FQCN: `ansible.builtin.copy`, `ansible.posix.firewalld`). The play-level
  `collections:` keyword is only a search path for short names, and roles do not inherit it.
- Install from a pinned `requirements.yml` (`collections:` list with `name` and `version`):
  `ansible-galaxy collection install -r requirements.yml`. Pre-releases need an explicit `==` version.

## 9. Secrets — Vault and `no_log`

- Vault encrypts whole files (`ansible-vault create|edit|view|encrypt|decrypt|rekey`) or single values
  (`ansible-vault encrypt_string --vault-id prod@prompt --stdin-name db_password`, then type the value and press
  Ctrl-D). A secret typed on the command line stays in shell history.
- Encrypted single values cannot be rekeyed; vaulted files can.
- Keep names greppable: `group_vars/<group>/vars` holds `db_password: "{{ vault_db_password }}"`, and the encrypted
  `group_vars/<group>/vault` holds `vault_db_password`.
- Vault protects data **at rest** only. After decryption, hide it: `no_log: true` on tasks that handle it (task
  level preferred over whole plays), `diff: false` on templated secret files. `no_log` does not hide data when
  debugging Ansible itself (`ANSIBLE_DEBUG`). Secrets in loops are easy to leak — the opt-in ansible-lint rule
  `no-log-password` catches them.

## 10. Testing gate

- `ansible-playbook -i <inventory> site.yml --syntax-check` — parses without running.
- `ansible-lint --profile=<name>`: profiles stack `min` → `basic` → `moderate` → `safety` → `shared` →
  `production`. `safety` adds `avoid-implicit`, `latest`, `package-latest`, `risky-file-permissions`,
  `risky-octal`, `risky-shell-pipe`; `no-changed-when` is in `shared`. ansible-lint runs `--syntax-check` itself
  and that rule cannot be skipped.
- Molecule's default `molecule test` sequence: dependency, cleanup, destroy, syntax, create, prepare, converge,
  **idempotence**, side_effect, verify, cleanup, destroy. `idempotence` runs converge again and fails if Ansible
  reports any change. Run it on a throwaway container or virtual machine, never on a shared host.
- In-play gates: `ansible.builtin.assert`, `uri` (the service answers) and `wait_for` (port open) after the change,
  so a failing host stops its batch.

## 11. Error messages by layer

| Message | Layer | Check, in order |
|---|---|---|
| `fatal: [<host>]: UNREACHABLE! =>` with `Failed to connect to the host via ssh:` | connection | name resolves, route and port 22 open, `ansible_user` (default: your local user name), key loaded in `ssh-agent` (no passphrase prompt otherwise), host key changed in `known_hosts`; network path → `devops-mutant-powers:network-operations` |
| `Missing sudo password` | become | rerun with `-K`, or give the account a sudoers rule |
| `Incorrect sudo password` | become | wrong password for this host's account |
| `Timeout (…s) waiting for privilege escalation prompt:` | become | `become_method` and the sudoers entry on that host |
| `Failed to set permissions on the temporary files Ansible needs to create when becoming an unprivileged user` | become | §7 |
| `couldn't resolve module/action '<name>'. This often indicates a misspelling, missing collection, or incorrect module path.` | parse | spelling, FQCN, collection installed in the environment that runs the play (§8) |
| `'<name>' is undefined` / `… has no attribute '<name>'` | templating | precedence (§5), the variable's scope (host vs play), a fact not gathered, `default()` |
| task "changed" on every run | idempotency | §4 guards; then the Molecule `idempotence` step |

Host key checking is on by default and guards against spoofing and man-in-the-middle attacks; turning it off
(`host_key_checking = False`) is a security trade-off, not a fix.

## 12. Firewall rules through Ansible

`ansible.posix.firewalld` defaults to `permanent: false`, which changes only the running firewalld rules, not the
permanent configuration. For a rule that is live now and kept, set `permanent: true` and `immediate: true`.

## Verified References

- <https://docs.ansible.com/projects/ansible/latest/inventory_guide/intro_patterns.html> — exclusion/intersection patterns, single quotes for negation, `--limit @file`, retry files, unmatched-pattern warning
- <https://docs.ansible.com/projects/ansible/latest/cli/ansible-playbook.html> — `--check`, `--diff`, `--limit`, `--list-hosts`, `--list-tasks`, `--syntax-check`, `-K`, `-b`, `--force-handlers`, `-f` default 5
- <https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_strategies.html> — `serial` number/percentage/list (last value repeats), whole play per batch, 5 forks, `throttle`, `run_once` per batch
- <https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_error_handling.html> — `max_fail_percentage` per batch and must be exceeded, `any_errors_fatal`, handlers skipped after a failure and `force_handlers` (unreachable hosts still skip them), `ignore_errors` limits, `changed_when`/`failed_when` lists joined with `and`
- <https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_checkmode.html> — modules without check support do nothing, registered-result conditions give no output, `check_mode: true|false`, `ansible_check_mode`, `diff: false`, diff with one host
- <https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/command_module.html> — check mode only with `creates`/`removes`, otherwise skipped; diff none; command safer than shell; reboot module
- <https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_variables.html> — the 22-level precedence list, extra vars always win, define each variable in one place
- <https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_filters.html> — undefined variables fail by default; `default()`, `mandatory`
- <https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_handlers.html> — run on changed, once, after each section, definition order, `flush_handlers`, `listen`, variables in handler names
- <https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_privilege_escalation.html> — `become_user` does not imply `become`, `-K`, hang at the prompt, unprivileged-user temp-file error and workarounds
- <https://docs.ansible.com/projects/ansible/latest/collections_guide/collections_using_playbooks.html> — prefer FQCN; `collections:` is a search path, roles do not inherit it
- <https://docs.ansible.com/projects/ansible/latest/collections_guide/collections_installing.html> — `requirements.yml` format, `-r`, `==` for pre-releases
- <https://docs.ansible.com/projects/ansible/latest/vault_guide/vault.html> — Vault protects data at rest only
- <https://docs.ansible.com/projects/ansible/latest/vault_guide/vault_encrypting_content.html> — `encrypt_string` with `--vault-id`/`--stdin-name` and the stdin prompt, `@prompt` password source, shell history warning, encrypted variables cannot be rekeyed, file subcommands
- <https://docs.ansible.com/projects/ansible/latest/tips_tricks/ansible_tips_tricks.html> — vars/vault file pattern with `vault_` names, staging first, `serial` batches
- <https://docs.ansible.com/projects/ansible/latest/reference_appendices/faq.html> — `no_log` on tasks or plays (tasks preferred), does not hide `ANSIBLE_DEBUG` output
- <https://docs.ansible.com/projects/ansible/latest/reference_appendices/test_strategies.html> — `--check` reports whether a host would change; `assert`, `uri`, `wait_for` as in-play tests that gate a rolling update
- <https://docs.ansible.com/projects/ansible/latest/inventory_guide/connection_details.html> — host key checking on by default and its trade-off, `ssh-agent` for passphrase keys, default remote user
- <https://docs.ansible.com/projects/ansible/latest/collections/ansible/posix/firewalld_module.html> — `permanent` default false, `immediate`
- <https://docs.ansible.com/projects/lint/profiles/> — profile order, `safety` rules, `no-changed-when` in `shared`
- <https://docs.ansible.com/projects/lint/rules/no-changed-when/> — what the rule checks (handlers too) and its fixes
- <https://github.com/ansible/ansible-lint/blob/main/docs/usage.md> — `--profile=<name>`; <https://github.com/ansible/ansible-lint/blob/main/src/ansiblelint/rules/syntax_check.md> — runs `--syntax-check`, unskippable; <https://github.com/ansible/ansible-lint/blob/main/src/ansiblelint/rules/no_log_password.md> — opt-in rule for secrets in loops; <https://github.com/ansible/ansible-lint/blob/main/src/ansiblelint/rules/partial_become.md> — `become` and `become_user` defined together
- <https://docs.ansible.com/projects/molecule/configuration/> — default `test_sequence`; <https://github.com/ansible/molecule/blob/main/docs/faq.md> — idempotence runs converge twice and reads Ansible's changed count
- Error strings (ansible-core `devel`): <https://raw.githubusercontent.com/ansible/ansible/devel/lib/ansible/plugins/callback/default.py> (`UNREACHABLE!`) · <https://raw.githubusercontent.com/ansible/ansible/devel/lib/ansible/plugins/connection/ssh.py> (`Failed to connect to the host via ssh:`, `Missing`/`Incorrect %s password`, escalation timeout) · <https://raw.githubusercontent.com/ansible/ansible/devel/lib/ansible/parsing/mod_args.py> (`couldn't resolve module/action`) · <https://raw.githubusercontent.com/pallets/jinja/main/src/jinja2/runtime.py> (`'<name>' is undefined`, `has no attribute`)
