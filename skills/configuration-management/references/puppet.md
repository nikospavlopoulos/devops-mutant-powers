# Puppet — Compile vs Apply, Ordering, Hiera, Environments, Errors

Load this when you write, review or run Puppet code, Hiera data or a control repository, or when a Puppet run
fails. It explains where each failure happens (catalog compilation on the server or applying on the node), how
agent runs, `--noop` and exit codes behave, how resource relationships and refresh events work, how Hiera finds a
value, how environments and r10k deploy code, what a run report says about drift, the Puppet Development Kit (PDK)
test gate, and the common error messages.
Behaviour is from the Puppet Core 9.1.0 documentation; check the version on your nodes. Every run without `--noop`,
`--disable`/`--enable` and every code deploy to production is approval-gated; when asked how to check, print the
commands for the human.

## 1. Compile vs apply — where did it fail?

- The agent sends its node name (usually the certname), certificate, facts and requested environment. The primary
  server compiles a catalog for that node; the agent downloads it and applies it. `puppet apply` does both on the
  node itself.
- **Compile errors** — syntax, a missing class, a duplicate declaration, a Hiera lookup — happen on the server
  before anything changes on the node. **Apply errors** — a provider failure, a dependency cycle, a failed
  dependency — happen on the node, resource by resource.
- With `usecacheonfailure = true` (the default), a failed compile makes the agent apply its **cached** catalog;
  the log says `Using cached catalog from environment '<env>'` and the report's `cached_catalog_status` is
  `on_failure`. The node keeps enforcing old code while new code never arrives. `puppet agent -t` sets
  `no-usecacheonfailure`, so a manual test run fails on the compile error instead of falling back.

## 2. Agent runs, noop and exit codes

```bash
# on web01.example.com (one node = the canary)
sudo puppet agent -t --noop --environment feature_tls     # preview against a test environment
sudo puppet agent -t --environment feature_tls            # (approval) real run
```

- `-t` / `--test` = `onetime`, `verbose`, `no-daemonize`, `no-usecacheonfailure`, `detailed-exitcodes`,
  `no-splay`, `show_diff`.
- `--detailed-exitcodes`: `0` no changes or failures · `1` run failed, or not attempted because another run is in
  progress · `2` changes, no failures · `4` failures · `6` changes and failures. The idempotency proof is a second
  run that exits `0`.
- `--noop` checks every resource and reports what would change, but it does not refresh resources and does not
  send refresh events — a service restart that a change would trigger is only logged. `exec` `onlyif`/`unless`
  commands still run in noop, because they decide whether the `exec` is in sync: they must be read-only.
- `puppet agent --disable "<reason>"` (approval) places a lock; runs then log `Skipping run of …; administratively
  disabled (Reason: '<reason>')` until `puppet agent --enable` (approval). Never leave a node disabled — it silently
  stops receiving fixes. A second concurrent run logs `Run of … already in progress; skipping (<lockfile> exists)`.
- Defaults to remember: `runinterval` 30m, `splay` false, `environment` production.

## 3. Resources, relationships and refresh

- Each resource is unique per type by **title and namevar**; a duplicate of either fails compilation. Fix a
  `Duplicate declaration` by giving the resource one owner (one class that every user includes), not by renaming
  one copy — two titles with the same namevar (for a `file`, its `path`) still collide.
- Ordering: `before` / `require`, or the arrow `->`. Refresh: `notify` / `subscribe`, or `~>`. Relationships may
  point at resources declared later in the code.
- Refreshable types: `service`, `exec` and `package`. A resource refreshes at most once per run. A refresh sent to a
  class or defined type reaches every resource inside it.
- A failed resource makes its dependents log `Skipping because of failed dependencies`; unrelated resources still
  apply.
- A dependency cycle compiles but cannot apply: `Found 1 dependency cycle:` with the loop printed, then `Failed to
  apply catalog: One or more resource dependency cycles detected in graph`. Remove one edge. With the `graph`
  setting on, `.dot` files are written to `graphdir` (default `$statedir/graphs`) to see the loop.
- Removing a resource from the code does **not** remove it from the node — Puppet just stops managing it. To remove a
  package, file or user, declare it with `ensure => absent`, run that, then delete the code.

## 4. Classes and autoloading

- Include-like declarations (`include`, `require`, `contain`) can repeat safely; a resource-like declaration
  (`class { 'ntp': servers => [...] }`) may appear only once per node. Do not mix both styles for one class.
  `contain` makes a class part of its parent, so the parent's ordering covers it.
- The autoloader maps `apache::mod` to `<modulepath>/apache/manifests/mod.pp` and a module's main class to
  `init.pp`. `Could not find class <name> for <node>` means: the module is missing from that node's environment
  (Puppetfile not deployed, wrong environment), the file path does not match the class name, or a typo.

