# AWS — Object Storage and IAM Essentials

Load this file when the work is Amazon S3 (Simple Storage Service) or an S3-compatible store reached with AWS tools:
which credentials a tool really uses, how IAM (Identity and Access Management) decides allow or deny, endpoints and
addressing for AWS and third-party S3 APIs, what each S3 error code points at, the bucket settings that surprise people,
and a short note on how Amazon EKS (Elastic Kubernetes Service) differs. Cost metrics, prefix-scoped S3 policies with
the policy simulator, leaked-key quarantine, root-user limits and instance-type availability live in
`references/aws-gotchas.md` — not repeated here.

Every command names `--profile <profile>` and, where the service is regional, `--region <region>`. Policy and bucket
setting changes (bucket policy, lifecycle, versioning, Object Ownership), key creation and EKS access changes need
explicit human approval. Asked "how do I check": print the commands, do not run them.

## 1. Which identity, which credentials

`aws sts get-caller-identity --profile <profile>` is the safe pin: STS (Security Token Service) `GetCallerIdentity`
needs no permission and works even when a policy explicitly denies it. It returns `Account`, `Arn` and `UserId` —
record the account and ARN (Amazon Resource Name), never keys.

- An assumed role shows its **session** ARN, `arn:aws:sts::<account>:assumed-role/<role>/<session>`. Where an IAM
  principal is required (for example an EKS access entry, §6) use the **role** ARN,
  `arn:aws:iam::<account>:role/<optional-path/><role>`.
- **Where credentials come from** (AWS CLI, highest first): command-line options (`--profile`, `--region`) →
  environment variables → assume role → assume role with web identity → IAM Identity Center → credentials file →
  custom process → config file → container credentials → EC2 (Elastic Compute Cloud) instance profile.
- So exported `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` beat a profile chosen with `AWS_PROFILE`; only an explicit
  `--profile` on the command line outranks the environment. `AWS_REGION` beats `AWS_DEFAULT_REGION` and the profile's
  `region`; `--region` beats both. `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` move the files themselves.
- See which variables are set without printing values: `env | grep -o '^AWS_[A-Z_]*'`.
- Pin in the place the failing tool runs (continuous integration job, container, pod, another host) — a laptop's
  answer says nothing about the runner.

## 2. How IAM decides

| Rule | Consequence |
|---|---|
| Everything starts as an implicit deny; an explicit `Deny` in any applicable policy wins | adding another `Allow` never fixes an explicit deny — find and change the denying policy |
| Same account: the identity-based and resource-based (bucket) policies are combined — an `Allow` in either suffices | a bucket policy alone can grant a same-account role |
| Permissions boundary, service control policies (SCPs) and resource control policies (RCPs) intersect with identity policies and never grant on their own | an action must be allowed by every one that applies |
| Cross account: the requester's identity policy **and** the resource account's bucket policy must both allow | a bucket policy naming the other account is half the change |

S3 `AccessDenied` messages name the policy type for requests within the same account or the same AWS Organizations
organization: `… with an explicit deny in a <type> policy` (with the policy ARN) versus `… because no <type> policy
allows the <action> action` — types include identity-based, resource-based, permissions boundary, session, SCP, RCP and
VPC (virtual private cloud) endpoint policies. Cross-organization requests get a bare `Access Denied`, and a VPC
endpoint policy denial inside the organization gets no extra context.

**Least privilege:** prefer roles and temporary credentials over access keys; start from AWS managed policies and narrow
with customer managed ones; IAM Access Analyzer can generate a policy from CloudTrail activity and validate policies
before you save them. Prove the result with an allowed and a denied call (`references/aws-gotchas.md` §3).

## 3. Endpoints and addressing (AWS and S3-compatible stores)

| Style | URL | Notes |
|---|---|---|
| Virtual-hosted | `https://<bucket>.s3.<region>.amazonaws.com/<key>` | the wildcard TLS certificate does not match bucket names containing dots |
| Path-style | `https://s3.<region>.amazonaws.com/<bucket>/<key>` | still supported; AWS has postponed its deprecation |

- **Wrong Region:** a path-style request to the legacy global endpoint or another Region's endpoint gets `301
  PermanentRedirect`; a virtual-hosted request to the legacy global endpoint gets `307 Temporary Redirect` (Regions
  launched before 2019-03-20) or `400 Bad Request` (newer Regions). Find the bucket's Region: HeadBucket, sent to any
  Region, returns it in `x-amz-bucket-region` even when access is denied — `aws s3api head-bucket --profile <profile>
  --bucket <bucket> --query BucketRegion` when allowed, otherwise
  `curl -sI https://s3.us-east-1.amazonaws.com/<bucket> | grep -i x-amz-bucket-region` (path-style, so dotted names
  work). `GetBucketLocation` is no longer the recommended way.
- **Addressing in the CLI:** `s3.addressing_style` = `auto` (default: virtual-hosted when the name allows, else path),
  `path` or `virtual`. With `path`, the configured Region must match the bucket's.
