# Tailscale Policy (grants, tags, tests)

Placeholders: users `dev-a@example.com` (team), `contractor-a@example.org` (external), `ops-a@example.com` (infra),
tags `tag:app-a-stg-gw`, `tag:app-a-prod-gw`. Editing the tailnet policy file is a live change for the whole tailnet
(Owner, Admin or Network admin role): draft it, get approval, then save.

## Identities and selectors

| Selector | Is | Watch out |
|---|---|---|
| `user@example.com` | a user identity; their devices carry it | removing the user removes their devices |
| `group:<name>` | users listed under `groups` | membership is the access — review it like a role |
| `tag:<name>` | a device identity with **no** user | tagging a device removes its user identity (and vice versa); the device survives user removal |
| `autogroup:member` | direct members of the tailnet | includes invited externals; shared-in users are `autogroup:shared` |
| `autogroup:self` | devices of the same user | user-owned devices only — never tagged ones |
| `autogroup:tagged` | every device with at least one tag | almost never the right `dst` |
| `autogroup:admin` / `owner` / `network-admin` … | members with that role | role ≠ need; still give explicit dst lists |
| `autogroup:internet` | public IPs via exit nodes | omit it and nobody routes internet traffic through exit nodes |

`tagOwners` decides who may apply a tag. Owning a tag = being able to give any device of yours that tag's access,
so `tagOwners` is itself an access grant. Use tags only for servers/services, never to annotate a person's laptop.

## Rules that decide every change

1. **Deny-by-default, allow-only, union.** A connection is allowed if any rule allows it. There is no deny; the
   only way to restrict is to remove or narrow the rule that allows it. A fresh tailnet starts with allow-all —
   replacing it is the first change.
2. **Visibility equals access, both ways.** A device's netmap (`tailscale status`) shows devices it can reach,
   devices that can reach it (even if it cannot reach back), and all devices of the same user. An "admins reach
   everything" rule therefore puts every admin device into every device's peer list — vendors included.
3. **The admin wildcard hides mistakes.** With `group:infra → *` every test from an admin device passes; a member
   rule with the wrong port or tag looks fine until the wildcard is removed. Give admins explicit `dst` lists too —
   then every new tag needs its admin grant and its tests in the same change that introduces it.
4. **Tags fan out.** A grant to `tag:x` reaches every device carrying `tag:x`. A generic tag shared by several
   gateways or environments turns one grant into many. One tag per role × environment × exposure.
5. **`autogroup:member` is not "our staff".** Once an external user is invited as a member, every grant with
   `src: autogroup:member` covers them. Keep member-wide grants to own-device access.
6. **`acls` and `grants` coexist** in one file (during a migration); `ssh` rules live in their own section in
   either case. Prefer grants for new rules — destination and ports are separate fields.

## Syntax: acls → grants

| ACLs | Grants |
|---|---|
| `"acls": [...]` | `"grants": [...]` |
| `"action": "accept"` (the only value) | removed — implied |
| `"dst": ["tag:x:443"]` | `"dst": ["tag:x"]`, `"ip": ["443"]` |
| `"proto": "tcp"` | inside `ip`: `"tcp:443"` |
| — | `"app": {...}` (application capabilities), `"via": [...]` (routing) |

One ACL with two tags and two ports is *not* one grant with both: a single grant would allow both ports on both
tags. Split it per tag.

## Example policy (HuJSON: comments and trailing commas allowed)

```jsonc
{
  "groups": {
    "group:team-a":   ["dev-a@example.com"],
    "group:vendor-a": ["contractor-a@example.org"],
    "group:infra":    ["ops-a@example.com"],
  },
  "tagOwners": {
    "tag:app-a-stg-gw":  ["group:infra"],
    "tag:app-a-prod-gw": ["group:infra"],
  },
  "grants": [
    // everyone reaches only their own devices
    {"src": ["autogroup:member"], "dst": ["autogroup:self"], "ip": ["*"]},
    // team: staging DB + HTTPS on the staging gateway only
    {"src": ["group:team-a"], "dst": ["tag:app-a-stg-gw"], "ip": ["tcp:5432", "tcp:443"]},
    // vendor: HTTPS on staging only
    {"src": ["group:vendor-a"], "dst": ["tag:app-a-stg-gw"], "ip": ["tcp:443"]},
    // infra: explicit tags and ports, no "*"
    {"src": ["group:infra"], "dst": ["tag:app-a-stg-gw", "tag:app-a-prod-gw"], "ip": ["tcp:22", "tcp:443", "tcp:5432"]},
  ],
  "ssh": [
    {"action": "check", "src": ["group:infra"], "dst": ["tag:app-a-stg-gw", "tag:app-a-prod-gw"], "users": ["autogroup:nonroot"]},
  ],
  "tests": [
    {"src": "dev-a@example.com", "proto": "tcp",
     "accept": ["tag:app-a-stg-gw:5432", "tag:app-a-stg-gw:443"],
     "deny":   ["tag:app-a-stg-gw:22", "tag:app-a-prod-gw:5432", "tag:app-a-prod-gw:443"]},
    {"src": "contractor-a@example.org", "proto": "tcp",
     "accept": ["tag:app-a-stg-gw:443"],
     "deny":   ["tag:app-a-stg-gw:5432", "tag:app-a-prod-gw:443"]},
  ],
  "sshTests": [
    {"src": "dev-a@example.com", "dst": ["tag:app-a-stg-gw"], "deny": ["root", "ubuntu"]},
    {"src": "ops-a@example.com", "dst": ["tag:app-a-stg-gw"], "check": ["ubuntu"], "deny": ["root"]},
  ],
}
```

