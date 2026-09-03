# Cross-Account Defaults

Default configuration values used by all Corgiro modes. Operator-specific values in `~/.corgiro/config.json` override these.

> For how modes obtain credentials per account, see [credential-resolution.md](credential-resolution.md) — it dispatches on each roster entry's `via` field. The AssumeRole pattern below applies to the `cross-account-role` access mode.

| Key | Default | Description |
|-----|---------|-------------|
| `ssoSessionName` | `corgiro` | IAM Identity Center session name |
| `profilePrefix` | `corgiro-` | Prefix for per-account CLI profiles (`<profilePrefix><accountId>`, `identity-center-direct` mode) |
| `permissionSetName` | `CorgiroOperator` | Permission set in the tooling account |
| `memberRoleName` | `CorgiroReadOnlyRole` | Role assumed in each member account |
| `externalId` | _(from operator config)_ | ExternalId for AssumeRole trust |
| `toolingAccountId` | _(from operator config)_ | Delegated admin account |
| `sessionDurationSeconds` | `3600` | STS session duration (hard ceiling 3600 — see below; clamp higher values) |
| `maxParallel` | `4` | Concurrent AssumeRole workers (hard ceiling 10 — clamp higher values) |
| `defaultRegions` | `auto` | Regions to probe (`auto` = discover per account) |
| `fallbackRegions` | `us-east-1, us-west-2, eu-west-1, ap-southeast-1` | Regions probed when `auto` discovery is unavailable (e.g. no payer-level Cost Explorer access) |
| `rosterFreshnessHours` | `24` | Re-fetch roster if older than this |
| `rosterStatePath` | `~/.corgiro/state/roster.json` | Cross-session roster snapshot |
| `coverageStatePath` | `~/.corgiro/state/coverage.json` | Cross-session coverage snapshot |

> **`sessionDurationSeconds` cannot exceed 3600.** Corgiro always assumes `CorgiroReadOnlyRole` *from a role session* — Identity Center credentials are an `AWSReservedSSO_*` role session, and an external-IdP login is an `AssumeRoleWithSAML` role session. Both are **role chaining**, which STS caps at 1 hour regardless of the requested duration. Values above 3600 are clamped with a warning, not a failure. The StackSet template's `MaxSessionDurationSeconds` accepts up to 43200 because the role may also be assumed by a non-chained principal outside Corgiro; that headroom is unreachable through either Corgiro path.

## Operator Config File (`~/.corgiro/config.json`)

Written by `setup-corgiro`. The `accessMode` field selects which block is populated.

```json
{
  "accessMode": "cross-account-role",
  "ssoSession": { "sessionName": "corgiro", "startUrl": "https://ORG.awsapps.com/start", "ssoRegion": "us-east-1" },
  "identityCenter": null,
  "crossAccount": {
    "toolingAccountId": "123456789012",
    "externalId": "your-external-id-here",
    "memberRoleName": "CorgiroReadOnlyRole",
    "accountFilter": { "include": [], "exclude": [] }
  }
}
```

For `accessMode: "identity-center-direct"`, `crossAccount` is `null` and `identityCenter` carries `rolePriority`; per-account credentials come from `<profilePrefix><accountId>` CLI profiles (prefix from `identityCenter.profilePrefix`, default `corgiro-`) instead of AssumeRole.

## Per-Account AssumeRole Pattern

For services without an org-wide API:

1. `sts:AssumeRole` with `RoleArn = arn:aws:iam::<account-id>:role/CorgiroReadOnlyRole`, `ExternalId`, `DurationSeconds = 3600`, `RoleSessionName = corgiro-<operator>-<run_id>` (include the operator's SSO identity for CloudTrail attribution — see [credential-resolution.md](credential-resolution.md) for how to derive and sanitize `<operator>`)
2. Cache credentials in memory keyed by account ID. Refresh on `ExpiredToken`.
3. Run calls in parallel up to `maxParallel` workers (**hard ceiling 10** — clamp higher values). Exponential backoff on `ThrottlingException` (base 1s, cap 30s).
4. Persist per-account JSON under `<run_dir>/per-account/<account_id>/` before aggregating.

## When AssumeRole Fails

| Error | Cause & Remediation |
|-------|---------------------|
| `AccessDenied` on AssumeRole | Role missing or trust mismatch → deploy/refresh StackSet |
| `AccessDenied` with "external ID" | External ID mismatch → check `~/.corgiro/config.json` |
| Account `Status = SUSPENDED` | Skip; surface as "not eligible" |
| Management account | Use local credentials directly for org-level APIs |
