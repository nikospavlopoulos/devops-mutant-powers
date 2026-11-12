# Salt — States, Test Mode, Targeting, Pillar

Load this when you write, review or run Salt states. It covers how states are applied, the `test=True` preview,
targeting and batches, where secrets belong (pillar, not grains or the command line), and requisites that keep
`cmd.run` from running on every apply. Facts are from the Salt project's current ("latest") documentation. Every
`state.apply` without `test=True` is approval-gated; when asked how to check, print the commands for the human.

## Applying states

- State files end in `.sls` and the docs call them SLS files. The top file (`top.sls`) maps minions to them.
  `state.apply` with no state names applies everything the top file assigns (the highstate);
  `state.apply nginx,users` applies only those state files.
- `state.show_highstate` displays the highstate data from the master without running it.

```bash
salt 'web01.example.com' state.apply nginx test=True        # preview on one minion
salt 'web01.example.com' state.apply nginx                  # (approval) canary
salt -C 'E@web\d+\.example\.com' -b 2 state.apply nginx   # (approval) batches of 2, targeted by minion ID
```

## Test mode

`test=True` runs states in dry-run mode: states that would change are shown in yellow with result `None`. Setting
`test: True` in the minion configuration makes test mode the default; `test=False` then applies. The `prereq`
requisite uses the same test mode to decide whether to act. The idempotency proof is a second real run with no
changes reported.

## Targeting and batches

- The default target is a glob on the minion ID. `-C` builds compound targets: `G@` grains glob, `P@` grains regular
  expression, `I@` pillar glob, `J@` pillar regular expression, `E@` minion-ID regular expression, `L@` list,
  `S@` subnet or IP, `N@` nodegroup.
- `-b 10` or `--batch-size 25%` runs on that many minions at a time as a rolling window (when one returns, the next
  starts); `--batch-wait <seconds>` pauses after each return.
- Grains can be set by anyone with access to the minion's configuration files, so they are less trustworthy than the
  minion ID. Target sensitive operations and data by minion ID; the only safe grain is `grains['id']`.

## Pillar — where secrets go

- Pillar data for a minion is accessible only to the minions it is targeted at, which makes it the place for secrets.
  Renderers can decrypt pillar data (for example the `gpg` renderer).
- Pillar passed on the command line (`pillar='{...}'`) is received by **all** minions, not only the targeted ones —
  never put a secret there.
- After changing pillar, `salt '<target>' saltutil.refresh_pillar` (approval on production) so in-memory lookups see
  the new data.

## Requisites and `cmd.run`

- `require` (run only after the required states succeed), `watch` (extra behaviour when watched states change),
  `onchanges` (apply only if the required states changed something), `prereq` (act before a change that test mode
  predicts), `onfail` (react only to a failure).
- `cmd.run` states run every time the SLS file is applied. Gate them with `creates` (run only while the files are
  missing), `unless` (skip when a check command succeeds), `onlyif` (run only when every check succeeds), or tie them
  to a change with `onchanges` — the documented replacement for `cmd.wait`.

```yaml
app-migrate:
  cmd.run:
    - name: /usr/local/bin/app migrate
    - onchanges:
      - pkg: app
```

## Verified References

- <https://docs.saltproject.io/en/latest/ref/states/highstate.html> — the top file maps minions to state files
- <https://docs.saltproject.io/en/latest/ref/modules/all/salt.modules.state.html> — `state.apply` with no SLS applies all configured states; with names applies those; `test=True` dry run; `state.show_highstate`
- <https://docs.saltproject.io/en/latest/ref/states/testing.html> — `test=True`, yellow / `None` results, `test` in the minion config, `test=False`
- <https://docs.saltproject.io/en/latest/topics/targeting/compound.html> — default glob, compound matcher letters
- <https://docs.saltproject.io/en/latest/topics/targeting/batch.html> — `-b` / `--batch-size` number or percentage, rolling window, `--batch-wait`
- <https://docs.saltproject.io/en/latest/faq.html> — grains can be set locally and are less secure; target sensitive operations by minion ID
- <https://docs.saltproject.io/en/latest/topics/pillar/index.html> — pillar only reaches targeted minions; CLI pillar reaches all minions; `saltutil.refresh_pillar`; decrypting renderers
- <https://docs.saltproject.io/en/latest/ref/states/requisites.html> — `require`, `watch`, `onchanges`, `prereq`, `onfail`, `creates`, `unless`, `onlyif`
- <https://docs.saltproject.io/en/latest/ref/states/all/salt.states.cmd.html> — `cmd.run` runs on every apply; `onchanges` preferred over `cmd.wait`
