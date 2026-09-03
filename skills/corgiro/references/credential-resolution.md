# Credential Resolution

How any mode obtains credentials for a given account. Modes stay access-mode-agnostic by reading `~/.corgiro/state/roster.json` and dispatching on each account's `via` field. The roster, the `accessMode`, and the `authMethod` are written by `setup-corgiro`.

Two independent axes:

- **`authMethod`** — how the operator obtains the base session (IAM Identity Center, or an external IdP). See [Auth Method Dispatch](#auth-method-dispatch).
- **`via`** (per roster entry) — how each member account is reached from that base session. See [Dispatch on `via`](#dispatch-on-via).

Modes care about neither directly: they resolve credentials through this reference and issue identical API calls either way.

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

### 2. Operator Session Freshness Check (T2)

Cached operator credentials can be reused by anyone with workstation access. Enforce a maximum acceptable session age, then confirm the session is actually still valid.

Where the expiry lives depends on `authMethod` (see [Auth Method Dispatch](#auth-method-dispatch)), so run **2a or 2b**, then **2c** in all cases.

#### 2a. `authMethod: identity-center` — SSO token cache

```bash
# Locate the cache file for THIS session. AWS CLI v2 keys the sso-session token
# cache on sha1(sessionName), so derive the filename rather than guessing.
SESSION=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.corgiro/config.json')))['ssoSession']['sessionName'])" 2>/dev/null)
SESSION_HASH=$(printf %s "$SESSION" | { shasum -a 1 2>/dev/null || sha1sum; } | cut -d' ' -f1)
CACHE_FILE=~/.aws/sso/cache/$SESSION_HASH.json

# Fallback: match on startUrl, not modification time.
if [ ! -f "$CACHE_FILE" ]; then
  START_URL=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.corgiro/config.json')))['ssoSession']['startUrl'])" 2>/dev/null)
  CACHE_FILE=$(grep -l "\"startUrl\": *\"$START_URL\"" ~/.aws/sso/cache/*.json 2>/dev/null | head -1)
fi

if [ -n "$CACHE_FILE" ] && [ -f "$CACHE_FILE" ]; then
  EXPIRES_AT=$(python3 -c "import json,sys; print(json.load(open('$CACHE_FILE')).get('expiresAt',''))" 2>/dev/null)
  if [ -n "$EXPIRES_AT" ]; then
    EXPIRES_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$EXPIRES_AT" "+%s" 2>/dev/null || date -d "$EXPIRES_AT" "+%s" 2>/dev/null)
    NOW_EPOCH=$(date "+%s")
    REMAINING=$(( EXPIRES_EPOCH - NOW_EPOCH ))
    if [ "$REMAINING" -le 0 ]; then
      echo "SSO session expired. Run: aws sso login --sso-session <sessionName>"
      exit 1
    fi
  fi
fi
```

> **Never select the cache file by modification time.** A laptop commonly holds SSO tokens for several unrelated sessions. Picking the newest file can read a *different* session's `expiresAt` and report a healthy Corgiro session when Corgiro's own token has expired — a silent false pass on a security control.

#### 2b. `authMethod: saml-external` — credentials-file expiry

An external-IdP helper writes short-lived credentials into a named profile in `~/.aws/credentials`, along with an expiry timestamp. `aws-azure-login` writes `aws_expiration` (ISO 8601):

```bash
AUTH_PROFILE=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.corgiro/config.json')))['auth']['profile'])")
EXPIRES_AT=$(aws configure get aws_expiration --profile "$AUTH_PROFILE" 2>/dev/null)

if [ -z "$EXPIRES_AT" ]; then
  echo "NOTE: no known expiry key on profile '$AUTH_PROFILE'. Age enforcement unavailable; relying on 2c only."
fi
```

> **Expiry key names vary by helper.** `aws_expiration` is verified for `aws-azure-login`. Other helpers use different keys and some write none at all. When no expiry is found, do **not** fail — emit the note above and let 2c decide. Age enforcement is best-effort on this path; validity enforcement is not.

#### 2c. Both — authoritative validity probe

Expiry timestamps only say when a session *would* lapse. They do not detect a session revoked or disabled at the IdP, which otherwise fails on the first member account, mid-fan-out and mid-report. Probe the tooling-account session before doing any work:

```bash
aws sts get-caller-identity --profile "$AUTH_PROFILE" >/dev/null 2>&1 || {
  echo "Operator session invalid or expired. Run: $LOGIN_COMMAND"
  exit 1
}
```

`$LOGIN_COMMAND` comes from `auth.loginCommand` for `saml-external`, or is `aws sso login --sso-session <sessionName>` for `identity-center`.

**Recommended session duration:** 1 hour maximum, configured in IAM Identity Center or in your external IdP. This bounds the window during which a stolen session is usable.

**MFA requirement:** Operators MUST have MFA enabled on the authentication that produces the operator session. Without MFA, token theft becomes a single-factor attack. Under `saml-external`, Corgiro cannot observe or attest to this — it is enforced entirely in the external IdP (see [Residual risk](#residual-risk-saml-external)).

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
- `~/.corgiro/config.json` → `accessMode`, `authMethod`, `ssoSession`, `auth`, `crossAccount`

## Auth Method Dispatch

`authMethod` describes **how the operator obtains the base session**. It is orthogonal to `accessMode`, which describes **how member accounts are reached**. Only the base session differs — `via` dispatch, the roster schema, parallelism, and every mode's API calls are identical across auth methods.

| `authMethod` | Base session from | Base profile | Re-login command |
|---|---|---|---|
| `identity-center` (default) | IAM Identity Center | `<profilePrefix><accountId>` (Option A) or `corgiro` (Option B) | `aws sso login --sso-session <sessionName>` |
| `saml-external` | External IdP via `sts:AssumeRoleWithSAML` | `auth.profile` (default `corgiro`) | `auth.loginCommand` |

**A missing `authMethod` field means `identity-center`.** Existing `config.json` files predate this field and must keep working unchanged.

`saml-external` covers any IdP-federated CLI helper that writes short-lived **role-session** credentials to a named profile — `aws-azure-login`, `saml2aws`, `gimme-aws-creds`, or a `credential_process` returning a role session.

### Valid combinations

| `accessMode` | `identity-center` | `saml-external` |
|---|---|---|
| `cross-account-role` | supported | supported |
| `identity-center-direct` | supported | **invalid — hard stop** |

`identity-center-direct` discovers accounts through `aws sso list-accounts` / `list-account-roles`, which require an Identity Center access token. An external IdP exposes the account/role list only inside the SAML assertion, with no AWS API to enumerate it. There is nothing to fall back to, so reject the combination at setup rather than half-working:

> `authMethod: saml-external requires accessMode: cross-account-role. Account discovery on identity-center-direct depends on the Identity Center token APIs, which have no external-IdP equivalent. Re-run /corgiro setup-corgiro and choose path B.`

### Preconditions for `saml-external`

Verify before any member-account work; each failure is a hard stop:

```bash
CALLER=$(aws sts get-caller-identity --profile "$AUTH_PROFILE" --output json)
```

1. `.Account` must equal `crossAccount.toolingAccountId`.
2. `.Arn` must match `^arn:aws:sts::<toolingAccountId>:assumed-role/`. An `arn:aws:iam::…:user/` ARN means the profile holds **long-lived IAM user access keys**, not a federated session — reject it:

   > `Profile '<name>' resolves to an IAM user, not a federated role session. Corgiro requires short-lived credentials; long-lived access keys are flagged as a finding by /corgiro iam-security-review. Configure your IdP helper to write role-session credentials.`

3. The role name in `.Arn` must match the `OperatorRoleName` the StackSet was deployed with, or every AssumeRole will fail `AccessDenied` with no useful message. When the profile carries `azure_default_role_arn`, derive and cross-check it instead of asking:

   ```bash
   aws configure get azure_default_role_arn --profile "$AUTH_PROFILE"
   ```

4. Clamp `sessionDurationSeconds` to 3600 — see [cross-account-defaults.md](cross-account-defaults.md). Warn, do not fail.

### Residual risk (`saml-external`)

Under `identity-center`, **who** may assume the operator role is recorded in AWS as an Identity Center assignment — inspectable and auditable from the AWS side. Under `saml-external`, that decision lives entirely in the external IdP's app-role assignment. The AWS-side trust can only assert the SAML audience, so neither AWS nor Corgiro can see or attest to which humans hold the operator role, nor whether MFA was required to obtain it.

Surface this in setup summaries the same way `readOnlyEnforced: false` is surfaced:

> `RESIDUAL RISK — operator assignment is IdP-side. Corgiro cannot verify who is entitled to the operator role, or that MFA was enforced. Both are governed solely by your IdP's app-role assignment and conditional-access policy. Read-only in member accounts IS still enforced at the IAM layer by CorgiroReadOnlyRole.`

Note the scope of what does **not** change: `readOnlyEnforced` stays `true` on this path. The member-account privilege boundary is `CorgiroReadOnlyRole`, which is unaffected by how the operator authenticated.

## Dispatch on `via`

### via = "sso" — accessMode: identity-center-direct

Use the per-account CLI profile written by `setup-corgiro` (Option A). No AssumeRole, no external ID — the CLI refreshes credentials from the cached SSO token.

```bash
aws <service> <command> --profile <profilePrefix><accountId> --region <region> --output json
```

- Profile missing → roster is stale; re-run `/corgiro setup-corgiro` (Option A) to refresh profiles.
- `aws sts get-caller-identity --profile <profilePrefix><accountId>` returns an auth error → SSO session expired; run `aws sso login --sso-session <sessionName>`.

### via = "assume-role" — accessMode: cross-account-role

Assume `CorgiroReadOnlyRole` from the tooling-account session, gated by the external ID. The tooling-account session is the base profile written by `setup-corgiro` Option B — `corgiro` under `authMethod: identity-center` (Step 5), or `auth.profile` under `authMethod: saml-external`. Invoke it with `--profile <baseProfile>` or `export AWS_PROFILE=<baseProfile>`; the AssumeRole call itself is identical either way. See [cross-account-defaults.md](cross-account-defaults.md) → "Per-Account AssumeRole Pattern" for full detail and the failure table.

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
| `auth_expired`   | SSO token expired → `aws sso login`        | tooling session expired → re-login (see below)    |
| `not_in_scope`   | account no longer assigned to the user     | —                                                 |
| `role_missing`   | —                                          | `CorgiroReadOnlyRole` absent → redeploy StackSet  |
| `trust_mismatch` | —                                          | external ID **or operator role ARN** mismatch → check `config.json` and the StackSet's `OperatorRoleName` |
| `suspended`      | account suspended                          | account suspended                                 |
| `management`     | —                                          | management account (use local creds for org APIs) |

The re-login command for `auth_expired` depends on `authMethod`: `aws sso login --sso-session <sessionName>` for `identity-center`, or `auth.loginCommand` for `saml-external`. Report the one matching the operator's config — never both.

Under `saml-external`, `trust_mismatch` has a second cause beyond the external ID: the operator role ARN not matching the `OperatorRoleName` the StackSet was deployed with. Both produce an identical `AccessDenied` on AssumeRole, so check the operator role ARN as well before concluding the external ID is wrong.
