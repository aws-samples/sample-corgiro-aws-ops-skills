# Cross-Account Defaults

Default configuration values used by all Corgiro modes. Operator-specific values in `~/.corgiro/config.json` override these.

> For how modes obtain credentials per account, see [credential-resolution.md](credential-resolution.md) — it dispatches on each roster entry's `via` field. The AssumeRole pattern below applies to the `cross-account-role` access mode.

| Key | Default | Description |
|-----|---------|-------------|
| `ssoSessionName` | `corgiro` | IAM Identity Center session name |
| `permissionSetName` | `CorgiroOperator` | Permission set in the tooling account |
| `memberRoleName` | `CorgiroReadOnlyRole` | Role assumed in each member account |
| `externalId` | _(from operator config)_ | ExternalId for AssumeRole trust |
| `toolingAccountId` | _(from operator config)_ | Delegated admin account |
| `sessionDurationSeconds` | `3600` | STS session duration |
| `maxParallel` | `4` | Concurrent AssumeRole workers (hard ceiling 10 — clamp higher values) |
| `defaultRegions` | `auto` | Regions to probe (`auto` = discover per account) |
| `rosterFreshnessHours` | `24` | Re-fetch roster if older than this |
| `rosterStatePath` | `~/.corgiro/state/roster.json` | Cross-session roster snapshot |
| `coverageStatePath` | `~/.corgiro/state/coverage.json` | Cross-session coverage snapshot |

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

For `accessMode: "identity-center-direct"`, `crossAccount` is `null` and `identityCenter` carries `rolePriority`; per-account credentials come from `corgiro-<accountId>` CLI profiles instead of AssumeRole.

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
