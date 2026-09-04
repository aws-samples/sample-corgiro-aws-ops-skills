---
name: setup-corgiro
description: "One-time setup for Corgiro multi-account access. Four paths: (A) use your existing IAM Identity Center access — fast, no org changes; (B) provision org-wide cross-account access — deploys CorgiroReadOnlyRole via StackSet, with either IAM Identity Center or an external SAML IdP (Azure AD/Entra, Okta, aws-azure-login) as the operator's entry point; (C) join a cross-account deployment a colleague already provisioned — no payer access needed; or (D) adopt an org-wide read-only role your organization already deploys, creating no new IAM role. All save state to ~/.corgiro/. Use for first-time setup, onboarding an additional operator, configuring multi-account access, switching access modes, reusing an existing read-only or audit role instead of creating one, or setting up Corgiro without IAM Identity Center."
user-invocable: true
---

# Corgiro Setup (One-Time)

Prepares Corgiro to operate across multiple AWS accounts and saves the result to `~/.corgiro/`. Choose the path that matches the access you have.

| Path                                               | Choose when…                                                                                          | What it does                                                            | Org changes                             | Coverage                       |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | --------------------------------------- | ------------------------------ |
| **A — Existing access** (`identity-center-direct`) | You already sign in via IAM Identity Center and just want Corgiro to use the accounts you're assigned | Discovers your assigned accounts/roles, writes per-account CLI profiles | None                                    | Accounts you're assigned       |
| **B — Cross-account setup** (`cross-account-role`) | You administer the org and want full, consistent, read-only coverage of every account                 | Trusted access, delegated admin, deploys `CorgiroReadOnlyRole` org-wide | Yes (needs temporary payer + IdC admin) | Entire org (+ future accounts) |
| **C — Join existing** (`cross-account-role`)       | A colleague already ran path B or D and you're joining as an **additional operator**                  | Discovers the existing deployment, configures this machine only          | None (needs no payer access)            | Entire org, minus the payer    |
| **D — Adopt existing role** (`cross-account-role`) | Your org **already has** an org-wide read-only role, and creating a new one is blocked or unwanted     | Adopts that role; deploys nothing into member accounts                  | None to member accounts (payer optional) | Wherever their role is deployed |

> **Identity provider.** Path A requires IAM Identity Center. Paths B, C and D support either Identity Center or an **external SAML IdP** (Azure AD / Entra ID, Okta, PingFederate, ADFS via `aws-azure-login`, `saml2aws`, `gimme-aws-creds`), recorded as `authMethod` in `config.json`. Path A has no external-IdP variant: it discovers accounts through the Identity Center token APIs, which have no external-IdP equivalent.

> **Path C requires that path B or D already ran.** C attaches to an existing `cross-account-role` deployment; it cannot create one and is not a lighter substitute for B. The only thing C needs from the operator who ran B or D is an Identity Center assignment or an IdP role claim — no payer access, no redeploy. See [`references/option-c-join-existing.md`](references/option-c-join-existing.md).

> **B and D differ only in who owns the member role,** recorded as `roleProvenance`. B deploys `CorgiroReadOnlyRole` (`corgiro-managed`); D adopts a role the customer already operates (`customer-managed`). Everything downstream — the roster, credential dispatch, every mode's API calls — is identical. Prefer B unless creating a new IAM role is itself blocked; see [`references/option-d-adopt-existing-role.md`](references/option-d-adopt-existing-role.md#when-to-prefer-this-over-option-b).

## Output (all paths)

`~/.corgiro/config.json`:

