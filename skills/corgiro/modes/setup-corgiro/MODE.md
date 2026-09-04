---
name: setup-corgiro
description: "One-time setup for Corgiro multi-account access. Three paths: (A) use your existing IAM Identity Center access — fast, no org changes; (B) provision org-wide cross-account access — deploys CorgiroReadOnlyRole via StackSet, with either IAM Identity Center or an external SAML IdP (Azure AD/Entra, Okta, aws-azure-login) as the operator's entry point; or (C) join a cross-account deployment a colleague already provisioned — no payer access needed. All save state to ~/.corgiro/. Use for first-time setup, onboarding an additional operator, configuring multi-account access, switching access modes, or setting up Corgiro without IAM Identity Center."
user-invocable: true
---

# Corgiro Setup (One-Time)

Prepares Corgiro to operate across multiple AWS accounts and saves the result to `~/.corgiro/`. Choose the path that matches the access you have.

| Path                                               | Choose when…                                                                                          | What it does                                                            | Org changes                             | Coverage                       |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | --------------------------------------- | ------------------------------ |
| **A — Existing access** (`identity-center-direct`) | You already sign in via IAM Identity Center and just want Corgiro to use the accounts you're assigned | Discovers your assigned accounts/roles, writes per-account CLI profiles | None                                    | Accounts you're assigned       |
| **B — Cross-account setup** (`cross-account-role`) | You administer the org and want full, consistent, read-only coverage of every account                 | Trusted access, delegated admin, deploys `CorgiroReadOnlyRole` org-wide | Yes (needs temporary payer + IdC admin) | Entire org (+ future accounts) |
| **C — Join existing** (`cross-account-role`)       | A colleague already ran path B and you're joining as an **additional operator**                       | Discovers the existing deployment, configures this machine only          | None (needs no payer access)            | Entire org, minus the payer    |

> **Identity provider.** Path A requires IAM Identity Center. Paths B and C support either Identity Center or an **external SAML IdP** (Azure AD / Entra ID, Okta, PingFederate, ADFS via `aws-azure-login`, `saml2aws`, `gimme-aws-creds`), recorded as `authMethod` in `config.json`. Path A has no external-IdP variant: it discovers accounts through the Identity Center token APIs, which have no external-IdP equivalent.

> **Path C requires that path B already ran.** C attaches to an existing `cross-account-role` deployment; it cannot create one and is not a lighter substitute for B. The only thing C needs from the operator who ran B is an Identity Center assignment or an IdP role claim — no payer access, no redeploy. See [`references/option-c-join-existing.md`](references/option-c-join-existing.md).

## Output (all paths)

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

For paths B and C, `accessMode` is `cross-account-role`, `identityCenter` is `null`, and `crossAccount` carries `toolingAccountId`, `externalId`, `memberRoleName`, and `accountFilter`.

`authMethod` is `identity-center` (default) or `saml-external`; under `saml-external`, `ssoSession` is `null`. A config file with no `authMethod` field is treated as `identity-center`.

