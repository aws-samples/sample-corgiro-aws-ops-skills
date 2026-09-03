---
name: setup-corgiro
description: "One-time setup for Corgiro multi-account access. Two paths: (A) use your existing IAM Identity Center access — fast, no org changes; or (B) provision org-wide cross-account access — deploys CorgiroReadOnlyRole via StackSet, with either IAM Identity Center or an external SAML IdP (Azure AD/Entra, Okta, aws-azure-login) as the operator's entry point. Both save state to ~/.corgiro/. Use for first-time setup, onboarding an operator, configuring multi-account access, switching access modes, or setting up Corgiro without IAM Identity Center."
user-invocable: true
---

# Corgiro Setup (One-Time)

Prepares Corgiro to operate across multiple AWS accounts and saves the result to `~/.corgiro/`. Choose the path that matches the access you have.

| Path                                               | Choose when…                                                                                          | What it does                                                            | Org changes                             | Coverage                       |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | --------------------------------------- | ------------------------------ |
| **A — Existing access** (`identity-center-direct`) | You already sign in via IAM Identity Center and just want Corgiro to use the accounts you're assigned | Discovers your assigned accounts/roles, writes per-account CLI profiles | None                                    | Accounts you're assigned       |
| **B — Cross-account setup** (`cross-account-role`) | You administer the org and want full, consistent, read-only coverage of every account                 | Trusted access, delegated admin, deploys `CorgiroReadOnlyRole` org-wide | Yes (needs temporary payer + IdC admin) | Entire org (+ future accounts) |

> **Identity provider.** Path A requires IAM Identity Center. Path B supports either Identity Center or an **external SAML IdP** (Azure AD / Entra ID, Okta, PingFederate, ADFS via `aws-azure-login`, `saml2aws`, `gimme-aws-creds`), recorded as `authMethod` in `config.json`. Path A has no external-IdP variant: it discovers accounts through the Identity Center token APIs, which have no external-IdP equivalent.

## Output (both paths)

`~/.corgiro/config.json`:

```json
{
  "accessMode": "identity-center-direct",
  "authMethod": "identity-center",
  "ssoSession": {
    "sessionName": "corgiro",
    "startUrl": "https://ORG.awsapps.com/start",
    "ssoRegion": "us-east-1"
  },
  "identityCenter": {
    "rolePriority": ["ReadOnlyAccess", "ViewOnlyAccess", "SecurityAudit"],
    "profilePrefix": "corgiro-",
    "discoveredAt": "<iso8601>"
  },
  "auth": null,
  "crossAccount": null
}
```

For path B, `accessMode` is `cross-account-role`, `identityCenter` is `null`, and `crossAccount` carries `toolingAccountId`, `externalId`, `memberRoleName`, and `accountFilter`.

