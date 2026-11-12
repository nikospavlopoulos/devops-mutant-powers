# AWS Gotchas

Every command names `--region <region>` (and `--profile <profile>` where several accounts are configured). Policy
edits, key rotation, quarantine-policy removal and anything that deletes or reconfigures a resource need explicit
human approval. Asked "how do I check": print the commands, do not run them.

Credential precedence, IAM policy evaluation, S3 and S3-compatible endpoints and addressing, the S3 error table,
versioning and lifecycle behaviour, and how EKS (Elastic Kubernetes Service) differs → `references/aws.md`.

## 1. Pin identity and region first

```bash
aws sts get-caller-identity --profile <profile>          # account, ARN of the principal you are acting as
aws configure get region --profile <profile>             # the default you will silently use without --region
```

CloudWatch metrics exist only in the Region where they were created — a per-bucket or per-instance query against the
wrong Region returns **empty data, not an error**.

## 2. S3 cost attribution

**Split by usage type before blaming a bucket.** Storage, requests, data transfer and retrieval are separate usage
types; a "storage" spike is often requests or egress.

```bash
aws ce get-cost-and-usage --profile <profile> \
  --time-period Start=<YYYY-MM-01>,End=<YYYY-MM-01> --granularity MONTHLY --metrics UnblendedCost \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Simple Storage Service"]}}' \
  --group-by Type=DIMENSION,Key=USAGE_TYPE \
  | jq -r '.ResultsByTime[].Groups[] | [.Keys[0], .Metrics.UnblendedCost.Amount] | @tsv' | sort -t$'\t' -k2 -gr | head -20
```

Cost Explorer data refreshes at least every 24 h, and each paginated API request is billed — batch your queries.

**Then size per bucket with the free daily storage metrics** (reported once per day at no extra cost):

```bash
aws cloudwatch get-metric-statistics --profile <profile> --region <bucket-region> --namespace AWS/S3 --metric-name BucketSizeBytes \
  --dimensions Name=BucketName,Value=<bucket> Name=StorageType,Value=StandardStorage \
  --start-time <YYYY-MM-DD>T00:00:00Z --end-time <YYYY-MM-DD>T00:00:00Z --period 86400 --statistics Average
# NumberOfObjects uses StorageType=AllStorageTypes
```

| Empty or surprising result | Cause |
|---|---|
| No datapoints | wrong Region (query the bucket's Region), or the `StorageType` dimension missing |
| Size far below the bill | objects live in another class: `StandardIAStorage`, `GlacierStorage`, `IntelligentTiering*Storage`, … — query each |
| Size far above `aws s3 ls --recursive --summarize` | `BucketSizeBytes` counts noncurrent versions and incomplete multipart uploads too → lifecycle rules for both |

**Relative-time trap (dashboards, metric widgets):** `start` takes an ISO 8601 duration — `-PT3M` is the last
**3 minutes**, `-P3M` the last **3 months**; the widget default is `-PT3H`. One missing `T` turns a quarter's trend
into a flat line.

## 3. IAM — S3 access that "should work"

| Symptom | Cause | Fix |
|---|---|---|
| `aws s3 ls s3://<bucket>/...` → `AccessDenied` while `GetObject` works | `s3:ListBucket` missing — it applies to the **bucket ARN** `arn:aws:s3:::<bucket>`, not `<bucket>/*` | grant `ListBucket` on the bucket ARN (optionally prefix-limited) |
| A tool fails at startup with a bare `403`/`404`, no message | it calls `HeadBucket`, which needs `s3:ListBucket`; HEAD responses carry no body | grant `ListBucket` on the bucket ARN; test with `aws s3api head-bucket --profile <profile> --bucket <bucket>` |
| Prefix-scoped user lists other teams' keys | `ListBucket` without an `s3:prefix` condition | add the condition (below) |

Prefix-scoped access (values marked `<>` are yours):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "ListOwnPrefixOnly", "Effect": "Allow", "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::<bucket>",
      "Condition": { "StringLike": { "s3:prefix": ["<team-a>/*"] } } },
    { "Sid": "ObjectsInOwnPrefix", "Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::<bucket>/<team-a>/*" }
  ]
}
```

Test **positive and negative** before handing it over — a policy that only passed the positive test may grant far
more than intended:

```bash
ARN=arn:aws:iam::<account-id>:user/<user>
aws iam simulate-principal-policy --profile <profile> --policy-source-arn "$ARN" --action-names s3:PutObject \
  --resource-arns "arn:aws:s3:::<bucket>/<team-a>/probe.txt" "arn:aws:s3:::<bucket>/<team-b>/probe.txt" \
  --query 'EvaluationResults[].[EvalResourceName,EvalDecision]' --output table   # expect allowed / implicitDeny
