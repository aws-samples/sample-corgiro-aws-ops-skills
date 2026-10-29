# Step 2: Collect Security Signals

For each in-scope account, resolve credentials per [`../../../references/credential-resolution.md`](../../../references/credential-resolution.md) (dispatch on the account's `via`), then run the read-only calls below for each of that account's regions in `scope.json`. Run up to `max_parallel` accounts concurrently (clamp to 10); back off on `ThrottlingException` / `TooManyRequestsException` (base 1s, cap 30s). Persist each raw response under `per-account/<account_id>/` before aggregating - never hold large blobs in context.

All commands are read-only (`describe` / `list` / `get`). `generate-credential-report` produces a report and mutates no resource. Every command here is dispatched with the account's resolved credentials (profile or assumed-role env vars) plus `--region <region>` for regional services; omitted below for brevity.

## Regional vs global

- **Regional** (one call per region in scope; saved to `per-account/<account_id>/<region>/`): GuardDuty, Security Hub, EBS, RDS, AWS Config, security groups, IAM Access Analyzer.
- **Global** (once per account; saved to `per-account/<account_id>/global/`): IAM account summary, credential report, password policy, S3 `list-buckets`, CloudTrail. IAM global calls use `us-east-1`. S3 bucket sub-calls (`get-bucket-*`) are addressed to the bucket's own region.

## Count only this account and region

Delegated-admin and aggregation setups return other accounts' data. A GuardDuty or Security Hub administrator account sees every member's findings, a Security Hub aggregation region returns findings from linked regions, and an organization Access Analyzer reports findings for every account in the org. Every findings query below filters to the account and region being collected, so each finding is counted exactly once - against the account that owns the resource.

## Domain A: Threat Detection (GuardDuty + Security Hub)

GuardDuty (per region):
```bash
aws guardduty list-detectors --output json                      # empty DetectorIds => NOT enabled
# if a detector exists - <criteria> =
#   {"Criterion":{"accountId":{"Eq":["<account_id>"]},"service.archived":{"Eq":["false"]},
#                 "severity":{"Gte":4},"updatedAt":{"Gte":<epoch_ms_30d_ago>}}}
aws guardduty get-findings-statistics --detector-id <id> \
  --group-by SEVERITY --finding-criteria '<criteria>' --output json       # exact counts (GroupedBySeverity)
aws guardduty list-findings --detector-id <id> --finding-criteria '<criteria>' \
  --sort-criteria '{"AttributeName":"severity","OrderBy":"DESC"}' --max-results 50 --output json
aws guardduty get-findings --detector-id <id> --finding-ids <ids...> --output json   # top-50 detail rows only
```
Counts come from `get-findings-statistics`, never from the capped `list-findings` page. Save to `<region>/guardduty.json`: `{ enabled, counts: {high, medium}, topFindings: [{severity, type, title, resourceType, count}] }` (high = severity >= 7).

Security Hub (per region):
```bash
aws securityhub get-enabled-standards --output json             # which standards active
aws securityhub get-findings \
  --filters '{"AwsAccountId":[{"Value":"<account_id>","Comparison":"EQUALS"}],
              "Region":[{"Value":"<region>","Comparison":"EQUALS"}],
              "ComplianceStatus":[{"Value":"FAILED","Comparison":"EQUALS"}],
              "SeverityLabel":[{"Value":"CRITICAL","Comparison":"EQUALS"},{"Value":"HIGH","Comparison":"EQUALS"}],
              "RecordState":[{"Value":"ACTIVE","Comparison":"EQUALS"}],
              "WorkflowStatus":[{"Value":"NEW","Comparison":"EQUALS"},{"Value":"NOTIFIED","Comparison":"EQUALS"}]}' \
  --max-results 100 --output json                               # paginate on NextToken until exhausted
```
`InvalidAccessException` => Security Hub not enabled in that region. Save to `<region>/securityhub.json`: `{ enabled, standards: [{name, status}], failedCriticalHigh: <count>, failedChecks: [{title, severity, resourceId}] }`.

## Domain B: Data Protection (S3 + EBS + RDS)

S3 (global list, per-bucket sub-calls):
```bash
aws s3api list-buckets --output json                            # each bucket carries BucketRegion
aws s3control get-public-access-block --account-id <account_id> --output json   # account-level block
# per bucket, addressed to its BucketRegion:
aws s3api get-public-access-block --bucket <b> --output json     # NoSuchPublicAccessBlockConfiguration => not set
aws s3api get-bucket-policy-status --bucket <b> --output json    # {"PolicyStatus":{"IsPublic":true|false}} - evaluates the policy only; NoSuchBucketPolicy => no policy
```
`NoSuchPublicAccessBlockConfiguration` on the account-level call means no account block is set. The **effective** block for a bucket is, per setting (`BlockPublicAcls`, `IgnorePublicAcls`, `BlockPublicPolicy`, `RestrictPublicBuckets`), account-level OR bucket-level; a bucket is `publicAccessNotBlocked` only if any effective setting is false. `IsPublic` describes the bucket policy alone: a bucket goes in `publicPolicies` only if `IsPublic = true` **and** effective `RestrictPublicBuckets = false`; otherwise it goes in `publicPolicyNeutralized`. Bucket default encryption is not checked: S3 applies SSE-S3 to every bucket by default, so a missing encryption config does not mean unencrypted data. Save to `global/s3-buckets.json`: `{ totalBuckets, publicAccessNotBlocked: [name], publicPolicies: [name], publicPolicyNeutralized: [name], accountPublicAccessBlock: {...} }`.

EBS (per region):
```bash
aws ec2 get-ebs-encryption-by-default --output json              # {"EbsEncryptionByDefault": true|false}
aws ec2 describe-volumes --output json                           # each volume has "Encrypted": true|false
```
Save to `<region>/ebs.json`: `{ defaultEncryption, totalVolumes, unencrypted: [volumeId] }`.

RDS (per region):
```bash
aws rds describe-db-instances --output json                     # StorageEncrypted, PubliclyAccessible
aws rds describe-db-clusters --output json                      # StorageEncrypted
```
Aurora instances inherit encryption from their cluster - evaluate `StorageEncrypted` per cluster for Aurora and per instance only for non-Aurora instances, so one cluster is not counted once per member. Save to `<region>/rds.json`: `{ totalInstances, unencrypted: [id], publiclyAccessible: [id] }`.

## Domain C: Logging and Monitoring (CloudTrail + AWS Config)

CloudTrail (global, once per account):
```bash
aws cloudtrail describe-trails --include-shadow-trails --output json   # every trail visible to the account, incl. org trails
aws cloudtrail get-trail-status --name <TrailARN> --output json        # IsLogging; always the full ARN
```
Dedupe by `TrailARN`, and record each trail's owner (the account ID in its ARN). A region in scope is **covered** if a multi-region trail, or a single-region trail with that `HomeRegion`, has `isLogging` of `true` or `"unknown"` (an org trail whose status cannot be read is assumed to cover - do not raise a false `CLOUDTRAIL_MISSING`). Always pass the full `TrailARN` to `get-trail-status`: member accounts can read an organization trail's status by ARN from any region, but a bare name is resolved against the member's own account and fails with `TrailNotFoundException`. If `get-trail-status` still fails on an organization trail (`IsOrganizationTrail: true`), record its status as `unknown (org trail)` - do not treat it as not logging. Save to `global/cloudtrail.json`: `{ trails: [{arn, ownerAccount, isMultiRegion, isOrganizationTrail, logFileValidation, encrypted, isLogging: true|false|"unknown"}], uncoveredRegions: [region] }`.

AWS Config (per region):
```bash
aws configservice describe-configuration-recorders --output json
aws configservice describe-configuration-recorder-status --output json   # recording: true|false
aws configservice get-compliance-summary-by-config-rule --output json    # compliant vs non-compliant rule counts
```
Save to `<region>/config.json`: `{ enabled, recording, complianceSummary: {compliant, nonCompliant} }`.

## Domain D: Identity (light summary - defer depth to iam-security-review)

Global (us-east-1). Collect summary signals only; do not reproduce the full IAM analysis.
```bash
aws iam get-account-summary --output json                       # AccountMFAEnabled (0 => root no MFA), AccountAccessKeysPresent (1 => root keys)
aws iam generate-credential-report >/dev/null                   # returns State STARTED | INPROGRESS | COMPLETE
aws iam get-credential-report --query Content --output text | base64 --decode > per-account/<account_id>/global/credential-report.csv
aws iam get-account-password-policy --output json               # NoSuchEntity => no policy (a finding, not an error)
```
If `generate-credential-report` is not yet `COMPLETE`, or `get-credential-report` returns `ReportInProgress`, poll with short backoff (a few retries) until it is ready. From the credential report, derive only: count of console users (`password_enabled=true`) with `mfa_active=false`, and from the `<root_account>` row whether root still has credentials (`password_enabled = true`, or `access_key_1_active` / `access_key_2_active` true). Under centralized root access management (see `rootCredentialsManaged` in `scope.json`) member accounts have no root credentials and report `AccountMFAEnabled = 0` - that is not a finding. The report contains no key material - nothing to mask. Save derived values to `global/account-summary.json` (`{ rootMfa, rootAccessKeys, rootHasCredentials, consoleUsersWithoutMfa }`) and the raw password-policy response (or `NoSuchEntity`) to `global/password-policy.json`.

IAM Access Analyzer (per region):
```bash
aws accessanalyzer list-analyzers --type ACCOUNT --output json        # in each member account
aws accessanalyzer list-analyzers --type ORGANIZATION --output json   # in scope.json accessAnalyzerAdmin only
aws accessanalyzer list-findings --analyzer-arn <arn> \
  --filter '{"status":{"eq":["ACTIVE"]},"resourceOwnerAccount":{"eq":["<account_id>"]}}' --output json
```
A region is **covered** for an account if the account has an `ACCOUNT` analyzer there, or the admin account has an `ORGANIZATION` analyzer in that region. Query org-analyzer findings once per member account using the `resourceOwnerAccount` filter, so external-access findings land on the account that owns the resource, not the admin account. If both an account analyzer and the org analyzer report the same resource, keep one finding per resource ARN. Save to `<region>/access-analyzer.json`: `{ covered, coveredBy: "account" | "organization" | null, externalFindings: [{resourceType, resource}] }`.

> Do NOT list access keys, admin roles, or per-user policies here - that is `iam-security-review`'s job. The report's Identity section links to it for depth.

## Domain E: Network Exposure (security groups, public RDS, public S3)

Security groups (per region) - flag ingress open to the internet on sensitive ports:
```bash
aws ec2 describe-security-groups --output json                  # inspect IpPermissions for 0.0.0.0/0 or ::/0
```
Flag a rule when its source is `0.0.0.0/0` or `::/0` and either `IpProtocol` is `-1` (all traffic) or the `FromPort`-`ToPort` range includes a sensitive port (22, 3389, 3306, 5432, 1433, 6379, 27017). Save to `<region>/security-groups.json`: `{ openToInternet: [{groupId, protocol, fromPort, toPort, cidr}] }`.

Public RDS instances and S3 buckets with public access are already collected under Domain B; Step 3 scores them under Network only. Do not re-query them.

## Checks to flag (passed to Step 3)

GUARDDUTY_DISABLED, GUARDDUTY_HIGH_FINDINGS, SECURITYHUB_DISABLED, SECURITYHUB_LOW_SCORE, NO_SECURITY_STANDARDS, S3_PUBLIC_ACCESS_POSSIBLE, S3_PUBLIC_POLICY, EBS_DEFAULT_ENCRYPTION_OFF, EBS_UNENCRYPTED, RDS_UNENCRYPTED, RDS_PUBLICLY_ACCESSIBLE, CLOUDTRAIL_MISSING, CLOUDTRAIL_NOT_LOGGING, CLOUDTRAIL_NOT_MULTIREGION, CLOUDTRAIL_NO_VALIDATION, CLOUDTRAIL_NOT_ENCRYPTED, CONFIG_DISABLED, CONFIG_HIGH_NONCOMPLIANCE, ROOT_NO_MFA, ROOT_ACCESS_KEYS, USERS_WITHOUT_MFA, NO_PASSWORD_POLICY, ACCESS_ANALYZER_DISABLED, EXTERNAL_ACCESS_DETECTED, SG_OPEN_TO_INTERNET.
