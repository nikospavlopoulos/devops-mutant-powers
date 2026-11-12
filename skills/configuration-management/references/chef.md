# Chef — Run-Lists, Guards, Why-Run, Test Kitchen

Load this when you write, review or run Chef cookbooks. It covers what runs (run-lists and Policyfiles), which
attribute value wins, how to keep `execute` resources idempotent, how notifications are timed, what why-run mode can
and cannot show, secrets, and the test gate. Facts are from the Chef Infra Client 19 and Chef Workstation 26.1
documentation. Every client run without `--why-run` on a shared or production node is approval-gated; when asked
how to check, print the commands for the human.

## What runs

- A run-list is an ordered list of roles and recipes, run in that order; a recipe listed twice runs once.
- A Policyfile pins an immutable set of cookbooks, dependencies and attributes. `chef install` resolves it and writes
  `Policyfile.lock.json`; `chef push <policy_group> Policyfile.rb` (approval for production groups) uploads the lock
  and its cookbooks and applies it to that policy group; `chef diff production...staging` compares two groups'
  locks; `chef update` re-resolves and can pull newer cookbooks.
- To promote, push the tested lock unchanged to the next group instead of re-resolving in between. The docs describe
  promotion through stages but no fixed procedure; this follows from what `chef push` and `chef update` do.
- `chef-client -o <recipe>` / `--override-runlist` (approval) replaces the run-list for one run and does not save
  node data at the end — useful on one canary node, not a rollout method.

## Attribute precedence

Last one wins, lowest first: `default` → `force_default` → `normal` → `override` → `force_override` → `automatic`
(the facts Ohai collects at the start of the run). A value that "will not change" is usually set again at a higher
level.

## Idempotency, guards and notifications

- Prefer a resource that knows the end state (`package`, `template`, `service`) over `execute`. Guard any command:
  `not_if` skips the resource when the condition is true, `only_if` runs it only when the condition is true.
- `notifies :action, 'type[name]', :timer` and `subscribes` with timers `:before`, `:delayed` (the default — queued
  and run at the end of the client run) and `:immediately`. A resource with `action :nothing` acts only when
  notified.

```ruby
execute 'app-migrate' do
  command '/usr/local/bin/app migrate'
  action :nothing
  subscribes :run, 'package[app]', :immediately
end
```

## Why-run (`chef-client --why-run` / `-W`)

Why-run does everything except modify the system: it shows what the client would have configured. It does not map
resources to providers or configure anything, so anything that depends on an earlier change in the same run is an
assumption, not an observation. It still runs `not_if`/`only_if` guards, assuming they are safe — keep them
read-only. The Chef docs say it is not a replacement for running the cookbook in a test environment that mirrors
production.

## Secrets

- `sensitive true` on a resource keeps its data out of the client's logs; set it on every resource that handles a
  secret.
- The `secret(name: '<name>', service: <service>, config: {...})` helper reads from `:hashi_vault`,
  `:aws_secrets_manager`, `:azure_key_vault` or `:akeyless_vault` at run time instead of storing the value in
  attributes.

## Testing gate

- `cookstyle .` in the cookbook directory — linting built on RuboCop.
- Test Kitchen runs cookbooks on throwaway instances across platforms and suites defined in `kitchen.yml`:
  `kitchen create`, `kitchen converge`, `kitchen verify`, `kitchen destroy`; `kitchen test` does the whole cycle
  (cleaning up a previous instance if needed); its default `--destroy=passing` keeps a failed instance for
  inspection. Converge twice and check that the second run updates nothing.

## Verified References

- <https://docs.chef.io/client/19/policy/run_lists/> — run-list order; a repeated recipe runs once
- <https://docs.chef.io/client/19/policy/policyfile/> — immutable cookbook sets, `Policyfile.lock.json`, `chef install`, `chef push POLICY_GROUP POLICY_FILE`, `chef diff`, `chef update` re-resolves, promotion through stages
- <https://docs.chef.io/client/19/reference/ctl_chef_client/> — `--why-run` does everything except modify the system, no provider mapping, guards assumed safe to run, not a replacement for a test environment; `-o` does not persist node data (Chef Infra Client 19)
- <https://docs.chef.io/client/19/cookbooks/attributes/attribute_precedence/> — application order, last one wins
- <https://docs.chef.io/client/19/resources/common_functionality/> — `not_if`/`only_if`, `notifies`/`subscribes` timers, `:delayed` default, `action :nothing`, `sensitive`
- <https://docs.chef.io/client/19/infra_language/secrets/> — `secret()` helper syntax and supported services
- <https://docs.chef.io/workstation/cookstyle/> — Cookstyle is RuboCop-based; `cookstyle .`
- <https://docs.chef.io/workstation/26.1/tools/kitchen/> — Test Kitchen tests cookbooks across platforms and suites from `kitchen.yml` · <https://docs.chef.io/workstation/26.1/tools/kitchen/ctl_kitchen/> — `create`, `converge`, `verify`, `destroy`, `test` (cleans up a previous instance if necessary; `--destroy` default `passing`)
