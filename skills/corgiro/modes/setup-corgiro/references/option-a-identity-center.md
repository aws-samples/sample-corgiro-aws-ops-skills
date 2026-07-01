# Option A — Existing Identity Center Access

Uses the accounts and permission sets the operator is **already assigned** in IAM Identity Center. No org changes. Assumes Step 1 (SSO login) of MODE.md is done.

> ⚠️ **No IAM enforcement of read-only.** This path uses whatever permission set you already have, so Corgiro's read-only posture is **behavioral only** -- coverage equals whatever your permission set allows. If that set can write or administer (e.g. `AdministratorAccess`), nothing at the IAM layer stops a mutating call; the prompt-injection defenses in SKILL.md become the only barrier. **Run Option A with a read-only permission set** (`ReadOnlyAccess` / `ViewOnlyAccess` / `SecurityAudit`) for actual enforcement. If you need read-only guaranteed at the IAM layer, use Option B (cross-account role) instead.

## A1: Locate the cached access token

`aws sso login` caches a token under `~/.aws/sso/cache/`. Find the file for this session (`sha1(sessionName).json`) or, as a fallback, the newest `*.json` containing a non-expired `accessToken`. Parse the JSON directly (no extra tooling required); if `jq` is available this one-liner works:

```bash
TOKEN=$(jq -r 'select(.accessToken) | .accessToken' ~/.aws/sso/cache/*.json | head -1)
```

The token is a short-lived secret. **Never print it.** If no valid token is found, tell the operator to re-run `aws sso login --sso-session corgiro`.

## A2: List assigned accounts

```bash
aws sso list-accounts --access-token "$TOKEN" --region <ssoRegion> --output json
```

The CLI auto-paginates. Capture `accountId` and `accountName` for each.

## A3: List roles per account

For each account (parallel up to 4, back off on `TooManyRequestsException`):

```bash
aws sso list-account-roles --access-token "$TOKEN" --account-id <id> --region <ssoRegion> --output json
```

## A4: Pick one role per account

`rolePriority = ["ReadOnlyAccess", "ViewOnlyAccess", "SecurityAudit"]` (from config; overridable).

```
candidates = roles ∩ rolePriority, ordered by rolePriority
if candidates non-empty   → auto-pick candidates[0]   (no prompt; role is a known read-only role)
else                      → HARD STOP for this account -- no known read-only role available
```

**No known read-only role is a hard stop, not a warning.** Corgiro cannot enforce the role's privilege on this path, so it must not silently operate with a role that may have write/admin access. When the hard stop triggers:

1. Show the operator: the account id + name, the role name(s) available, and this residual-risk warning: _"This role is not a known read-only role. Corgiro cannot enforce read-only at the IAM layer here; if the role has write/admin privileges, attacker-controlled resource metadata (tags, names, user-data) could be leveraged to trigger a mutating call. Recommended: use a read-only permission set instead."_
2. **Default action = SKIP this account** (do not add it to the roster).
3. To proceed anyway, require **explicit double-confirmation**:
   - if more than one role is available, the operator must first choose which role to use, AND
   - the operator must type the **account id** to acknowledge "no IAM read-only enforcement on this account".
     Any other / empty / declined input → skip the account.
4. Mark every account accepted this way `readOnlyEnforced: false` in the roster (see A6). Auto-picked priority-role accounts are `readOnlyEnforced: true`. Step 3's summary surfaces all `readOnlyEnforced: false` accounts as residual risk.

## A5: Write per-account CLI profiles

> Heads-up: this adds a `[sso-session corgiro]` block and one `[profile corgiro-<accountId>]` entry per account to the operator's `~/.aws/config`. Existing profiles are left untouched — tell the operator before writing.

Write the SSO session block once, then one profile per account into `~/.aws/config`:

```ini
[sso-session corgiro]
sso_start_url = https://ORG.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile corgiro-111111111111]
sso_session = corgiro
sso_account_id = 111111111111
sso_role_name = ReadOnlyAccess
region = us-east-1
output = json
```

This leverages the CLI's native SSO credential refresh — no custom credential handling. Downstream modes select an account with `--profile corgiro-<accountId>`.

## A6: Save Corgiro config + roster

- `~/.corgiro/config.json` → `accessMode: "identity-center-direct"`, `ssoSession`, `identityCenter.rolePriority`, `discoveredAt`.
- `~/.corgiro/state/roster.json` → one entry per account: `{ "name", "role", "via": "sso", "readOnlyEnforced": <true|false> }`. `readOnlyEnforced` is `true` for auto-picked known read-only roles, `false` for accounts the operator double-confirmed in A4 with a non-read-only role.

After writing, lock down the directory and files: `chmod 700 ~/.corgiro ~/.corgiro/state` and `chmod 600 ~/.corgiro/config.json ~/.corgiro/state/*.json`. Setup Step 3 re-applies this after the coverage snapshot is written.

## A7: Smoke test

```bash
aws sts get-caller-identity --profile corgiro-<one-account-id>
```

Confirm it returns the expected account and assumed role. Then return to setup **Step 3**, which validates reachability across all accounts and writes the coverage snapshot.

## Notes & limits

- **Read-only is behavioral, not IAM-enforced** on this path (see the callout at the top). Accounts accepted in A4 without a known read-only role are recorded `readOnlyEnforced: false` and flagged as residual risk in the Step 3 summary. For IAM-enforced read-only, use Option B.
- Coverage = only the accounts you're assigned. New org accounts won't appear until Identity Center assigns them to you — re-run this path to refresh.
- Org-wide APIs (e.g. `health ... -for-organization`) need management or delegated-admin access and generally won't work on this path unless you're assigned such an account. Modes that require org-wide scope should declare it and skip or fall back.