- **Custom endpoints, highest first:** `--endpoint-url` → `AWS_ENDPOINT_URL_S3` → `AWS_ENDPOINT_URL` → `endpoint_url`
  under the S3 key of a `[services]` section → `endpoint_url` directly in the profile → the AWS default.
  `AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true` ignores the configured ones (not `--endpoint-url`). A global
  `AWS_ENDPOINT_URL` or profile-level `endpoint_url` sends **every** service there — STS included, so `get-caller-identity`
  stops telling you about AWS. Scope a third-party store to S3 only:

```ini
[profile objstore]
region = <region-the-provider-expects>
services = objstore-s3
s3 =
  addressing_style = path

[services objstore-s3]
s3 =
  endpoint_url = https://s3.example.com
```

- **Default integrity checksums:** AWS SDK (software development kit) and CLI versions from December 2024 on calculate a CRC (cyclic redundancy check)
  checksum for uploads by default (`request_checksum_calculation` / `AWS_REQUEST_CHECKSUM_CALCULATION` =
  `WHEN_SUPPORTED`) and validate response checksums (`response_checksum_validation`). If a third-party store starts
  rejecting uploads after a client upgrade, test once with `WHEN_REQUIRED` for both — a test to run, not a known
  incompatibility of any given provider.
- **Terraform state on an S3-compatible store:** support is best effort (tested against Amazon S3 only); the backend
  needs `endpoints { s3 = "https://s3.example.com" }`, `use_path_style = true` and, depending on the provider,
  `skip_credentials_validation`, `skip_region_validation`, `skip_requesting_account_id`, `skip_s3_checksum`. Backend
  design and locking → `devops-mutant-powers:infrastructure-provisioning`.

## 4. S3 error → cause

| Code (HTTP status) | Points at |
|---|---|
| `PermanentRedirect` (301), `TemporaryRedirect` (307), `IllegalLocationConstraintException` (400), `IncorrectEndpoint` (400) | the bucket lives in another Region or behind another endpoint — pass its Region/endpoint (§3) |
| `InvalidHostHeader` (400) | wrong addressing style for this endpoint (path vs virtual-hosted) |
| `AuthorizationHeaderMalformed` (400) | the authorization header is invalid — read the message; `Credential should be scoped to a valid Region, not <region>` means the signing Region differs from the request's Region |
| `RequestTimeTooSkewed` (403); `Signature expired: … is now earlier than …`; `Signature not yet current` | the client's clock — fix time sync, not permissions |
| `SignatureDoesNotMatch` (403) | wrong secret for the key ID, or a hop that rewrote a signed part → `devops-mutant-powers:error-reading`, and `devops-mutant-powers:reverse-proxy` for a content delivery network in front |
| `InvalidAccessKeyId` (403) | the key ID is unknown to the service you reached — wrong profile, or keys for one endpoint sent to another |
| `ExpiredToken` (400) | the session expired — renew the Identity Center login or the assumed role |
| `AccessDenied` (403) | read the policy type in the message (§2). `GetObject` on a missing key returns `404` only with `s3:ListBucket`, otherwise `403` |
| `AccessControlListNotSupported` (400) | the bucket has ACLs (access control lists) disabled and the request carried an ACL other than `bucket-owner-full-control` — remove the ACL from the client's settings |
| `403` on a bucket encrypted with a customer managed KMS (Key Management Service) key | uploads need `kms:GenerateDataKey`, downloads and multipart uploads `kms:Decrypt` — in the key policy as well |

## 5. Bucket settings that surprise people

- **Object Ownership:** new buckets default to *Bucket owner enforced* — ACLs disabled, the bucket owner owns every
  object, access comes only from policies. Cross-account writers need bucket-policy grants, not ACLs.
- **Versioning:** off by default; once enabled a bucket can never return to unversioned, only be suspended. A delete
  adds a delete marker; every version is billed as a full object. When enabling it on a bucket with an expiration rule,
  add `NoncurrentVersionExpiration` (optionally `NewerNoncurrentVersions`) or "deleted" data keeps accumulating.
- **Lifecycle:** a new rule applies to existing objects too — objects already past the age are queued for expiry
  right away, and noncurrent-version expiry is permanent. A bucket policy **cannot** stop lifecycle deletions or
  transitions, even one denying everything. Expiration does not remove incomplete multipart uploads; add
  `AbortIncompleteMultipartUpload` (not allowed in a rule filtered by tags). Rules are eventually consistent.

## 6. How EKS differs (pointer)

- **People and pipelines → the Kubernetes API:** EKS access entries (cluster authentication mode `API` or
  `API_AND_CONFIG_MAP`; moving to a mode with the EKS API cannot be undone). An entry holds exactly one existing IAM
  principal; role ARNs may include a path (`aws-auth` ConfigMap entries cannot). Deleting and recreating a role with the
  same ARN does not revive its entry — EKS stored the old role ID — so delete and recreate the entry. Group names on an
  entry are not checked against RBAC (role-based access control) bindings; changes take seconds to apply.