`auth` is populated under **both** auth methods, because it carries `profile` — the base CLI profile every mode operates from. Under `saml-external` it also carries `loginCommand` and `operatorRoleArn`; under `identity-center` those are `null`. A config file with no `auth.profile` is treated as `corgiro`, so configs written before path C existed keep working unchanged. Full schema and the valid-combination matrix: [`../../references/credential-resolution.md`](../../references/credential-resolution.md#auth-method-dispatch).

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

`via` is `sso` (path A) or `assume-role` (paths B and C). `readOnlyEnforced` indicates whether read-only is guaranteed at the IAM layer: `true` for paths B and C (`CorgiroReadOnlyRole`) and for path A accounts auto-picked with a known read-only role; `false` for path A accounts the operator double-confirmed with a non-read-only role (residual risk, surfaced in Step 3).

`~/.corgiro/state/coverage.json` — reachability snapshot written by the Step 3 validation probe (same format `account-coverage` writes and later refreshes).

## Workflow

### Step 0 — Choose access model

1. If `~/.corgiro/config.json` exists, show the current `accessMode` and offer: reconfigure / switch mode / cancel.
2. Otherwise ask the operator: **A (existing access)**, **B (cross-account setup)**, or **C (join an existing cross-account deployment)**. Do not guess.

   Disambiguate B from C with one question — the answer determines whether payer access is needed at all:

   > "Has anyone already set Corgiro up for this organization — deployed `CorgiroReadOnlyRole` across the accounts?
   >  • No, or you don't know and you administer the org → **B**
   >  • Yes, and you're joining as an additional operator → **C**"

   If the operator picks C but nothing turns out to be deployed, path C hard-stops at its Step 1 or Step 5 with the reason; that is the intended failure, not a fallback into B.

### Step 1 — Operator session

- **Option A:** ensure an SSO session exists (`aws configure sso-session`) — default name `corgiro`, but an existing session works; record the chosen name as `ssoSession.sessionName`. Capture `startUrl` and `ssoRegion`, then `aws sso login --sso-session <sessionName>` using your existing Identity Center access.
- **Option B:** ask which identity provider the operator uses, and record it as `authMethod`. Do not guess.

  | Answer                                                          | `authMethod`       |
  | --------------------------------------------------------------- | ------------------ |
  | IAM Identity Center                                             | `identity-center`  |
  | External SAML IdP (Azure AD/Entra, Okta, PingFederate, ADFS)     | `saml-external`    |

  Either way, do **not** log in as the operator here — the operator identity doesn't exist yet. Option B needs **temporary payer (management) access** to provision trusted access, delegated admin, and the StackSet, and only then creates the operator identity and logs in. Go straight to Step 2 → B.
  - Note: the StackSet can be deployed from the management account or a registered delegated admin account - see [StackSet Deployment Mode](references/option-b-cross-account.md#stackset-deployment-mode-decide-upfront).

- **Option C:** ask which identity provider the operator uses and record it as `authMethod`, using the same table as Option B. Do not guess.

  Unlike Option B, the operator identity **already exists** — a colleague provisioned it — so you do log in here, as that operator. Path C's Step 1 does this and simultaneously discovers the tooling account, so go straight to Step 2 → C rather than logging in twice. Do **not** ask for payer access: path C needs none, and requesting it defeats the point of the path.

### Step 2 — Run the chosen path

| Path                        | Read, in order                                                                                                                                                |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **A**                       | [`references/option-a-identity-center.md`](references/option-a-identity-center.md)                                                                             |
| **B**, `identity-center`    | [`references/option-b-cross-account.md`](references/option-b-cross-account.md) — the whole file                                                                |
| **B**, `saml-external`      | [`references/option-b-saml-external.md`](references/option-b-saml-external.md) first (it states the deltas), then [`references/option-b-cross-account.md`](references/option-b-cross-account.md) **Steps 0–3 only**, then back for Steps 4–6 |
| **C**, `identity-center`    | [`references/option-c-join-existing.md`](references/option-c-join-existing.md) — the whole file                                                                |
| **C**, `saml-external`      | [`references/option-c-join-existing.md`](references/option-c-join-existing.md) — the whole file; each step has an `identity-center` and a `saml-external` branch |

> Load only the references your path routes you to, in the order given — not all of them. The `saml-external` path reads two files because Steps 0–3 (trusted access, delegated-admin gate, StackSet deploy) are shared and deliberately single-sourced rather than duplicated. Path C reads one file under either `authMethod`: it deploys nothing, so it shares none of Option B's steps.

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
   - **Path C only — effective scope.** Print the effective `accountFilter` and the resulting account count, followed by: _"Scope is per-operator local config. If the operator who onboarded you excluded accounts and you did not, your reports are WIDER than theirs. Compare account counts before trusting a diff."_
   - **Path C only — limited capability.** If the management account probed as unreachable, print the `LIMITED CAPABILITY` block from [`references/option-c-join-existing.md`](references/option-c-join-existing.md#step-7-detect-and-disclose-what-you-cannot-reach), naming the affected modes. Do not present this as an error: it is the expected state for an operator without payer access.
   - If `accessMode` is `identity-center-direct`, always include a one-line note that this mode provides no IAM enforcement of read-only -- coverage and privilege equal the operator's permission sets.
   - If `authMethod` is `saml-external`, also print the IdP-side entitlement note from [`../../references/credential-resolution.md`](../../references/credential-resolution.md#residual-risk-saml-external): Corgiro cannot verify who is entitled to the operator role or that MFA was enforced, because both live in the external IdP. Read-only in member accounts **is** still IAM-enforced by `CorgiroReadOnlyRole`, so `readOnlyEnforced` stays `true` — do not conflate the two.
5. To re-check access later — or to pick up newly assigned/added accounts — run `/corgiro account-coverage` anytime. It re-probes and refreshes the snapshot.

## Safety

- **Read-only by default.** Only describe/list/get calls during setup unless the operator explicitly approves a mutating step (path B deploys a StackSet — confirm first). Path C mutates nothing in AWS.
- **Never print** SSO access tokens, the external ID, or any credentials. Reference the cache file by path, not by value. This holds in path C too: when the external ID is read from a trust policy, capture it into a variable and write it only to `config.json` — never echo it.
- **Never clobber the operator's AWS config.** Path C runs on a machine with existing working AWS access. Check whether a profile name is taken before writing it, and ask rather than overwrite.

## Assets

- [`../../assets/corgiro-readonly-role.yaml`](../../assets/corgiro-readonly-role.yaml) — member-account read-only role; used by path B under either `authMethod`. Path C reads its trust policy but never deploys it.
- [`../../assets/corgiro-operator-role.yaml`](../../assets/corgiro-operator-role.yaml) — tooling-account operator role; used by path B only when `authMethod` is `saml-external`.
