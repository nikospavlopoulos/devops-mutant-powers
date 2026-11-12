# Record Changes — Find the Owner, Change It There, Prove It

A DNS record has one write path: the infrastructure-as-code (IaC) root or the controller that owns its zone. A change
made anywhere else, such as the DNS provider's web console, is either reverted by the next apply or lives on outside
review. Load this file before you add, change or delete a record: find the owner, adopt records made by hand, make
the change through a reviewed plan, and prove it at every authoritative server. Record, name-server (NS) and
time-to-live (TTL) changes and every apply need the owner's explicit approval; when asked how to check, print the
commands. Route 53 with Terraform is the worked example; other DNS providers follow the same pattern with their own
Terraform resources.

## 1. Find the owner before touching a record

```bash
dig +short NS example.com                                    # CHANGE: zone — which DNS provider serves it
git grep -n -i -e 'example\.com' -- '*.tf' '*.tfvars'        # CHANGE: zone name; run in every IaC repo
terraform state list | grep -i -E 'route53|dns'              # in the root module the grep found: is the record in state?
```

| What you find | Owner | Write path |
|---|---|---|
| a record or zone resource in IaC code and in its state | that IaC root module | code change → saved plan → review → gated apply (`devops-mutant-powers:infrastructure-provisioning`) |
| TXT records in the zone with `heritage=external-dns,external-dns/owner=<id>` | an ExternalDNS instance in a cluster | change the Kubernetes object it names (`external-dns/resource=<kind>/<ns>/<name>`), not the record |
| neither | nobody — unmanaged | say so, name who controls the zone, and prefer adopting it into IaC (§2) over another manual edit |

- No ownership TXT does not rule ExternalDNS out: `--txt-encrypt-enabled` encrypts it, and the `dynamodb`, `crd`,
  `noop` and `aws-sd` registries keep no TXT in the zone — check the ExternalDNS flags in each cluster.
- A console edit to an IaC-managed record is drift: `terraform plan -refresh-only` shows it, and the next normal apply
  reverts it to what the code says. A console-made record that the code does not declare stays outside review until
  it is imported.
- If the IaC path itself is down during an outage, a console change is break-glass (explicit approval), and the same
  change goes into the code before the next apply.

## 2. Adopt a record made by hand (Terraform, Route 53)

Write the `aws_route53_record` resource block as the record exists today, then:

```hcl
import {
  to = aws_route53_record.www          # CHANGE: the resource block you wrote
  id = "<zone-id>_www.example.com_A"   # CHANGE: ZONEID_NAME_TYPE; append _<set_identifier> if the record has one
}
```

- From Terraform 1.12 the block may use `identity = { zone_id = "<zone-id>", name = "www.example.com", type = "A" }`
  instead of `id`.
- The plan must show `1 to import` and no other change for that record; then the gated apply. Import mechanics:
  `devops-mutant-powers:infrastructure-provisioning` (its refactor-and-state reference).
- Do not set `allow_overwrite = true` to take over the existing record: it defaults to `false`, and the provider calls
  it not recommended for most environments. Import instead.
- Alias records have a fixed 60-second TTL — omit `ttl` on them.
- Leave the zone's own NS record alone; Route 53 recommends not adding, changing or deleting its name servers except in
  rare cases. Delegation changes happen at the parent zone (SKILL.md §5).

## 3. Prove the change

Order: every authoritative server → the resolvers your users use → the app's view → the IaC plan.

```bash
for ns in $(dig +short NS example.com); do                   # CHANGE: zone
  printf '%-30s ' "$ns"; dig @"$ns" +norecurse +short TXT example.com | tr '\n' ' '; echo   # CHANGE: name and type
done
dig @<resolver> www.example.com A                            # after the old TTL; the TTL column is the remaining cache
terraform plan -input=false -detailed-exitcode               # in the owning root: 0 = code and zone agree
```

- Every authoritative server must return the new data. One stale server means some resolvers cache the old answer.
- Route 53 marks a change batch `PENDING` until it has reached every Route 53 server for the zone, then `INSYNC`; the
  per-server loop checks the same thing from outside. Route 53 does not change the start-of-authority (SOA) serial on
  its own, so comparing serials proves nothing there — query the record.
- The app's view: `getent ahosts` in the app's container (SKILL.md Core Rule 2).
- Mail records (SPF, DKIM, DMARC): also prove with a real message → `references/email-deliverability.md` §3.
- Then the cleanup from SKILL.md §5: TTL raised again, temporary records removed.

## Verified References

- <https://developer.hashicorp.com/terraform/tutorials/state/resource-drift> — changes made outside Terraform are drift; `plan -refresh-only` shows them; a normal apply reverts them
- <https://developer.hashicorp.com/terraform/cli/commands/state/list> — `terraform state list` prints one resource address per line
- <https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/route53_record.html.markdown> — `allow_overwrite` default `false`, not recommended for most environments; import ID zone ID, name and type joined by `_` (plus set identifier); `identity` in `import` from Terraform 1.12; alias records fixed 60 s TTL, omit `ttl`
- <https://developer.hashicorp.com/terraform/tutorials/state/state-import> — the plan reports `1 to import`; state changes at apply
- <https://github.com/kubernetes-sigs/external-dns/blob/master/docs/registry/txt.md> — ExternalDNS default TXT registry stores ownership as `heritage=external-dns,external-dns/owner=<id>,external-dns/resource=…`; optional encryption (`--txt-encrypt-enabled`)
- <https://github.com/kubernetes-sigs/external-dns/blob/master/docs/registry/registry.md> — registries `txt` (default), `dynamodb`, `crd`, `noop`, `aws-sd`
- <https://docs.aws.amazon.com/Route53/latest/APIReference/API_GetChange.html> — `PENDING` until the change reaches all Route 53 servers for the zone, then `INSYNC`
- <https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/SOA-NSrecords.html> — Route 53 does not change the SOA serial on its own; do not add, change or delete the zone NS record's name servers except in rare cases
- <https://developer.hashicorp.com/terraform/cli/commands/plan> — `-detailed-exitcode` 0 = no changes, 2 = changes present