`authMethod` is `identity-center` (default) or `saml-external`; under `saml-external`, `ssoSession` is `null` and `auth` carries `profile`, `loginCommand` and `operatorRoleArn`. A config file with no `authMethod` field is treated as `identity-center`. Full schema and the valid-combination matrix: [`../../references/credential-resolution.md`](../../references/credential-resolution.md#auth-method-dispatch).

`~/.corgiro/state/roster.json` — per-account resolution, written by both paths so downstream modes are access-mode-agnostic. The entry schema is owned by [`../../references/credential-resolution.md`](../../references/credential-resolution.md) → "Roster Entry Schema" — non-normative example:

```json
{
  "111111111111": {
    "name": "prod-app",
    "role": "ReadOnlyAccess",
    "via": "sso",
    "readOnlyEnforced": true,
    "profile": "corgiro-111111111111"
  }
}
```

`via` is `sso` (path A) or `assume-role` (path B). `readOnlyEnforced` indicates whether read-only is guaranteed at the IAM layer: `true` for path B (`CorgiroReadOnlyRole`) and for path A accounts auto-picked with a known read-only role; `false` for path A accounts the operator double-confirmed with a non-read-only role (residual risk, surfaced in Step 3).

`~/.corgiro/state/coverage.json` — reachability snapshot written by the Step 3 validation probe (same format `account-coverage` writes and later refreshes).

## Workflow

### Step 0 — Choose access model

1. If `~/.corgiro/config.json` exists, show the current `accessMode` and offer: reconfigure / switch mode / cancel.
2. Otherwise ask the operator: **A (existing access)** or **B (cross-account setup)**. Do not guess.

### Step 1 — Operator session

- **Option A:** ensure an SSO session exists (`aws configure sso-session`) — default name `corgiro`, but an existing session works; record the chosen name as `ssoSession.sessionName`. Capture `startUrl` and `ssoRegion`, then `aws sso login --sso-session <sessionName>` using your existing Identity Center access.
- **Option B:** ask which identity provider the operator uses, and record it as `authMethod`. Do not guess.

  | Answer                                                          | `authMethod`       |
  | --------------------------------------------------------------- | ------------------ |
  | IAM Identity Center                                             | `identity-center`  |
  | External SAML IdP (Azure AD/Entra, Okta, PingFederate, ADFS)     | `saml-external`    |

  Either way, do **not** log in as the operator here — the operator identity doesn't exist yet. Option B needs **temporary payer (management) access** to provision trusted access, delegated admin, and the StackSet, and only then creates the operator identity and logs in. Go straight to Step 2 → B.
  - Note: the StackSet can be deployed from the management account or a registered delegated admin account - see [StackSet Deployment Mode](references/option-b-cross-account.md#stackset-deployment-mode-decide-upfront).

### Step 2 — Run the chosen path

| Path                        | Read, in order                                                                                                                                                |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **A**                       | [`references/option-a-identity-center.md`](references/option-a-identity-center.md)                                                                             |
| **B**, `identity-center`    | [`references/option-b-cross-account.md`](references/option-b-cross-account.md) — the whole file                                                                |
| **B**, `saml-external`      | [`references/option-b-saml-external.md`](references/option-b-saml-external.md) first (it states the deltas), then [`references/option-b-cross-account.md`](references/option-b-cross-account.md) **Steps 0–3 only**, then back for Steps 4–6 |

> Load only the references your path routes you to, in the order given — not all of them. The `saml-external` path reads two files because Steps 0–3 (trusted access, delegated-admin gate, StackSet deploy) are shared and deliberately single-sourced rather than duplicated.

### Step 3 — Validate access & finalize (common)

1. Confirm `~/.corgiro/config.json` and `~/.corgiro/state/roster.json` were written.
2. **Secure local state.** `config.json` holds the external ID (cross-account trust secret) and tooling account ID. Restrict permissions immediately:
   ```bash
   chmod 700 ~/.corgiro ~/.corgiro/state
   chmod 600 ~/.corgiro/config.json ~/.corgiro/state/*.json
   ```
   The `700` directory mode also protects any state file written later in this flow (e.g. `coverage.json`).
3. **Validate reachability inline** (same probe as `account-coverage` Step 2): for each account in `roster.json`, resolve credentials per [`../../references/credential-resolution.md`](../../references/credential-resolution.md) and run `aws sts get-caller-identity`, up to `maxParallel` (4) at once. Categorize each as reachable or not, then write `~/.corgiro/state/coverage.json`. This makes downstream modes work immediately — no separate validation step is required. (For very large orgs this may take a few minutes.)
4. Print a summary: access mode, accounts in scope, how many are reachable, and where state was saved. List any unreachable accounts with the one-line fix from the credential-resolution failure table.
   - **Residual-risk block.** If any roster entry has `readOnlyEnforced: false`, print a dedicated `RESIDUAL RISK` section listing those accounts and their roles, and state: _"Read-only is NOT enforced at the IAM layer on these accounts. Corgiro cannot prevent a mutating call if its behavior is subverted (e.g. via prompt injection in resource metadata). Recommended: re-run setup and select a read-only permission set for these accounts."_
   - If `accessMode` is `identity-center-direct`, always include a one-line note that this mode provides no IAM enforcement of read-only -- coverage and privilege equal the operator's permission sets.
   - If `authMethod` is `saml-external`, also print the IdP-side entitlement note from [`../../references/credential-resolution.md`](../../references/credential-resolution.md#residual-risk-saml-external): Corgiro cannot verify who is entitled to the operator role or that MFA was enforced, because both live in the external IdP. Read-only in member accounts **is** still IAM-enforced by `CorgiroReadOnlyRole`, so `readOnlyEnforced` stays `true` — do not conflate the two.
5. To re-check access later — or to pick up newly assigned/added accounts — run `/corgiro account-coverage` anytime. It re-probes and refreshes the snapshot.

## Safety

- **Read-only by default.** Only describe/list/get calls during setup unless the operator explicitly approves a mutating step (path B deploys a StackSet — confirm first).
- **Never print** SSO access tokens, the external ID, or any credentials. Reference the cache file by path, not by value.

## Assets

- [`../../assets/corgiro-readonly-role.yaml`](../../assets/corgiro-readonly-role.yaml) — member-account read-only role; used by path B under either `authMethod`.
- [`../../assets/corgiro-operator-role.yaml`](../../assets/corgiro-operator-role.yaml) — tooling-account operator role; used by path B only when `authMethod` is `saml-external`.
