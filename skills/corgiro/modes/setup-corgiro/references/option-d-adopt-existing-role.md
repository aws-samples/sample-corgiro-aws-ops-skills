# Option D — Adopt an Existing Org-Wide Read-Only Role

Configures Corgiro to assume a read-only role **the customer already operates** in every member account, instead of deploying `CorgiroReadOnlyRole`. Same access model as [option-b-cross-account.md](option-b-cross-account.md) — `accessMode: cross-account-role`, org-wide, assumed from a tooling account — but Corgiro deploys no member-account role and creates nothing in accounts it does not own.

Recorded as `roleProvenance: customer-managed` in `config.json`. See [`credential-resolution.md`](../../../references/credential-resolution.md#role-provenance) for the axis.

> **Corgiro never modifies the customer's role.** Not its trust policy, not its attached policies. Every gap this path finds is reported with the change *they* must make through *their* provisioning mechanism. That includes the data-plane denylist: Corgiro passes it as a session policy on every AssumeRole instead, precisely so the shared role is left alone.

## When to prefer this over Option B

Option B deploys a dedicated role and is the better trade in most orgs — it gives consistent coverage, auto-enrolls future accounts, and its trust is narrowed to the operator identity by construction.

Choose Option D when **a new IAM role is itself the blocker**:

| Reason | Why D wins |
| --- | --- |
| An SCP denies `iam:CreateRole`, or role creation needs per-role change approval | Option B cannot deploy at all; D needs no new role |
| Role-count or IAM-surface governance | Reuses an existing, already-reviewed role |
| The customer's read-only role is already the sanctioned path for third-party tooling | Corgiro fits the pattern they already audit |

Choose Option B instead when none of those apply — especially if you land in [trust case (c)](#the-three-trust-cases) below, where D costs an N-account change to a role you own and buys nothing that B does not.

## What you need before starting

| Requirement | Who provides it | Discoverable by Path D? |
| --- | --- | --- |
| The role's name | The customer | **No** — asked in Step 1 |
| A tooling account whose principals the role trusts | The customer | Partly — Step 1 verifies a candidate |
| An operator identity in that tooling account | Identity Center / IdP admin | Verified in Step 5 |
| External ID, if their trust requires one | The customer | Sometimes, Step 2 — falls back to asking |
| Whether the role covers every account | — | Yes, Step 3 and MODE.md Step 3 |
| Payer access | you | Yes, Step 4 — optional |

## Step 1: Identify the role and the tooling account

Ask both; neither is discoverable. Do not guess a role name — a wrong guess is indistinguishable from a trust failure in Step 3.

> 1. "What is the name of the read-only role deployed across your accounts?" → `MEMBER_ROLE_NAME`
> 2. "Which account should Corgiro operate *from*? It must be an account whose principals that role already trusts — often a central tooling, security, or automation account." → `TOOLING_ACCOUNT_ID`

Then determine which trust case you are in, because it decides whether this path costs anything at all.

### The three trust cases

| Case | Their trust policy admits | Cost to adopt |
| --- | --- | --- |
| **(a)** | `arn:aws:iam::<TOOLING_ACCOUNT_ID>:root` — any principal in that account | **Zero.** Nothing to change. This is the case Option D exists for. |
| **(b)** | A specific role/principal ARN in a central account | **One-time.** Make the operator identity *be* that principal, or have them add yours. Single account, single change. |
| **(c)** | Nothing Corgiro can reach | **N accounts.** A trust-policy edit everywhere. See below. |

You normally cannot read the trust policy to classify this — the shipped operator policy grants no `iam:*`, and [`credential-resolution.md`](../../../references/credential-resolution.md) notes AWS returns the same `AccessDenied` for an absent role, a rejecting trust, and a wrong external ID. So **do not try to classify it up front.** Ask the customer which case they believe they are in, then let Step 3 settle it empirically.

## Step 2: Resolve the external ID

Their role may or may not require one. Try in order, and **never echo the value**.

1. **Ask whether their trust has an `sts:ExternalId` condition at all.** If they say no, set `EXTERNAL_ID=null` and continue — this is legitimate under `customer-managed`.
2. **If they say yes, ask for the value.** They own it; there is no Corgiro-side generation step.
3. **If they do not know,** try reading it the way [option-c-join-existing.md](option-c-join-existing.md#step-4-resolve-the-external-id) does — `iam:GetRole` on the role from any profile you hold with IAM read in an org account, tolerating a policy with several statements:

   ```bash
   aws iam get-role --role-name "$MEMBER_ROLE_NAME" --profile <someProfile> \
     --query 'Role.AssumeRolePolicyDocument.Statement[].Condition.StringEquals."sts:ExternalId"' \
     --output text
   ```

   An empty result means no statement carries the condition, which is a *positive* answer: `EXTERNAL_ID=null`. Do not treat it as a failed lookup.

> Unlike Option B, a null here is expected rather than an error. [`credential-resolution.md`](../../../references/credential-resolution.md#external-id-under-customer-managed) defines when a null is legitimate and when it is a hard stop — the distinction is exactly `roleProvenance`, which is why the field exists.

## Step 3: Hard gate — sample three accounts

Prove the whole chain before writing anything. Sign in to the tooling account first (any profile that reaches it; Step 5 settles the permanent one).

Pick **three** randomly-sampled `ACTIVE` accounts — not one:

```bash
aws organizations list-accounts --profile <baseProfile> \
  --query 'Accounts[?Status==`ACTIVE`].Id' --output text
```

For each, attempt the assume exactly as [`credential-resolution.md`](../../../references/credential-resolution.md#via--assume-role--accessmode-cross-account-role) specifies — session policies included, since they are what make the boundary hold:

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::<SAMPLE_ACCOUNT_ID>:role/$MEMBER_ROLE_NAME \
  --role-session-name corgiro-onboard-check \
  --duration-seconds 3600 \
  --policy-arns arn=arn:<partition>:iam::aws:policy/ReadOnlyAccess \
  --policy file://<skillDir>/assets/corgiro-dataplane-deny.json \
  --profile <baseProfile> \
  --query 'AssumedRoleUser.Arn' --output text
  # add --external-id "$EXTERNAL_ID" only when it is not null
```

Interpret the count, not just the first result — this is why three:

| Result | Meaning | Action |
| --- | --- | --- |
| **3 / 3** | Trust case (a) or (b). Adoption works. | Continue to Step 4 |
| **1–2 / 3** | The role is reachable but **not deployed org-wide**. A coverage gap, *not* a config error. | Continue, and flag it. MODE.md Step 3's full probe will enumerate exactly which accounts lack it. Do not re-ask for the role name. |
| **0 / 3** | Config-level. | **Hard stop** — present all four causes below |

**Hard stop message at 0/3** — present every cause; AWS gives you no way to tell them apart:

> AssumeRole failed on all three sampled accounts. Any of these could be the cause:
>
> 1. The role is not named `<MEMBER_ROLE_NAME>` — confirm the exact name.
> 2. The role's trust does not admit your operator principal (trust case (c) — see below).
> 3. The external ID is wrong, or one is required and you passed none (or vice versa).
> 4. The role genuinely does not exist in these accounts.

### Trust case (c): what to send them

If the customer confirms their trust admits nothing in your tooling account, Corgiro stops here. Emit the statement their pipeline must add, and be honest about the cost:

> **HARD STOP — the role's trust does not admit Corgiro.**
>
> Add this statement to `<MEMBER_ROLE_NAME>`'s trust policy in each account, through your own provisioning mechanism:
>
> ```json
> {
>   "Effect": "Allow",
>   "Principal": { "AWS": "arn:aws:iam::<TOOLING_ACCOUNT_ID>:root" },
>   "Action": "sts:AssumeRole",
>   "Condition": {
>     "ArnLike": { "aws:PrincipalArn": "<OPERATOR_PRINCIPAL_ARN>" }
>   }
> }
> ```
>
> Keep the `ArnLike` condition. The root principal alone would trust *every* identity in the tooling account; the condition is what narrows it to Corgiro's operator.
>
> **This is an N-account change to a role you own.** [Option B](option-b-cross-account.md) deploys a purpose-built role for comparable effort, with its trust narrowed correctly from the start. Prefer Option D here **only** if creating a new IAM role is itself blocked — an SCP denying `iam:CreateRole`, or per-role change approval.

Corgiro does not offer to apply this. Setup mutates nothing in accounts it does not own.

### Discover the session-duration ceiling

While you have the sample accounts, learn the role's cap — it is free here and saves a failure on every account later. If the 3600-second request above returned

```
ValidationError: The requested DurationSeconds exceeds the MaxSessionDuration set for this role.
```

step down 3600 → 1800 → 900 and record the first value that succeeds as `SESSION_DURATION`. Default to 3600 when it worked. See [`credential-resolution.md`](../../../references/credential-resolution.md#session-duration).

## Step 4: Payer access — optional

Path D does not require payer access. Whether you have it changes only which org-wide services Corgiro can use.

```bash
aws organizations describe-organization --profile <baseProfile> \
  --query 'Organization.MasterAccountId' --output text
```

**If you have payer access** and want org-wide Health, Config, Security Hub, GuardDuty or Access Analyzer, run [option-b-cross-account.md](option-b-cross-account.md) **Steps 1 and 2 only** — trusted access and delegated-admin registration for `TOOLING_ACCOUNT_ID`. These are independent of how the member role got there.

> **Never run option-b Step 3.** That deploys `CorgiroReadOnlyRole`. Skipping it is what makes this Option D.

**If you do not have payer access,** skip both and print the `LIMITED CAPABILITY` block from [option-c-join-existing.md](option-c-join-existing.md#step-7-detect-and-disclose-what-you-cannot-reach). The degradation is identical, with one difference worth checking rather than assuming:

> **Path D may cover the payer where B and C cannot.** Service-managed StackSets skip the management account, so `CorgiroReadOnlyRole` is absent there under Options B and C. A *customer's* provisioning mechanism has no such restriction and often does include the payer. Probe it like any other account before declaring `ri-sp-coverage-analysis` unavailable.

## Step 5: Operator identity and laptop configuration

Reuse [option-b-cross-account.md](option-b-cross-account.md) **Steps 4, 5 and 6**, with one substitution throughout: wherever those steps say `CorgiroReadOnlyRole`, use `$MEMBER_ROLE_NAME`.

Concretely, in option-b Step 4 the operator's permission set (or, under `saml-external`, the `MemberRoleName` parameter of [`../../../assets/corgiro-operator-role.yaml`](../../../assets/corgiro-operator-role.yaml)) must grant:

```
sts:AssumeRole on arn:aws:iam::*:role/<MEMBER_ROLE_NAME>
```

The operator template already parameterises this, so no template change is needed — only the parameter value.

> Under `identity-center`, the permission-set **name** does not have to be `CorgiroOperator`. That default exists only because Corgiro's own StackSet matches `AWSReservedSSO_CorgiroOperator_*` in its trust. The customer's role has its own trust, so what matters is that the resulting principal is one their trust admits — which Step 3 already proved.

## Step 6: Write config and build the roster

```json
{
  "accessMode": "cross-account-role",
  "authMethod": "identity-center",
  "roleProvenance": "customer-managed",
  "ssoSession": { "sessionName": "<sessionName>", "startUrl": "https://ORG.awsapps.com/start", "ssoRegion": "us-east-1" },
  "identityCenter": null,
  "auth": { "profile": "<baseProfile>", "loginCommand": null, "operatorRoleArn": null },
  "sessionDurationSeconds": <SESSION_DURATION>,
  "crossAccount": {
    "toolingAccountId": "<TOOLING_ACCOUNT_ID>",
    "externalId": <EXTERNAL_ID or null>,
    "memberRoleName": "<MEMBER_ROLE_NAME>",
    "accountFilter": { "include": [], "exclude": [] }
  }
}
```

Under `saml-external`, set `ssoSession` to `null` and fill `auth.loginCommand` and `auth.operatorRoleArn`, exactly as [option-b-saml-external.md](option-b-saml-external.md) describes.

Restrict permissions immediately:

```bash
chmod 700 ~/.corgiro ~/.corgiro/state
chmod 600 ~/.corgiro/config.json
```

Then build the roster from the org, applying `accountFilter`, per the authoritative schema in [`credential-resolution.md`](../../../references/credential-resolution.md#roster-entry-schema-authoritative):

- `role: "<MEMBER_ROLE_NAME>"`
- `via: "assume-role"`
- `dataPlaneDenyEnforced: true` — the inline session policy is passed on every call, so this holds regardless of what the customer's role carries
- `readOnlyEnforced` — resolve it per [that reference's table](../../../references/credential-resolution.md#resolving-readonlyenforced). Normally `true`, because the managed `ReadOnlyAccess` session policy makes read-only a property of Corgiro's call rather than of their role. Only if that policy was **rejected** does the role's own configuration become the boundary, at which point run the attestation described there and record the result with a `warning`.

Then return to setup **MODE.md Step 3 (Validate access & finalize)**, which probes every account, writes the coverage snapshot, and prints the summary.

## Adding and removing operators

Additional operators use [Path C](option-c-join-existing.md), which handles `customer-managed` deployments too. They need no payer access and change nothing in AWS.

Removal depends on the trust case:

- **Case (a)** — the trust admits the tooling account root, so revoking the operator's Identity Center assignment or IdP role claim is sufficient. No AWS-side change, same as Option B.
- **Case (b)/(c)** — if the trust names a specific principal and that principal *is* the departing operator, the customer must edit the trust. Corgiro cannot, and should say so plainly rather than implying revocation is always free.

Either way, have them delete `~/.corgiro/`.

## What this path never does

- Deploy or modify any member-account role, including its trust policy
- Attach anything to the customer's role — the denylist travels as a session policy instead
- Create a StackSet, or require `iam:CreateRole` anywhere
- Require payer access
