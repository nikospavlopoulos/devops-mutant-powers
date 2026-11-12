# Cloud Cost Audit

A cost finding is only useful if it reconciles to the invoice, separates *why* the number moved, and recommends
something that can actually be bought in the target region today. Deleting "orphans", resizing or moving resources
are live changes — the audit produces a list with evidence; a human approves each action.

## 1. Reconcile to the invoice before analysing

| Question | Why it matters |
|---|---|
| Net or gross? | Cost tools usually show cost **before tax** (Azure Cost Management excludes taxes); the invoice the finance team quotes may include VAT. Compare net to net. |
| Which currency and rate? | Non-USD list prices are reference conversions; invoices use the billing currency. |
| Credits, refunds, marketplace, support plans | often outside the cost tool's default scope — list them separately |
| Actual vs amortized view | reservations/savings plans show as a lump (actual) or spread per day (amortized); pick one and say which |
| Period boundaries | billing period vs calendar month vs the tool's UTC day |

Write the reconciliation as a table: invoice total → minus tax → minus non-usage lines → = tool total (± a stated
tolerance). Unexplained remainder > tolerance = stop and find it before any recommendation.

## 2. Decompose every change: price, design, volume

For each line that moved between two periods (quantity `q`, unit price `p`):

| Effect | Formula / test | Typical cause |
|---|---|---|
| **Price** | `(p1 − p0) × q0` | list-price change, reservation or grandfathered price expired, currency |
| **Volume** | `p0 × (q1 − q0)` | more hours, more GB, more requests |
| **Interaction** | `(p1 − p0) × (q1 − q0)` | both moved — report it, don't hide it in either bucket |
| **Design** | a meter/SKU that appears or disappears | new architecture, SKU change, replication added, a feature turned on |

"Costs went up 30 %" without this split invites the wrong fix (resizing when the price changed, negotiating when the
volume grew).

**Grandfathered pricing:** older SKUs, retired tiers or legacy agreements can carry prices no longer offered.
Re-creating the resource (an IaC replace, a "quick" redeploy) moves it to today's price or an unavailable SKU — check
before recommending any change that recreates it.

## 3. Recommend only what can be bought

```bash
# Azure: is the size offered to THIS subscription in THIS region/zone? (Restrictions column)
az vm list-skus --subscription <sub> --location <region> --size <Standard_D> --all -o table
# AWS: which AZs offer the type?
aws ec2 describe-instance-type-offerings --profile <profile> --region <region> --location-type availability-zone \
  --filters Name=instance-type,Values=<type> --output table
```

`NotAvailableForSubscription` or a zone gap is a blocker for the recommendation, not a detail for later.

## 4. Orphans and leftovers (inventory, then human decision)

| Leftover | Find it | Note |
|---|---|---|
| Azure unattached managed disks | `az disk list --subscription <sub> --query "[?managedBy==null].{name:name, rg:resourceGroup, gb:diskSizeGb, sku:sku.name, state:diskState}" -o table` | snapshot first if anyone might need the data |
| Azure idle public IPs | `az network public-ip list --subscription <sub> --query "[?ipConfiguration==null && natGateway==null].{name:name, rg:resourceGroup}" -o table` | an IP referenced in DNS/allow-lists elsewhere is not "idle" |
| AWS unattached EBS volumes | `aws ec2 describe-volumes --profile <profile> --region <region> --filters Name=status,Values=available` | — |
| AWS Elastic IPs | `aws ec2 describe-addresses --profile <profile> --region <region> --query 'Addresses[?AssociationId==null]'` | Elastic IPs are charged whether associated or not |
| Load balancers with no healthy backends | provider LB lists vs Kubernetes `type: LoadBalancer` Services | a deleted Service can leave its LB if the controller failed |
| Kubernetes `Released` PVs with `Retain` | `kubectl --context <ctx> get pv` (STATUS `Released`) | the cloud disk keeps billing → `devops-mutant-powers:kubernetes-storage` |

