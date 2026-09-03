# How Corgiro Accesses Your AWS Accounts

This document is for the person who has to approve Corgiro: it describes exactly what access Corgiro needs, how that access is obtained, what it is bounded by at the IAM layer, and what it cannot do.

Corgiro is an agent skill — a set of Markdown instructions that drive the **AWS CLI v2 already installed on your laptop**. It has no service, no backend, no hosted component, and no credentials of its own. Every API call is made from your workstation, as an identity your organization issued, and every call appears in your CloudTrail attributed to a named operator.

- [The two axes](#the-two-axes)
- [Option A — use existing Identity Center access](#option-a--use-existing-identity-center-access)
- [Option B — org-wide cross-account access](#option-b--org-wide-cross-account-access)
- [Option C — join an existing deployment](#option-c--join-an-existing-deployment)
- [What the read-only boundary actually is](#what-the-read-only-boundary-actually-is)
- [The external ID](#the-external-id)
- [Sessions, throttling, and blast radius](#sessions-throttling-and-blast-radius)
- [Auditability](#auditability)
- [Local state on the laptop](#local-state-on-the-laptop)
- [What Corgiro never does](#what-corgiro-never-does)
- [Revoking access](#revoking-access)

## The two axes

Access is described by two **independent** settings, both recorded in `~/.corgiro/config.json` by `/corgiro setup-corgiro`.

| Axis | Field | Values | Answers |
|---|---|---|---|
| Access model | `accessMode` | `identity-center-direct`, `cross-account-role` | **How each member account is reached** |
| Auth method | `authMethod` | `identity-center` (default), `saml-external` | **How the operator signs in** |

They are orthogonal by design: only the base session differs between auth methods. The account roster schema, the per-account credential dispatch, and every mode's API calls are identical either way — so switching IdPs changes nothing about what Corgiro reads.

Valid combinations:

| | `authMethod: identity-center` | `authMethod: saml-external` |
|---|---|---|
| `accessMode: cross-account-role` | supported | supported |
| `accessMode: identity-center-direct` | supported | **rejected at setup** |

`identity-center-direct` discovers accounts through `aws sso list-accounts` / `list-account-roles`, which require an Identity Center access token. An external IdP exposes the account list only inside the SAML assertion, with no AWS API to enumerate it — so there is nothing to fall back to, and setup hard-stops rather than half-working.

The three setup paths map onto these axes:

| Path | `accessMode` | Org changes | Payer access needed | Coverage |
|---|---|---|---|---|
| **A** — existing access | `identity-center-direct` | None | No | Only accounts you are assigned |
| **B** — cross-account setup | `cross-account-role` | Yes, once | Yes, temporarily | Entire org, plus future accounts |
| **C** — join existing | `cross-account-role` | None | No | Entire org, minus the payer |

## Option A — use existing Identity Center access

Corgiro uses the accounts and permission sets you are **already assigned**. Nothing is deployed, no organization setting is touched, and no new IAM principal is created.

```mermaid
flowchart LR
    OP(["Operator"]) -->|"aws sso login<br/>--sso-session corgiro"| IDC["IAM Identity Center"]
    IDC -->|"sso:list-accounts<br/>sso:list-account-roles"| DISC["Discovered assignments"]
    DISC -->|"writes one profile per account<br/>into ~/.aws/config"| P1["profile corgiro-111111111111"]
    DISC --> P2["profile corgiro-222222222222"]
    P1 -->|"existing permission set"| A1["Account 111111111111"]
    P2 -->|"existing permission set"| A2["Account 222222222222"]
```

Setup discovers your assignments, picks one role per account by priority (`ReadOnlyAccess` > `ViewOnlyAccess` > `SecurityAudit`), and writes a `corgiro-<accountId>` CLI profile for each. The AWS CLI refreshes credentials from the cached SSO token natively — Corgiro handles no credential material itself.

> **Read-only is behavioral on this path, not IAM-enforced.** Corgiro operates with whatever permission set you already hold. If that set can write, nothing at the IAM layer stops a mutating call; the skill's own instructions and prompt-injection defenses are the only barrier. Run Option A with a read-only permission set.
>
> An account with **no** known read-only role is a **hard stop**, not a warning: the default action is to skip the account, and proceeding requires explicit double-confirmation (choose the role, then type the account ID). Any account accepted that way is recorded `readOnlyEnforced: false` and listed as residual risk in every setup summary.

Coverage equals your assignments, so newly added org accounts do not appear until Identity Center assigns them to you. Org-wide APIs — `health ... -for-organization`, for instance — need management or delegated-admin access and generally do not work on this path.

## Option B — org-wide cross-account access

This is the path that gives consistent, **IAM-enforced** read-only coverage of every account, including accounts created later. It is the heavier path: a one-time deploy that needs temporary payer access.

Three pieces are provisioned:

1. **`CorgiroReadOnlyRole`** in every member account, via a service-managed CloudFormation StackSet targeting the root OU, with auto-deployment on.
2. **A tooling account** as the single pivot — home to the `CorgiroOperator` identity, and a delegated administrator for Health, Config, Security Hub, GuardDuty, Access Analyzer, and Resource Explorer.
3. **An operator identity** in that tooling account: either a `CorgiroOperator` Identity Center permission set, or an IAM role reached through your external SAML IdP.

### Architecture

```mermaid
flowchart TB
    subgraph IDP["① Identity provider — one of these"]
        direction LR
        IDC["IAM Identity Center<br/>CorgiroOperator permission set<br/>authMethod: identity-center"]
        SAML["External SAML IdP<br/>Entra ID / Okta / Ping / ADFS<br/>authMethod: saml-external"]
    end

    subgraph LAPTOP["② Operator laptop — the only compute Corgiro runs on"]
        direction LR
        CLI["AWS CLI v2<br/>driven by the Corgiro skill"]
        CFG[("~/.corgiro/config.json<br/>toolingAccountId, externalId<br/>mode 600")]
    end

    subgraph TOOL["③ Tooling account — the single pivot"]
        OPROLE["CorgiroOperator<br/>sts:AssumeRole on */CorgiroReadOnlyRole<br/>+ org and delegated-admin reads<br/>no ReadOnlyAccess of its own"]
    end

    subgraph MEMBERS["④ Every member account in the root OU — including accounts created later"]
        M1["CorgiroReadOnlyRole<br/>ReadOnlyAccess + DataPlaneDeny explicit Deny<br/>trust: ArnLike on the operator principal + ExternalId"]
    end

    subgraph PAYER["Setup only — management / payer account"]
        direction LR
        TRUST["Trusted access + delegated admin<br/>health, config, securityhub,<br/>guardduty, access-analyzer"]
        SS["Service-managed StackSet<br/>auto-deployment: Enabled"]
    end

    IDC --> CLI
    SAML --> CLI
    CLI --- CFG
    CLI ==>|"base profile: auth.profile"| OPROLE
    OPROLE ==>|"sts:AssumeRole + ExternalId<br/>1 h session, ≤10 in parallel"| MEMBERS
    SS -.->|"one-time deploy to root OU"| MEMBERS
    TRUST -.->|"delegates org-wide read APIs"| OPROLE
```

Read the diagram in two passes. The **dotted edges** are the one-time setup: the payer activates trusted access, registers the tooling account as delegated admin, and deploys the StackSet. The **solid edges** ①→②→③→④ are what happens on every run: the operator signs in, the CLI resolves the tooling-account base profile, and Corgiro chains from there into each member account.

Note what is *not* on the diagram. The payer appears only in the setup pass — after setup, Corgiro never signs in to it. The tooling account holds no `ReadOnlyAccess` of its own; its only real power is the cross-account hop. And because service-managed StackSets skip the management account, `CorgiroReadOnlyRole` does not exist there by default.

The StackSet deploys to `us-east-1` only, because IAM is a global service — one stack instance per account creates a role usable in every region.

### What one run looks like

```mermaid
sequenceDiagram
    autonumber
    actor OP as Operator
    participant SK as Corgiro skill
    participant STS as STS
    participant TOOL as Tooling account
    participant MEM as Member account N

    OP->>SK: /corgiro rds-eol-analysis
    SK->>SK: read ~/.corgiro/config.json + state/roster.json
    SK->>SK: pre-flight: chmod 700/600, session freshness
    SK->>STS: get-caller-identity --profile auth.profile
    STS-->>SK: assumed-role ARN in tooling account
    Note over SK: hard gate — account must equal toolingAccountId,<br/>ARN must be a role session, not an IAM user
    SK->>SK: derive operator id for the session name

    loop each roster account, up to maxParallel workers
        SK->>STS: AssumeRole CorgiroReadOnlyRole<br/>+ ExternalId, 3600s,<br/>session corgiro-OPERATOR-RUNID
        STS-->>SK: temporary credentials, in memory only
        SK->>MEM: describe / list / get calls only
        MEM-->>SK: resource metadata
        SK->>SK: persist per-account JSON, then discard creds
    end

    SK->>SK: aggregate, sanitize metadata, render report
    SK-->>OP: Report-DATE.html + Report-DATE.md
```

The pre-flight gate matters more than it looks. Corgiro verifies that the base profile actually resolves to a **role session in the expected tooling account** before touching any member account. A profile that resolves to an IAM user is rejected outright — long-lived access keys are exactly what `/corgiro iam-security-review` flags as a finding.

### The trust policy

`CorgiroReadOnlyRole`'s trust names the tooling account root as principal, then narrows it with an `ArnLike` condition on `aws:PrincipalArn` and a `StringEquals` on `sts:ExternalId`. The root principal alone would trust every identity in the tooling account; the `ArnLike` is what reduces that to the operator identity.

Which principal patterns are emitted depends on two StackSet parameters:

| `PermissionSetNamePrefix` | `OperatorRoleName` | Trusted principals |
|---|---|---|
| `CorgiroOperator` (default) | `""` (default) | Identity Center only — both `AWSReservedSSO_` ARN layouts |
| `CorgiroOperator` | `MyRole` | Both — Identity Center and the named SAML role |
| `""` | `MyRole` | The named SAML role only |
| `""` | `""` | None — the role becomes unassumable, deliberately failing closed |

An org with no Identity Center at all should pass `PermissionSetNamePrefix=""`, so the member role does not carry an inert `AWSReservedSSO_CorgiroOperator_*` pattern that would silently start matching if Identity Center were adopted later and a permission set happened to be named `CorgiroOperator`.

Two consequences worth internalizing:

- **Adding an operator requires no AWS change.** The trust matches a *pattern*, so assigning the existing permission set — or adding someone to the IdP role claim — is sufficient. No StackSet update, no trust-policy edit, no external-ID rotation.
- **Removing an operator likewise requires no AWS change.** Unassign the permission set or drop the role claim, and the pattern stops matching them.

### Where the StackSet is deployed from

The StackSet can be created from the payer, or from a registered StackSets delegated administrator account. The deployer is independent of the role's trust: the template's `ToolingAccountId` parameter decides who can *assume* the role at runtime, while whoever *deploys* is a separate question. In `delegated-admin` mode the payer is needed only once beforehand, to activate organizations access and register the delegated admin.

Scope note: this only moves the `CorgiroReadOnlyRole` deploy off the payer. Enabling the other org-wide services still requires payer access.

### Residual risk under `saml-external`

Under `identity-center`, **who** may hold the operator role is recorded in AWS as an Identity Center assignment — inspectable and auditable from the AWS side. Under `saml-external`, the AWS-side trust can only assert the SAML audience; which humans hold the role, and whether MFA was required, are decided entirely in the external IdP's app-role assignment and conditional-access policy. Neither AWS nor Corgiro can observe or attest to either.

What does **not** change: `readOnlyEnforced` stays `true`. The member-account privilege boundary is `CorgiroReadOnlyRole`, which is unaffected by how the operator authenticated. Corgiro surfaces the entitlement gap in setup summaries rather than letting it pass silently.

## Option C — join an existing deployment

An additional operator joining a deployment someone else provisioned configures **only their own machine**. Nothing is deployed, no organization setting is touched, and no payer access is involved — the trust already matches their principal pattern.

Their IdP admin does exactly one thing, and it is not a Corgiro operation: assign the existing `CorgiroOperator` permission set in the tooling account, or add them to the AWS app's role claim.

Two limits are inherent to this path, and setup detects and states both rather than letting them surface later as a mode failure:

- **The management account is unreachable.** Service-managed StackSets skip the payer, so `CorgiroReadOnlyRole` does not exist there. `ri-sp-coverage-analysis` is therefore unavailable, and `defaultRegions: auto` discovery degrades to a fixed fallback region list, unless the tooling account is a delegated administrator for a billing/cost service. Lifting this means deploying the same template as a standalone stack in the payer — which grants payer read to every operator identity, so weigh it first.
- **Account scope can differ between operators.** `accountFilter` lives only in each operator's local config; AWS holds no record of it, so it cannot be discovered. If the operator who onboarded you excluded accounts and you did not, your reports are *wider* than theirs. Setup prints the effective scope and account count so this is visible when two operators compare output.

## What the read-only boundary actually is

Under `cross-account-role`, the member-account role carries `ReadOnlyAccess` plus a customer-managed policy with an **explicit Deny**. In IAM, an explicit Deny always wins, so the Deny is the real boundary — and it exists because `ReadOnlyAccess` alone permits bulk reads of secrets and customer data.

Denied outright, in every member account:

| Service | Denied actions | What this prevents |
|---|---|---|
| Secrets Manager | `GetSecretValue`, `BatchGetSecretValue` | Reading secret material |
| SSM Parameter Store | `GetParameter(s)`, `GetParametersByPath`, `GetParameterHistory` | Reading SecureString values |
| S3 | `GetObject`, `GetObjectVersion`, `GetObjectTorrent` | Reading object contents |
| DynamoDB | `GetItem`, `BatchGetItem`, `Query`, `Scan`, `PartiQLSelect` | Reading item/record contents |
| KMS | `Decrypt` | Decrypting any retrieved ciphertext |
| EC2 | `GetConsoleOutput`, `GetConsoleScreenshot` | Boot logs and on-screen secrets |
| Lambda | `GetFunction`, `GetFunctionConfiguration` | Plaintext env vars and code-download URLs |
| CloudWatch Logs | `GetLogEvents`, `FilterLogEvents` | Log contents, which routinely hold secrets and PII |
| API Gateway | `GET` | Returned API keys |

Everything Corgiro's modes actually need — the describe/list/get-configuration calls — is preserved. No current mode uses any denied action, and adding a mode that needed one would require a deliberate StackSet update, which is the point: the boundary cannot be widened from the laptop.

`ReadOnlyAccess` is kept as the baseline deliberately, for low maintenance — new read-only modes work without redeploying the StackSet — with the Deny layered on top to remove the sensitive data plane.

The **operator role in the tooling account is separately minimal**: it does *not* carry `ReadOnlyAccess`. Its policy grants the cross-account hop (scoped to `arn:aws:iam::*:role/CorgiroReadOnlyRole`, so it cannot assume arbitrary roles), the Organizations read APIs needed to build the roster, the org-wide Health APIs, delegated-admin reads for Config / Security Hub / GuardDuty / Access Analyzer, Cost Explorer and Savings Plans reads, and Resource Explorer search. All resource inspection happens through the member role, not from the pivot.

### Prompt-injection defense

AWS resource metadata — names, tags, descriptions, user-data, policy documents — is attacker-controlled input. A compromised account could craft a tag that tries to steer the agent. Corgiro treats every string returned by an AWS API as **data, never as instructions**: it does not build CLI commands from metadata, does not pass tag values into subsequent calls, does not follow URLs found in tags, and does not alter its execution flow based on metadata content. Values matching injection patterns are surfaced as findings.

Report rendering truncates each metadata value to 256 characters, HTML-entity-escapes it, and then wraps it — in that order — so a crafted tag cannot inject markup into a report that gets shared onward.

## The external ID

The external ID gates `sts:AssumeRole` into every member role. It is worth being precise about what it does, because it is easy to over-trust.

It is **not a secret in the sense a password is.** It appears in plaintext in `CorgiroReadOnlyRole`'s `AssumeRolePolicyDocument` in every member account, and `iam:GetRole` returns it to any principal with IAM read in that account. Option C onboarding depends on exactly this to configure new operators without payer access.

What it does provide:

- **Confused-deputy protection** — its actual AWS-intended purpose. A third party cannot induce Corgiro to assume a role in an organization you do not operate.
- **A speed bump.** An attacker holding the operator session but not `~/.corgiro/config.json` needs one more step.

What actually bounds access is elsewhere, and is not recoverable by reading a policy: the `ArnLike` condition on `aws:PrincipalArn`, and `ReadOnlyAccess` plus the explicit Deny.

Practical consequences: still never print it, and still keep `config.json` at mode `600` — narrowing who can read a value is worthwhile even when it is not categorically secret. But do **not** treat its exposure as an incident requiring rotation on its own. Losing the external ID does not grant access; losing the operator identity does. Removing an operator therefore needs no rotation.

It is also deliberately kept *out* of the operator's identity policy: pinning it there would publish it to anyone holding `iam:GetPolicyVersion` in the tooling account, for no gain.

## Sessions, throttling, and blast radius

| Control | Value | Why |
|---|---|---|
| Member session duration | 3600 s, hard ceiling | Corgiro always reaches the member role *from a role session* — Identity Center issues an `AWSReservedSSO_*` role session, and an IdP login issues an `AssumeRoleWithSAML` session. Both are **role chaining**, which STS caps at 1 hour regardless of the requested value. Higher configured values are clamped with a warning. |
| Recommended operator session | 1 hour max | Bounds the window in which a stolen session is usable. Configured in Identity Center or your IdP. |
| MFA | Required on the operator sign-in | Without it, token theft is a single-factor attack. Under `saml-external` this is enforced in the IdP and Corgiro cannot attest to it. |
| Parallel workers | default 4, **hard ceiling 10** | Higher operator values are clamped. Combined with backoff, this keeps Corgiro from exhausting member-account API rate limits and disrupting live workloads. For very large orgs, batch accounts rather than raising concurrency. |
| Throttling backoff | exponential, base 1 s, cap 30 s | On `ThrottlingException` / `TooManyRequestsException`. |
| Per-account call budget | optional cap, e.g. 50 per run | Stops early with a "partial — rate-limited" note rather than hammering a throttled account. |
| Failure handling | fail soft, per account | One unreachable account is recorded with its reason and the run continues. Per-account JSON is persisted before aggregation, so partial results survive. |

The template's `MaxSessionDurationSeconds` accepts up to 43200 because the role could also be assumed by a non-chained principal outside Corgiro. That headroom is unreachable through either Corgiro path.

Every run pre-flights the credential state before doing work: it verifies `~/.corgiro/` permissions, checks session expiry (from the SSO token cache under `identity-center`, or the credentials-file expiry key under `saml-external`), and then runs an authoritative `get-caller-identity` probe. The probe matters independently of the timestamps: an expiry only says when a session *would* lapse, not whether it was revoked at the IdP — which would otherwise fail on the first member account, mid-fan-out and mid-report.

## Auditability

Every member-account read is attributed to a specific human. The role session name is `corgiro-<operator>-<run_id>`, where `<operator>` is derived from the tooling-account caller identity (the SSO user, e.g. `jdoe@example.com`), sanitized to STS's permitted character set and truncated to fit the 64-character limit.

In CloudTrail this means an `AssumeRole` event in the tooling account, and every subsequent read in the member account, carries the operator's identity rather than an anonymous shared session. Combined with the deny list, you can answer "who read what, when" from CloudTrail alone.

## Local state on the laptop

```
~/.corgiro/                     # mode 700
├── config.json                 # mode 600 — accessMode, authMethod, tooling account, external ID
└── state/                      # mode 700
    ├── roster.json             # mode 600 — one entry per account, each with a "via" field
    └── coverage.json           # mode 600 — reachability snapshot
```

Permissions are verified and re-applied on **every** run, not just at setup. `config.json` holds the external ID and the account roster; generated reports hold infrastructure detail — treat both as sensitive.

Temporary member-account credentials are held **in memory only**, keyed by account ID, refreshed on `ExpiredToken`, and never written to disk.

Option A additionally writes an `[sso-session]` block and one `[profile corgiro-<accountId>]` entry per account into `~/.aws/config`. Existing profiles are never overwritten: setup checks whether a name is taken and asks rather than clobbering. This matters most on Option C, which by definition runs on a machine that already has working AWS access.

## What Corgiro never does

- **Mutate anything without explicit approval.** Only describe/list/get calls. The two exceptions are announced as mutating steps and require confirmation: the StackSet deploy in Option B, and the operator-role deploy under `saml-external`. Option A and Option C mutate nothing in AWS.
- **Display credentials.** Access keys, secret keys, session tokens, SSO access tokens, and the external ID are never printed. Cache files are referenced by path, not by value.
- **Persist member-account credentials.** In-memory only.
- **Act on resource metadata.** Tags, names, and descriptions are reported, never executed.
- **Guess lifecycle dates.** End-of-support analyses scrape current dates from AWS documentation and stop rather than answer from model memory.
- **Select an SSO token cache file by modification time.** A laptop commonly holds tokens for several unrelated sessions; picking the newest can read a *different* session's expiry and report a healthy Corgiro session when Corgiro's own token has expired — a silent false pass on a security control. The cache file is derived from `sha1(sessionName)`, falling back to a `startUrl` match.

## Revoking access

| Path | To revoke |
|---|---|
| A — existing access | Unassign the permission set in Identity Center. Corgiro had no dedicated identity to remove. |
| B / C — `identity-center` | Unassign the `CorgiroOperator` permission set from the user or group in the tooling account. |
| B / C — `saml-external` | Remove them from the AWS app's role claim in the IdP. |

In all cases nothing on the AWS side changes: no StackSet update, no trust-policy edit, no external-ID rotation. The trust matches a principal *pattern*, and that pattern is unchanged when one person loses the identity matching it.

To remove Corgiro from the organization entirely, delete the StackSet instances and the StackSet — which removes `CorgiroReadOnlyRole` from every member account — then deregister the delegated administrators and deactivate trusted access if nothing else uses them. Have each operator delete `~/.corgiro/`.

---

For the wider picture of what Corgiro does with this access, see [what-is-corgiro.md](what-is-corgiro.md). The authoritative, executable detail lives in the skill itself: [`credential-resolution.md`](../skills/corgiro/references/credential-resolution.md), [`cross-account-defaults.md`](../skills/corgiro/references/cross-account-defaults.md), the [`setup-corgiro` mode](../skills/corgiro/modes/setup-corgiro/), and the CloudFormation templates under [`assets/`](../skills/corgiro/assets/).
