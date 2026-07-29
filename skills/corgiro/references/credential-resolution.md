# Credential Resolution

How any mode obtains credentials for a given account. Modes stay access-mode-agnostic by reading `~/.corgiro/state/roster.json` and dispatching on each account's `via` field. The roster and the `accessMode` are written by `setup-corgiro`.

## Pre-flight Security Checks

Before reading any credentials or config, run these checks at the start of every mode execution:

### 1. File Permission Verification

Verify permissions on every run (not just setup):

```bash
CORGIRO_DIR_PERM=$(stat -f "%Lp" ~/.corgiro 2>/dev/null || stat -c "%a" ~/.corgiro 2>/dev/null)
if [ "$CORGIRO_DIR_PERM" != "700" ]; then
  echo "WARNING: ~/.corgiro/ permissions are $CORGIRO_DIR_PERM (expected 700). Fixing..."
  chmod 700 ~/.corgiro ~/.corgiro/state
  chmod 600 ~/.corgiro/config.json ~/.corgiro/state/*.json
fi
```

### 2. SSO Session Freshness Check (T2)

Cached SSO tokens in `~/.aws/sso/cache/` can be reused by anyone with workstation access. Enforce a maximum acceptable session age:

```bash
# Find the SSO cache file for the corgiro session
CACHE_FILE=$(ls -t ~/.aws/sso/cache/*.json 2>/dev/null | head -1)
if [ -n "$CACHE_FILE" ]; then
  EXPIRES_AT=$(python3 -c "import json,sys; print(json.load(open('$CACHE_FILE')).get('expiresAt',''))" 2>/dev/null)
  if [ -n "$EXPIRES_AT" ]; then
    EXPIRES_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$EXPIRES_AT" "+%s" 2>/dev/null || date -d "$EXPIRES_AT" "+%s" 2>/dev/null)
    NOW_EPOCH=$(date "+%s")
    REMAINING=$(( EXPIRES_EPOCH - NOW_EPOCH ))
    if [ "$REMAINING" -le 0 ]; then
      echo "SSO session expired. Run: aws sso login --sso-session corgiro"
      exit 1
    fi
  fi
fi
```

**Recommended session duration:** Configure IAM Identity Center session to 1 hour maximum. This bounds the window during which a stolen token is usable.

**MFA requirement:** Operators MUST have MFA enabled on their Identity Center authentication. Without MFA, token theft becomes a single-factor attack.

## Roster Entry Schema (authoritative)

This section is the **single source of truth** for the shape of a Roster Entry. Other documents (setup, account-coverage, mode references) link here — they do not restate the schema.

`~/.corgiro/state/roster.json` maps a 12-digit account ID to a Roster Entry:

```json
{
  "111111111111": {
    "name": "prod-app",
    "role": "ReadOnlyAccess",
    "via": "sso",
    "readOnlyEnforced": true,
    "profile": "corgiro-111111111111",
    "warning": "role is not in rolePriority (not a known read-only role)",
    "reachable": true,
    "lastProbedAt": "2026-07-29T19:36:04+07:00"
  }
}
```

| Field | Required | Written by | Meaning |
|-------|----------|------------|---------|
| `name` | yes | setup | Account display name |
| `role` | yes | setup | Role/permission set used to reach the account |
| `via` | yes | setup | Credential dispatch key: `sso` or `assume-role` |
| `readOnlyEnforced` | yes | setup | `true` when read-only is guaranteed at the IAM layer (always for `assume-role`; for `sso` only when the role is a known read-only role). `false` entries are residual risk — surface them in summaries. |
| `profile` | `sso` only | setup | Per-account CLI profile name (`<profilePrefix><accountId>`) |
| `warning` | optional | setup | Residual-risk note (e.g. non-read-only role accepted by double-confirmation) |
| `reachable` | optional | account-coverage | Result of the most recent reachability probe |
| `lastProbedAt` | optional | account-coverage | Timestamp of that probe |

Ownership: `setup-corgiro` creates entries and owns scope (which accounts exist in the roster); `account-coverage` refreshes only the reachability fields (`reachable`, `lastProbedAt`) — under `cross-account-role` it also rebuilds scope from the org. Modes never write the roster.

## Inputs

- Account ID and its Roster Entry (schema above)
- `~/.corgiro/config.json` → `accessMode`, `ssoSession`, `crossAccount`

## Dispatch on `via`

### via = "sso" — accessMode: identity-center-direct

Use the per-account CLI profile written by `setup-corgiro` (Option A). No AssumeRole, no external ID — the CLI refreshes credentials from the cached SSO token.

```bash
aws <service> <command> --profile corgiro-<accountId> --region <region> --output json
```

- Profile missing → roster is stale; re-run `/corgiro setup-corgiro` (Option A) to refresh profiles.
- `aws sts get-caller-identity --profile corgiro-<accountId>` returns an auth error → SSO session expired; run `aws sso login --sso-session corgiro`.

### via = "assume-role" — accessMode: cross-account-role

Assume `CorgiroReadOnlyRole` from the tooling-account session, gated by the external ID. The tooling-account session is the `corgiro` base profile written by `setup-corgiro` Option B (Step 5) — invoke it with `--profile corgiro` or `export AWS_PROFILE=corgiro`. See [cross-account-defaults.md](cross-account-defaults.md) → "Per-Account AssumeRole Pattern" for full detail and the failure table.

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::<accountId>:role/CorgiroReadOnlyRole \
  --role-session-name corgiro-<operator>-<run_id> \
  --external-id <externalId> \
  --duration-seconds 3600 \
  --profile corgiro
```

Export the returned credentials (env vars or a temporary named profile) for subsequent calls in that account.

> **Session name = operator identity + run id (CloudTrail attribution, threat T9).** Derive `<operator>` once per run from the tooling-account caller: `aws sts get-caller-identity --query Arn --output text`, then take the segment after the last `/` (the SSO user, e.g. `jdoe@example.com`). `RoleSessionName` must match `[\w+=,.@-]` and be ≤ 64 chars total — strip any other characters from `<operator>` and truncate it so `corgiro-<operator>-<run_id>` stays within 64. This attributes every member-account read to a specific operator instead of an anonymous `corgiro-<run_id>`.

## Parallelism & backoff

Both paths: up to `maxParallel` (default 4) concurrent workers; exponential backoff on throttling (`ThrottlingException` / `TooManyRequestsException`, base 1s, cap 30s). Persist per-account JSON before aggregating.

**Hard ceiling:** `maxParallel` must never exceed **10**, regardless of operator config — clamp to 10 if a higher value is set. Combined with backoff, this keeps Corgiro from exhausting member-account API rate limits and disrupting live workloads (threat T8). For very large orgs, prefer batching accounts over raising concurrency. Optionally cap calls per account per run (e.g. ≤ 50) and stop early with a "partial — rate-limited" note rather than hammering a throttled account.

## Reachability categories (shared vocabulary)

| Category         | via = sso                                  | via = assume-role                                 |
| ---------------- | ------------------------------------------ | ------------------------------------------------- |
| `reachable`      | profile resolves, `get-caller-identity` OK | AssumeRole OK                                     |
| `auth_expired`   | SSO token expired → `aws sso login`        | tooling session expired → re-login                |
| `not_in_scope`   | account no longer assigned to the user     | —                                                 |
| `role_missing`   | —                                          | `CorgiroReadOnlyRole` absent → redeploy StackSet  |
| `trust_mismatch` | —                                          | external ID mismatch → check `config.json`        |
| `suspended`      | account suspended                          | account suspended                                 |
| `management`     | —                                          | management account (use local creds for org APIs) |
