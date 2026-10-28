# Step 2: Collect Security Signals

For each in-scope account, resolve credentials per [`../../../references/credential-resolution.md`](../../../references/credential-resolution.md) (dispatch on the account's `via`), then run the read-only calls below. Run up to `max_parallel` accounts concurrently (clamp to 10); back off on `ThrottlingException` / `TooManyRequestsException` (base 1s, cap 30s). Persist each raw response under `per-account/<account_id>/` before aggregating - never hold large blobs in context.

All commands are read-only (`describe` / `list` / `get`). `generate-credential-report` produces a report and mutates no resource. Every command here is dispatched with the account's resolved credentials (profile or assumed-role env vars) plus `--region <region>` for regional services; omitted below for brevity.

## Regional vs global

- **Regional** (one call per region in scope): GuardDuty, Security Hub, EBS, RDS, AWS Config, security groups, IAM Access Analyzer.
- **Global** (once per account): IAM account summary, credential report, password policy, S3 `list-buckets`. IAM global calls use `us-east-1`. S3 bucket sub-calls (`get-bucket-*`) are addressed to the bucket's own region.

## Domain A: Threat Detection (GuardDuty + Security Hub)

GuardDuty (per region):
```bash
aws guardduty list-detectors --output json                      # empty DetectorIds => NOT enabled
# if a detector exists:
aws guardduty list-findings --detector-id <id> \
  --finding-criteria '{"Criterion":{"severity":{"Gte":4},"updatedAt":{"Gte":<epoch_ms_30d_ago>}}}' \
  --sort-criteria '{"AttributeName":"severity","OrderBy":"DESC"}' --max-results 50 --output json
aws guardduty get-findings --detector-id <id> --finding-ids <ids...> --output json
```
Save to `guardduty-<region>.json`: `{ enabled, findings: [{severity, type, title, resourceType, count}], summary: {high, medium} }`.

Security Hub (per region):
```bash
aws securityhub get-enabled-standards --output json             # which standards active
aws securityhub get-findings \
  --filters '{"ComplianceStatus":[{"Value":"FAILED","Comparison":"EQUALS"}],
              "SeverityLabel":[{"Value":"CRITICAL","Comparison":"EQUALS"},{"Value":"HIGH","Comparison":"EQUALS"}],
              "RecordState":[{"Value":"ACTIVE","Comparison":"EQUALS"}]}' \
  --max-results 100 --output json
```
`InvalidAccessException` on `get-findings` => Security Hub not enabled in that region. Save to `securityhub-<region>.json`: `{ enabled, standards: [{name, status}], failedChecks: [{title, severity, resourceId}], score: {critical, high, passed, total} }`.

## Domain B: Data Protection (S3 + EBS + RDS)

S3 (global list, per-bucket sub-calls):
```bash
aws s3api list-buckets --output json
# per bucket (address to the bucket's region via get-bucket-location):
aws s3api get-bucket-encryption --bucket <b> --output json       # SSE config; NotFound => unencrypted
aws s3api get-public-access-block --bucket <b> --output json     # NoSuchPublicAccessBlockConfiguration => not set
aws s3api get-bucket-policy-status --bucket <b> --output json    # {"PolicyStatus":{"IsPublic":true|false}}; NoSuchBucketPolicy => no policy
```
Also capture the account-level block:
```bash
aws s3control get-public-access-block --account-id <account_id> --output json
```
Save to `s3-buckets.json`: `{ totalBuckets, unencrypted: [name], publicAccessNotBlocked: [name], publicPolicies: [name], accountPublicAccessBlock: {...} }`.

EBS (per region):
```bash
aws ec2 get-ebs-encryption-by-default --output json              # {"EbsEncryptionByDefault": true|false}
aws ec2 describe-volumes --output json                           # each volume has "Encrypted": true|false
```
Save to `ebs-<region>.json`: `{ defaultEncryption, totalVolumes, unencrypted }`.

RDS (per region):
```bash
aws rds describe-db-instances --output json                     # StorageEncrypted, PubliclyAccessible
aws rds describe-db-clusters --output json                      # StorageEncrypted
```
Save to `rds-<region>.json`: `{ totalInstances, unencrypted: [id], publiclyAccessible: [id], clustersUnencrypted: [id] }`.

## Domain C: Logging and Monitoring (CloudTrail + AWS Config)

CloudTrail (per region; dedupe multi-region trails by `TrailARN`):
```bash
aws cloudtrail describe-trails --output json                    # IsMultiRegionTrail, LogFileValidationEnabled, KmsKeyId
aws cloudtrail get-trail-status --name <TrailARN> --output json # IsLogging
```
Save to `cloudtrail-<region>.json`: `{ trails: [{name, isMultiRegion, logFileValidation, encrypted, isLogging}] }`.

AWS Config (per region):
```bash
aws configservice describe-configuration-recorders --output json
aws configservice describe-configuration-recorder-status --output json   # recording: true|false
aws configservice get-compliance-summary-by-config-rule --output json    # compliant vs non-compliant counts
```
Save to `config-<region>.json`: `{ enabled, recording, complianceSummary: {compliant, nonCompliant} }`.

## Domain D: Identity (light summary - defer depth to iam-security-review)

Global (us-east-1). Collect summary signals only; do not reproduce the full IAM analysis.
```bash
aws iam get-account-summary --output json                       # AccountMFAEnabled (0 => root no MFA), AccountAccessKeysPresent (1 => root keys)
aws iam generate-credential-report >/dev/null                   # idempotent
aws iam get-credential-report --query Content --output text | base64 --decode > per-account/<account_id>/credential-report.csv
aws iam get-account-password-policy --output json               # NoSuchEntity => no policy (a finding, not an error)
```
From the credential report, derive only: count of console users (`password_enabled=true`) with `mfa_active=false`, and the `<root_account>` row. The report contains no key material - nothing to mask. Save derived counts to `account-summary.json`.

IAM Access Analyzer (per region):
```bash
aws accessanalyzer list-analyzers --output json                 # empty => none in this region
# if an ACCOUNT/ORGANIZATION analyzer exists:
aws accessanalyzer list-findings --analyzer-arn <arn> \
  --filter '{"status":{"eq":["ACTIVE"]}}' --output json
```
Save to `access-analyzer-<region>.json`: `{ enabled, externalFindings: [{resourceType, resource}] }`.

> Do NOT list access keys, admin roles, or per-user policies here - that is `iam-security-review`'s job. The report's Identity section links to it for depth.

## Domain E: Network Exposure (security groups + derived)

Security groups (per region) - flag ingress open to the internet on sensitive ports:
```bash
aws ec2 describe-security-groups --output json                  # inspect IpPermissions for 0.0.0.0/0 or ::/0
```
Flag any rule allowing `0.0.0.0/0` (or `::/0`) to sensitive ports (22, 3389, 3306, 5432, 1433, 6379, 27017, or "all"). Save to `security-groups-<region>.json`: `{ openToInternet: [{groupId, port, cidr}] }`.

The rest of the Network domain is **derived** in Step 3 from already-collected signals: publicly accessible RDS instances and S3 buckets with public access. Do not re-query them.

## Checks to flag (passed to Step 3)

GUARDDUTY_DISABLED, GUARDDUTY_HIGH_FINDINGS, SECURITYHUB_DISABLED, SECURITYHUB_LOW_SCORE, NO_SECURITY_STANDARDS, S3_UNENCRYPTED, S3_PUBLIC_ACCESS_POSSIBLE, S3_PUBLIC_POLICY, EBS_DEFAULT_ENCRYPTION_OFF, EBS_UNENCRYPTED, RDS_UNENCRYPTED, RDS_PUBLICLY_ACCESSIBLE, CLOUDTRAIL_NOT_LOGGING, CLOUDTRAIL_NOT_MULTIREGION, CLOUDTRAIL_NO_VALIDATION, CLOUDTRAIL_NOT_ENCRYPTED, CONFIG_DISABLED, CONFIG_HIGH_NONCOMPLIANCE, ROOT_NO_MFA, ROOT_ACCESS_KEYS, USERS_WITHOUT_MFA, NO_PASSWORD_POLICY, ACCESS_ANALYZER_DISABLED, EXTERNAL_ACCESS_DETECTED, SG_OPEN_TO_INTERNET.