- **Pods → AWS:** EKS Pod Identity (an agent DaemonSet on each node; role trust principal `pods.eks.amazonaws.com`; no
  OpenID Connect provider) or IRSA (IAM roles for service accounts, which uses one). Restrict pod access to the
  Instance Metadata Service (IMDS), or containers can reach the node role's credentials. Pods behind a proxy need
  `169.254.170.23` in `NO_PROXY`.
- Kubernetes RBAC and who gets access → `devops-mutant-powers:access-management`; workloads →
  `devops-mutant-powers:kubernetes`.

## Traps

- Reading `403` on `GetObject` as "no permission" when the key may simply not exist (no `s3:ListBucket`).
- Answering an explicit deny with another `Allow`; assuming same-account rules for a cross-account request.
- Pointing a client at an S3-compatible endpoint without the addressing style and Region it expects, or via a global
  `AWS_ENDPOINT_URL` that also captures STS.
- Pasting the `sts …:assumed-role/…` session ARN where the role ARN belongs.
- Blaming a bucket policy for lifecycle deletions; enabling a lifecycle rule without checking which existing objects
  it expires.

## Verified References

- <https://docs.aws.amazon.com/STS/latest/APIReference/API_GetCallerIdentity.html> — no permission needed, works under explicit deny; `Account`/`Arn`/`UserId`; assumed-role ARN format
- <https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html> — credential and configuration precedence order; signatures carry a timestamp, clock must be right
- <https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html> — env vars override profile settings, command line overrides env; `AWS_PROFILE` vs `--profile`; `AWS_REGION` vs `AWS_DEFAULT_REGION`; file-location variables; checksum variables
- <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html> — union of identity and resource policies in one account; explicit deny overrides; boundaries, SCPs and RCPs intersect
- <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic-cross-account.html> — both accounts' evaluations must allow
- <https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html> — temporary credentials, least privilege, Access Analyzer generation and validation; SCPs/RCPs and boundaries do not grant
- <https://docs.aws.amazon.com/AmazonS3/latest/userguide/troubleshoot-403-errors.html> — enhanced `AccessDenied` wording and policy types; same account/organization only; VPC endpoint exception; KMS permissions; Bucket owner enforced is the default
- <https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetObject.html> — missing key: 404 with `s3:ListBucket`, 403 without
- <https://docs.aws.amazon.com/AmazonS3/latest/userguide/VirtualHosting.html> — URL formats; dotted names and the wildcard certificate; path-style deprecation delayed; 301 / 307 / 400 by endpoint and Region age
- <https://docs.aws.amazon.com/AmazonS3/latest/API/API_HeadBucket.html> — `x-amz-bucket-region` returned regardless of permissions, also to anonymous requests
- <https://docs.aws.amazon.com/cli/latest/reference/s3api/head-bucket.html> — `BucketRegion` output field
- <https://docs.aws.amazon.com/cli/latest/reference/s3api/get-bucket-location.html> — `GetBucketLocation` no longer best practice; use HeadBucket
- <https://docs.aws.amazon.com/cli/latest/topic/s3-config.html> — `addressing_style` values and `auto` behaviour; `path` needs the matching Region; nested `s3 =` settings
- <https://docs.aws.amazon.com/sdkref/latest/guide/feature-ss-endpoints.html> — endpoint settings, `[services]` section, precedence, `ignore_configured_endpoint_urls`, global endpoint applies to all services
- <https://docs.aws.amazon.com/sdkref/latest/guide/feature-dataintegrity.html> — default CRC checksums since December 2024 versions; `WHEN_SUPPORTED` / `WHEN_REQUIRED`
- <https://developer.hashicorp.com/terraform/language/backend/s3> — S3-compatible support best effort; `endpoints.s3`, `use_path_style`, `skip_*` arguments
- <https://docs.aws.amazon.com/AmazonS3/latest/userguide/ErrorCodeBilling.html> — error codes and HTTP statuses in §4
- <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-troubleshooting.html> — `Credential should be scoped to a valid Region`, `Signature expired`, `Signature not yet current`; proxies that modify headers
- <https://docs.aws.amazon.com/AmazonS3/latest/userguide/about-object-ownership.html> — Bucket owner enforced default; `AccessControlListNotSupported` (400) for other ACLs
- <https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html> — three states, never back to unversioned; delete markers; each version billed in full; add noncurrent expiration
- <https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html> — rules apply to existing objects; bucket policy cannot prevent lifecycle actions
- <https://docs.aws.amazon.com/AmazonS3/latest/userguide/intro-lifecycle-rules.html> — `NoncurrentVersionExpiration`, `NewerNoncurrentVersions`, `AbortIncompleteMultipartUpload` (not with tag filters); eventual consistency
- <https://docs.aws.amazon.com/eks/latest/userguide/setting-up-access-entries.html> — `API` / `API_AND_CONFIG_MAP`; cannot switch back
- <https://docs.aws.amazon.com/eks/latest/userguide/creating-access-entries.html> — one principal per entry; path allowed (not in `aws-auth`); recreated principal needs a new entry; groups not validated; eventual consistency
- <https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html> — agent DaemonSet; `pods.eks.amazonaws.com`; no OIDC provider; IMDS restriction; `169.254.170.23` in `NO_PROXY`