Every row in the deletion proposal carries: owner (or "unknown"), last-used evidence, backup/snapshot taken, and the
human who approved it. Decommissioning whole platforms → `devops-mutant-powers:platform-lifecycle`.

## 5. Replicated storage: raw vs logical

Software-replicated storage (Longhorn, Ceph, database replicas) bills **raw** capacity: `replicas × provisioned size`
+ snapshots + filesystem overhead. Report the ratio:

```
raw : logical = (sum of disk capacity backing the storage) / (sum of data the apps actually store)
```

A 3-replica volume with weekly snapshots can sit well above 3:1. Reducing replicas or snapshot retention is a
durability decision, not a cost tweak → `devops-mutant-powers:kubernetes-storage`.

## 6. Scripts that produce numbers

- **Locale:** run with `LC_ALL=C` (at least `LC_NUMERIC=C`) — a comma-decimal locale turns `3.14` into parse errors
  or `3,14` in `printf`/`awk` → `devops-mutant-powers:batch-data-jobs` (its shell-hardening reference).
- **Units:** GB vs GiB, hourly vs monthly (state the hours-per-month you used), per-unit vs per-1,000 requests.
- **Schema-drift guard for pricing scrapers.** A moved or renamed field makes `jq '.Items[].retailPrice'` print `null`
  → summed as 0 → "everything is free". Assert before using results:

```bash
q="serviceName eq 'Virtual Machines' and armRegionName eq '<region>' and armSkuName eq '<sku>' and priceType eq 'Consumption'"
curl -fsS --get 'https://prices.azure.com/api/retail/prices' --data-urlencode "\$filter=$q" \
  | jq -e '(.Items | length) > 0
           and all(.Items[]; (.retailPrice | type) == "number" and .retailPrice > 0 and (.unitOfMeasure | type) == "string")' \
  >/dev/null || { echo "pricing response failed schema/sanity check" >&2; exit 1; }
```

  The Retail Prices API is unauthenticated, returns at most 1,000 items per page (follow `NextPageLink`), and filter
  values are case-sensitive from the `2023-01-01-preview` version. One `armSkuName` returns several meters
  (Windows vs Linux products, Spot) — filter on `productName`/`meterName` explicitly and assert exactly
  one match per SKU. Pin a known SKU's price as a canary and fail when it moves by more than the expected tolerance.

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "The tool says X, the invoice says Y, close enough" | Reconcile first; an unexplained gap usually is the finding. |
| "Costs rose, so downsize" | Split price vs volume vs design first — downsizing doesn't fix a price change. |
| "Move to the cheaper SKU in region Z" | Check it is offered to this subscription and zone today. |
| "Unattached disk = garbage" | Unattached ≠ unwanted. Owner, last use, snapshot, approval. |
| "Three replicas is just HA, ignore it" | It triples raw storage cost; report the ratio and let the owner decide. |
| "The scraper ran without errors" | `null` prices sum to zero silently. Assert the schema and a canary price. |

## Verified References

- <https://learn.microsoft.com/azure/cost-management-billing/costs/understand-cost-mgt-data> — Cost Management data does not include taxes (and some credits/purchases)
- <https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices> — unauthenticated endpoint, `$filter` fields (`armSkuName`, `priceType`, …), `currencyCode`, 1,000 records per page with `NextPageLink`, case-sensitive filter values from 2023-01-01-preview, non-USD prices are for reference
- <https://learn.microsoft.com/en-us/azure/azure-resource-manager/troubleshooting/error-sku-not-available> — `az vm list-skus --location --size --all`, `NotAvailableForSubscription` restrictions
- <https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-instance-type-offerings.html> — instance type offerings per AZ
- <https://learn.microsoft.com/cloud-computing/finops/best-practices/networking> — idle public IP query checks both `ipConfiguration` and `natGateway`; unattached disk detection via `managedBy`
- <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/elastic-ip-addresses-eip.html> — Elastic IPs are charged whether or not they are associated
- <https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-volumes.html> — `status=available` = not attached