```json
{
  "accessMode": "identity-center-direct",
  "authMethod": "identity-center",
  "roleProvenance": null,
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

For paths B, C and D, `accessMode` is `cross-account-role`, `identityCenter` is `null`, and `crossAccount` carries `toolingAccountId`, `externalId`, `memberRoleName`, and `accountFilter`.

`authMethod` is `identity-center` (default) or `saml-external`; under `saml-external`, `ssoSession` is `null`. A config file with no `authMethod` field is treated as `identity-center`.

`roleProvenance` is `corgiro-managed` (paths B, and C joining a B deployment) or `customer-managed` (path D, and C joining a D deployment), and `null` on path A, which assumes no member role. Under `cross-account-role`, a missing or null value is treated as `corgiro-managed`, so configs written before this field existed keep working unchanged. `externalId` may be `null` only under `customer-managed`. Full schema and the valid-combination matrix: [`../../references/credential-resolution.md`](../../references/credential-resolution.md#role-provenance).

`auth` is populated under **both** auth methods, because it carries `profile` — the base CLI profile every mode operates from. Under `saml-external` it also carries `loginCommand` and `operatorRoleArn`; under `identity-center` those are `null`. A config file with no `auth.profile` is treated as `corgiro`, so configs written before path C existed keep working unchanged. Full schema and the valid-combination matrix: [`../../references/credential-resolution.md`](../../references/credential-resolution.md#auth-method-dispatch).

`~/.corgiro/state/roster.json` — per-account resolution, written by both paths so downstream modes are access-mode-agnostic. The entry schema is owned by [`../../references/credential-resolution.md`](../../references/credential-resolution.md) → "Roster Entry Schema" — non-normative example:

```json
{
  "111111111111": {
    "name": "prod-app",
    "role": "ReadOnlyAccess",
    "via": "sso",
    "readOnlyEnforced": true,
    "dataPlaneDenyEnforced": false,
    "profile": "corgiro-111111111111"
  }
}
```

`via` is `sso` (path A) or `assume-role` (paths B, C and D). `readOnlyEnforced` indicates whether read-only is guaranteed at the IAM layer — `true` on every `assume-role` path, because the managed `ReadOnlyAccess` session policy Corgiro passes makes it a property of the call rather than of the role, and `true` for path A accounts auto-picked with a known read-only role. It is `false` for path A accounts the operator double-confirmed with a non-read-only role, and for `assume-role` accounts where that session policy was rejected and the role's own policies could not be attested. `dataPlaneDenyEnforced` is `true` for every `assume-role` account and `false` on path A. Both are resolved per [`../../references/credential-resolution.md`](../../references/credential-resolution.md#resolving-readonlyenforced); `false` values are residual risk, surfaced in Step 3.

`~/.corgiro/state/coverage.json` — reachability snapshot written by the Step 3 validation probe (same format `account-coverage` writes and later refreshes).

## Workflow

### Step 0 — Choose access model

1. If `~/.corgiro/config.json` exists, show the current `accessMode` and offer: reconfigure / switch mode / cancel.
2. Otherwise ask the operator: **A (existing access)**, **B (cross-account setup)**, **C (join an existing cross-account deployment)**, or **D (adopt an existing org-wide read-only role)**. Do not guess.

   Disambiguate with two questions, in this order. The first separates joining from setting up; the second separates deploying a role from adopting one:

   > 1. "Has anyone already set Corgiro up for this organization?
   >     • Yes, and you're joining as an additional operator → **C**
   >     • No, or you don't know and you administer the org → ask question 2"
   >
   > 2. "Does your organization already have a read-only IAM role deployed across all accounts that Corgiro could use?
   >     • No → **B** (Corgiro deploys `CorgiroReadOnlyRole`)
   >     • Yes, and I'd rather Corgiro used it than created another → **D**
   >     • Yes, but I'm happy for Corgiro to deploy its own → **B**"

   The last branch is deliberate: having a role does not make D the better choice. B's role has its trust narrowed to the operator identity by construction and auto-enrolls future accounts, so B stays the default. D earns its place when a *new* role is blocked — an SCP denying `iam:CreateRole`, or per-role change approval. See [`references/option-d-adopt-existing-role.md`](references/option-d-adopt-existing-role.md#when-to-prefer-this-over-option-b).

   If the operator picks C but nothing turns out to be deployed, path C hard-stops at its Step 1 or Step 5 with the reason; that is the intended failure, not a fallback into B or D.

### Step 1 — Operator session

- **Option A:** ensure an SSO session exists (`aws configure sso-session`) — default name `corgiro`, but an existing session works; record the chosen name as `ssoSession.sessionName`. Capture `startUrl` and `ssoRegion`, then `aws sso login --sso-session <sessionName>` using your existing Identity Center access.
- **Option B:** ask which identity provider the operator uses, and record it as `authMethod`. Do not guess.

  | Answer                                                          | `authMethod`       |
  | --------------------------------------------------------------- | ------------------ |
  | IAM Identity Center                                             | `identity-center`  |
  | External SAML IdP (Azure AD/Entra, Okta, PingFederate, ADFS)     | `saml-external`    |

  Either way, do **not** log in as the operator here — the operator identity doesn't exist yet. Option B needs **temporary payer (management) access** to provision trusted access, delegated admin, and the StackSet, and only then creates the operator identity and logs in. Go straight to Step 2 → B.
  - Note: the StackSet can be deployed from the management account or a registered delegated admin account - see [StackSet Deployment Mode](references/option-b-cross-account.md#stackset-deployment-mode-decide-upfront).

- **Option D:** ask which identity provider the operator uses and record it as `authMethod`, using the same table as Option B. Do not guess.

  Do **not** ask for payer access here. Path D needs none to adopt the role, and treats it as an optional extra at its Step 4 purely for enabling org-wide Health/Config/Security Hub. The operator identity does not exist yet, so do not log in as it either — go straight to Step 2 → D.

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
| **D**, either `authMethod`   | [`references/option-d-adopt-existing-role.md`](references/option-d-adopt-existing-role.md) — the whole file. Its Step 4 optionally sends you to [`references/option-b-cross-account.md`](references/option-b-cross-account.md) **Steps 1–2 only**, and its Step 5 to that file's **Steps 4–6**. Under `saml-external`, also read [`references/option-b-saml-external.md`](references/option-b-saml-external.md) for the operator-role deltas |

> Load only the references your path routes you to, in the order given — not all of them. The `saml-external` path reads two files because Steps 0–3 (trusted access, delegated-admin gate, StackSet deploy) are shared and deliberately single-sourced rather than duplicated. Path C reads one file under either `authMethod`: it deploys nothing, so it shares none of Option B's steps.

> **Path D must never run option-b Step 3.** That step deploys the `CorgiroReadOnlyRole` StackSet; skipping it is the entire point of Path D. D reuses only the payer bootstrap (Steps 1–2, optional) and the operator-identity and laptop steps (4–6).

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
   - **Residual-risk block.** If any roster entry has `readOnlyEnforced: false`, print a dedicated `RESIDUAL RISK` section. Open with the shared consequence — _"Read-only is NOT enforced at the IAM layer on these accounts. Corgiro cannot prevent a mutating call if its behavior is subverted (e.g. via prompt injection in resource metadata)."_ — then give the remediation that matches the cause:

     | Cause | Remediation to print |
     | --- | --- |
     | `via: sso` with a non-read-only permission set (path A) | _"Re-run setup and select a read-only permission set for these accounts."_ |
     | `via: assume-role`, managed session policy rejected, role attested broader than `ReadOnlyAccess` | _"`<memberRoleName>` grants more than read-only in these accounts, and the `ReadOnlyAccess` session policy was rejected, so nothing narrows it. Name the offending policy."_ |
     | `via: assume-role`, managed session policy rejected, role not attestable | _"Read-only in these accounts is asserted by your role's configuration, which Corgiro could not read. It is not verified."_ |

     **Collapse a uniform cause.** When every affected account shares one cause — the normal case on a `customer-managed` deployment — print it **once** as an org-level statement with the account count, and list individual accounts only as *exceptions* where attestation found something specific. A 200-row wall repeating one fact is how this block stops being read. This mirrors the [uniform-failure rule](../../references/credential-resolution.md#uniform-failure-across-all-accounts).
   - **Path C only — effective scope.** Print the effective `accountFilter` and the resulting account count, followed by: _"Scope is per-operator local config. If the operator who onboarded you excluded accounts and you did not, your reports are WIDER than theirs. Compare account counts before trusting a diff."_
   - **Path C only — limited capability.** If the management account probed as unreachable, print the `LIMITED CAPABILITY` block from [`references/option-c-join-existing.md`](references/option-c-join-existing.md#step-7-detect-and-disclose-what-you-cannot-reach), naming the affected modes. Do not present this as an error: it is the expected state for an operator without payer access.
   - **Path D only — coverage is theirs, not Corgiro's.** Print the number of accounts where `<memberRoleName>` was reachable against the org total, followed by: _"Corgiro adopted a role you provision. Accounts where it is absent are a coverage gap in your own deployment, not a Corgiro misconfiguration — and new accounts are covered only if your mechanism enrolls them. Re-run `/corgiro account-coverage` after your next rollout."_ Present a partial result as amber, not red; only a 0-account result indicates config.
   - **Path D only — what Corgiro did not touch.** State once: _"Corgiro deployed nothing into your accounts and did not modify `<memberRoleName>` or its trust policy. The data-plane denylist is applied as a session policy on each AssumeRole, so your role is unchanged and its other consumers are unaffected."_
   - If `accessMode` is `identity-center-direct`, always include a one-line note that this mode provides no IAM enforcement of read-only -- coverage and privilege equal the operator's permission sets.
   - If `authMethod` is `saml-external`, also print the IdP-side entitlement note from [`../../references/credential-resolution.md`](../../references/credential-resolution.md#residual-risk-saml-external): Corgiro cannot verify who is entitled to the operator role or that MFA was enforced, because both live in the external IdP. Read-only in member accounts **is** still IAM-enforced by `CorgiroReadOnlyRole`, so `readOnlyEnforced` stays `true` — do not conflate the two.
5. To re-check access later — or to pick up newly assigned/added accounts — run `/corgiro account-coverage` anytime. It re-probes and refreshes the snapshot.

## Safety

- **Read-only by default.** Only describe/list/get calls during setup unless the operator explicitly approves a mutating step (path B deploys a StackSet — confirm first). Path C mutates nothing in AWS. Path D mutates nothing in member accounts and **never** edits a role it does not own; its only optional mutations are the payer-side trusted-access and delegated-admin registrations, which are confirmed like any other.
- **Never print** SSO access tokens, the external ID, or any credentials. Reference the cache file by path, not by value. This holds in path C too: when the external ID is read from a trust policy, capture it into a variable and write it only to `config.json` — never echo it.
- **Never clobber the operator's AWS config.** Path C runs on a machine with existing working AWS access. Check whether a profile name is taken before writing it, and ask rather than overwrite.

## Assets

- [`../../assets/corgiro-readonly-role.yaml`](../../assets/corgiro-readonly-role.yaml) — member-account read-only role; used by path B under either `authMethod`. Path C reads its trust policy but never deploys it. Path D never touches it.
- [`../../assets/corgiro-operator-role.yaml`](../../assets/corgiro-operator-role.yaml) — tooling-account operator role; used by paths B and D when `authMethod` is `saml-external`. Path D passes its own role name as `MemberRoleName`.
- [`../../assets/corgiro-dataplane-deny.json`](../../assets/corgiro-dataplane-deny.json) — canonical data-plane denylist, passed as an inline session policy on every AssumeRole by all `cross-account-role` paths. Not deployed; read at call time.