- `tests` and `sshTests` run on every save; a failing assertion rejects the whole policy. Treat them as the access
  contract: every grant gets an `accept`, every boundary gets a `deny` (other port, other environment, other party).
- Address tests by identity — users, groups, tags. A `hosts` alias is only an IP: it tests an address, not the
  identity the grants key on. Tests cannot use CIDR notation.
- Tailscale SSH: `dst` may be a tag, `autogroup:self` (sources only users/groups) or the same single user; a user
  cannot SSH to another user's device; tagged devices cannot SSH to user devices. `check` re-authenticates.

## Change procedure (approval)

1. Write the intended matrix first: identity × destination tag × port, allowed and denied.
2. Edit the policy: add/adjust `tests` for both directions **before** the grant, then the grant. Use the admin
   console's "Preview rules" to see what a given user would get.
3. Get approval, save. A rejection names the failing test — fix the rule, never weaken the test to pass.
4. Prove from a **non-admin** identity on a real device (not from your admin laptop):

   ```bash
   # what this device can see, with tags (visibility = access)
   tailscale status --json | jq -r '.Peer[] | [.HostName, ((.Tags // []) | join(",")), (.TailscaleIPs[0] // "-"), (.Online|tostring)] | @tsv'
   tailscale status --json | jq -r '.Self.Tags // [] | join(",")'      # this device's own tags (empty = user device)
   # allowed AND denied ports on the destination, 3 s cap each
   for p in 443 5432 22; do timeout 3 bash -c "</dev/tcp/<tailnet-ip>/$p" 2>/dev/null && echo "$p open" || echo "$p closed"; done
   tailscale whois <tailnet-ip>                                         # which user / tags own that IP
   ```

   "closed" proves the policy only if the service listens: confirm the port is open from an allowed identity first.
5. Check the other direction: list who can now see the destination (peers that appeared in *its* status).
6. Record the change (matrix, approver, policy revision) and the revoke path.

## Revoke

| Scope | Action (approval) | Proof |
|---|---|---|
| one person, one resource | remove them from the group, or narrow the grant | updated `deny` test passes; probe from their device → closed |
| external party leaves | remove the user (removes their devices); remove devices they tagged (tags survive user removal) and their `tagOwners` entries; delete their group and grants | their devices are gone from peers' `tailscale status`; no group, grant, tag owner or test still names them |
| retire a server | remove its tag grants, then the device; delete the tag from `tagOwners` when unused | no grant or test still names the tag |

## Regression triage

| Symptom | Likely cause | Check |
|---|---|---|
| Member lost access right after a broad rule was removed | the broad rule was carrying it; the narrow rule has the wrong tag or port | destination's tags in `status --json`; the member's `tests` |
| Works for admins, fails for the member | admin wildcard masked a wrong member rule | probe from the member's device |
| A host shows up in the vendor's peer list | something lets that host reach the vendor (or vice versa), or the same user owns both | grants where the vendor's group/devices are `dst` |
| A new server is reachable by a team that should not reach it | it was given an existing shared tag | give it its own tag + tests |
| Own-device access to a server stopped after tagging it | tagging removed the user identity; `autogroup:self` excludes tagged devices | `tailscale whois` shows Tags, no user |
| SSH from a tagged host to a laptop fails | tagged devices cannot SSH to user-owned devices | by design — reverse the direction or use a tag |
| Policy save rejected | a test assertion failed | read the named test; fix the rule |

## Verified References

- <https://tailscale.com/docs/reference/syntax/grants.md> — grant fields (`src`, `dst`, `ip`, `app`, `via`); deny-by-default; union of matching grants
- <https://tailscale.com/docs/features/access-control/grants.md> — `ip` network capabilities such as `"tcp:443"`, `"udp:53"`
- <https://tailscale.com/docs/reference/migrate-acls-grants.md> — acls → grants mapping (`action` dropped, ports move to `ip`); split multi-tag ACLs; Preview rules
- <https://tailscale.com/docs/reference/targets-and-selectors.md> — autogroups: `member` (direct members, not shared users), `shared`, `self`, `tagged`, role autogroups, `internet`
- <https://tailscale.com/docs/concepts/device-visibility.md> — netmap holds reachable devices, same-user devices and devices that can reach you; the default policy is allow-all
- <https://tailscale.com/docs/reference/syntax/policy-file.md> — `tests` / `sshTests` reject a failing policy; explicit destinations, no CIDR; `ssh` dst limits; `autogroup:self` excludes tagged devices
- <https://tailscale.com/docs/features/tags.md> — tags replace user identity; tagged devices survive user removal; `tagOwners`; tags for non-human devices only
- <https://tailscale.com/docs/reference/tailscale-cli.md> — `tailscale status --json`, `tailscale whois`