## 5. `exec` without surprises

An `exec` must be safe to run again. Use an idempotent command, or a guard: `creates => '/path'`, `onlyif` / `unless`
(read-only test commands), or `refreshonly => true` so it runs only when it receives an event.

```puppet
exec { 'app-migrate':
  command     => '/usr/local/bin/app migrate',
  refreshonly => true,
  subscribe   => Package['app'],
}
```

## 6. Hiera — where does a value come from?

- Three layers, searched global → environment → module. The global layer is for temporary overrides only; most
  data and the hierarchy belong in the environment layer; the module layer sets defaults for a module's class
  parameters.
- Inside a layer, the hierarchy is searched in the written order and earlier levels win.
- Ask Hiera instead of guessing:

```bash
# on a Puppet Server node (it needs the Hiera data); uses the node's stored facts from PuppetDB when configured,
# otherwise pass them with --facts <file>
sudo puppet lookup ntp::servers --node web01.example.com --environment production --explain
sudo puppet lookup ntp::servers --node web01.example.com --environment production --explain-options
```

`--compile` performs a full catalog compilation first (for values that depend on code); `--merge` overrides the
merge behaviour.
- Secrets: hiera-eyaml keeps values encrypted on disk and Puppet decrypts them during compilation. A hierarchy level
  uses `lookup_key: eyaml_lookup_key` with `options` pointing at `pkcs7_private_key` / `pkcs7_public_key`. The
  backend ships with Puppet Server. `show_diff` (on under `-t`) sends partial file contents into logs and reports —
  set `show_diff => false` on `file` resources that hold secrets.

## 7. Environments and code deployment

- An environment is an isolated main manifest plus module set that a group of nodes uses. Test a change on a few
  nodes assigned to a feature environment before merging to production.
- r10k maps each branch of the control repository to one environment. `r10k deploy environment <env> --modules` updates one
  environment and its modules (approval for production); deploying every environment at once is a brute-force
  operation, not a routine one.
- Code management purges anything in the environment's module directory that is not in the Puppetfile. With r10k,
  never `puppet module install` into a managed environment — the next deploy deletes it.
- Custom resource types can leak between environments on the primary server; environment isolation fixes this by
  running `puppet generate types --environment <env>` for each environment after every deploy (part of the approved
  deploy).

## 8. Reports and drift

- The agent writes a run summary (`lastrunfile`, `last_run_summary.yaml`) and the last report (`lastrunreport`,
  `last_run_report.yaml`).
- Report fields that matter: `status` (`failed` / `changed` / `unchanged`), `noop` and `noop_pending` (changes a noop
  run held back), `corrective_change` (the change or noop event was caused by an unexpected change to the system
  between runs — drift from outside Puppet), `cached_catalog_status` (`not_used` / `explicitly_requested` /
  `on_failure`), `transaction_completed`.
- A `corrective_change` that recurs on the same resource suggests that something outside Puppet (a person, a
  script, another tool) keeps changing it — an inference from the field's meaning, not a documented diagnosis. Find
  that actor and move the change into the code.

## 9. Testing gate

- `puppet parser validate <files>` checks syntax without compiling a catalog.
- `pdk validate` checks metadata, Puppet syntax and style, and Ruby style.
- `pdk test unit` runs the RSpec unit tests (rspec-puppet). They check that the code compiles and that the catalog
  holds the declared resources — they cannot test changes to the system or services. The tests PDK generates only
  prove the manifest compiles on the supported operating systems; write tests for the behaviour you expect.
- Then a noop and a real run on one node in a feature environment.

## 10. Error messages

| Message | Stage | Check, in order |
|---|---|---|
| `Duplicate declaration: <Type[title]> is already declared at <file:line>; cannot redeclare` | compile | two declarations of one title or namevar; mixed include-like and resource-like class declaration (§3, §4) |
| `Could not find class <name> for <node>` | compile | module present in that environment, Puppetfile deployed, autoload path (§4, §7) |
| `Could not retrieve catalog from remote server: …` then `Using cached catalog …` | compile, cached apply | read the server-side error; the node still runs old code (§1) |
| `Found 1 dependency cycle:` … `One or more resource dependency cycles detected in graph` | apply | the printed loop; remove one edge (§3) |
| `Skipping because of failed dependencies` | apply | the first failed resource above it |
| exit code `2` on every run | idempotency | the resource that changes each time; an `exec` without a guard (§5) |

## Verified References