```

The simulator evaluates the principal's identity policies, its attached permissions boundary and (in an organization)
SCPs; a bucket policy counts only if you pass it with `--resource-policy`. Finish with a real call as the scoped identity (inside the prefix succeeds, outside fails). A request
without a prefix (e.g. `HeadBucket`) does not satisfy an `s3:prefix` condition — tools that probe the bucket first may
need their own statement; check with the simulator.

## 4. Exposed access keys and the quarantine policy

When AWS detects a leaked access key it attaches the managed policy `AWSCompromisedKeyQuarantineV3` (older accounts
may show `V2`) to the IAM user and opens a support case. The policy's own documentation says **not to remove it** —
follow the support case. Order (each step approval-gated):

1. From an admin identity (the policy denies the user `iam:CreateAccessKey`/`UpdateAccessKey`/`DeleteAccessKey`),
   create a new key and roll it out to every consumer. The policy is on the user, so the new key stays restricted too.
2. Deactivate, then delete the exposed key; review CloudTrail for what the key did while exposed.
3. Only then, as the case instructs, remove the quarantine policy and verify each consumer works with the new key.
   Removing it first re-arms a key that is still public.

Rotation lockstep across consumers and secret stores → `devops-mutant-powers:secrets-management`.

## 5. Root user limits

The root user cannot assume IAM roles (`sts:AssumeRole` is refused when signed in as root). Use root only for the
root-only tasks, with MFA; day-to-day work goes through IAM roles or Identity Center users.

## 6. Check availability before recommending a move

```bash
aws ec2 describe-instance-type-offerings --profile <profile> --region <region> --location-type availability-zone \
  --filters Name=instance-type,Values=<type> --query 'InstanceTypeOfferings[].Location' --output text
```

An instance type missing from a zone your subnets use is a migration blocker, not a footnote. Cost methodology →
`references/cost-audit.md`.

## Verified References

- <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/cloudwatch_concepts.html> — metrics exist only in the Region in which they are created
- <https://docs.aws.amazon.com/AmazonS3/latest/userguide/cloudwatch-monitoring.html> — S3 storage metrics are reported once per day at no additional cost
- <https://docs.aws.amazon.com/AmazonS3/latest/userguide/metrics-dimensions.html> — `BucketSizeBytes` with `StorageType` values per class (e.g. `StandardStorage`); includes noncurrent versions and incomplete multipart uploads; `NumberOfObjects` with `AllStorageTypes`
- <https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/CloudWatch-Dashboard-Body-Structure.html> — `start` relative ISO 8601: `-PT5M` minutes, `-P3M` months
- <https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/CloudWatch-Metric-Widget-Structure.html> — metric widget `start` default `-PT3H`
- <https://docs.aws.amazon.com/cost-management/latest/userguide/ce-what-is.html> — Cost Explorer refreshes at least once every 24 hours; API requests are billed
- <https://docs.aws.amazon.com/AmazonS3/latest/API/API_HeadBucket.html> — HeadBucket needs `s3:ListBucket`; 400/403/404 without a body
- <https://docs.aws.amazon.com/AmazonS3/latest/userguide/amazon-s3-policy-keys.html> — `s3:prefix` condition key limits listing to a prefix
- <https://docs.aws.amazon.com/cli/latest/reference/iam/simulate-principal-policy.html> — `--policy-source-arn`, `--action-names`, `--resource-arns`; identity policies, the attached permissions boundary and SCPs evaluated; resource policies only when supplied
- <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AWSCompromisedKeyQuarantineV3.html> — quarantine managed policy (V3 current, V2 exists); do not remove it, follow the support case; denies `iam:CreateAccessKey`/`UpdateAccessKey`/`DeleteAccessKey`
- <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-api.html> — you cannot assume a role when signed in as the root user
- <https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-instance-type-offerings.html> — offerings per location; `availability-zone` location type; `instance-type` filter
- <https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-options.html> — `--profile` and `--region` are global options accepted by every `aws` command