- <https://help.puppet.com/core/current/Content/PuppetCore/subsystem_catalog_compilation.htm> — what the agent sends, server-side compilation, `puppet apply` does both
- <https://help.puppet.com/core/current/Content/PuppetCore/Markdown/agent.htm> — `-t` settings, `--noop`, detailed exit codes, `--disable`/`--enable` (Puppet Core 9.1.0)
- <https://help.puppet.com/core/current/Content/PuppetCore/Markdown/configuration.htm> — `usecacheonfailure` true, `runinterval` 30m, `show_diff` exposes file contents, `graph`/`graphdir`, `lastrunfile`, `lastrunreport`, `splay`, `environment`
- <https://help.puppet.com/core/current/Content/PuppetCore/lang_relationships.htm> — metaparameters and arrows, refreshable types, once per run, class refresh, failed dependencies, cycles, forward references, noop does not refresh or send events
- <https://help.puppet.com/core/current/Content/PuppetCore/lang_resources.htm> — uniqueness by title and name, removed resources are ignored, `ensure => absent`
- <https://help.puppet.com/core/current/Content/PuppetCore/lang_class_declare.htm> — include-like vs resource-like, do not mix, `contain`
- <https://help.puppet.com/core/current/Content/PuppetCore/lang_namespaces.htm> — autoloader paths and `init.pp`
- <https://help.puppet.com/core/current/Content/PuppetCore/Markdown/exec.htm> — `exec` idempotency options, `onlyif`/`unless` run during noop, `refreshonly`
- <https://help.puppet.com/core/current/Content/PuppetCore/hiera_config_layers.htm> — three layers, search order, global layer for temporary overrides, environment layer for most data, module layer for class parameter defaults
- <https://help.puppet.com/core/current/Content/PuppetCore/Markdown/file.htm> — `file` `show_diff` for files holding secrets; the global setting overrides it
- <https://help.puppet.com/core/current/Content/PuppetCore/hiera_hierarchy.htm> — written order, higher-priority sources override
- <https://help.puppet.com/core/current/Content/PuppetCore/Markdown/lookup.htm> — `puppet lookup` with `--node`, `--environment`, `--explain`, `--explain-options`, `--compile`, `--merge`; run on a Puppet Server node with sudo; PuppetDB facts or `--facts`
- <https://help.puppet.com/core/current/Content/PuppetCore/hiera_eyaml.htm> — `eyaml_lookup_key`, key options, encrypted on disk and read during compilation, bundled in Puppet Server
- <https://help.puppet.com/core/current/Content/PuppetCore/environments_about.htm> — environment = own main manifest and modules; test nodes before production
- <https://help.puppet.com/core/current/Content/PuppetCore/puppetfile_manage_modules.htm> — purge of modules not in the Puppetfile; no `puppet module` with r10k
- <https://help.puppet.com/core/current/Content/PuppetCore/environment_isolation.htm> — resource types leak between environments without isolation · <https://help.puppet.com/core/current/Content/PuppetCore/env_isolation_r10k.htm> — generate types per environment after each r10k deploy · <https://help.puppet.com/core/current/Content/PuppetCore/Markdown/generate.htm> — `puppet generate types --environment <env>`
- <https://raw.githubusercontent.com/puppetlabs/r10k/main/doc/dynamic-environments/introduction.mkd> — one branch = one environment · <https://raw.githubusercontent.com/puppetlabs/r10k/main/doc/dynamic-environments/usage.mkd> — `r10k deploy environment <env> --modules`; deploying all environments is brute force
- <https://help.puppet.com/core/current/Content/PuppetCore/format_report.htm> — report fields `status`, `noop_pending`, `corrective_change`, `cached_catalog_status`, `transaction_completed`
- <https://help.puppet.com/core/current/Content/PuppetCore/Markdown/parser.htm> — `puppet parser validate` checks syntax without compiling
- <https://help.puppet.com/pdk/current/topics/validating_modules.htm> — PDK 4.0.1 validations (metadata, syntax, style, Rubocop) · <https://help.puppet.com/pdk/current/topics/validate_module.htm> — the `pdk validate` command
- <https://help.puppet.com/pdk/current/topics/unit_test_module.htm> — `pdk test unit`; generated tests only prove compilation · <https://help.puppet.com/pdk/current/topics/unit_testing_modules.htm> — unit tests check compilation and declared resources, not changes to the system; rspec-puppet
- <https://raw.githubusercontent.com/puppetlabs/puppet/main/locales/puppet.pot> — exact strings: `Duplicate declaration: … cannot redeclare`, `Could not find class %{name} for %{node}`, `Found %{num} dependency cycle:`, `Failed to apply catalog:`, `One or more resource dependency cycles detected in graph`, `Could not retrieve catalog from remote server`, `Using cached catalog from environment`, `administratively disabled`, `already in progress; skipping`
