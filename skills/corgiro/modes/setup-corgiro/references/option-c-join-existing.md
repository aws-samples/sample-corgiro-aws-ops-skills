# Option C — Join an Existing Cross-Account Deployment

Configures **this machine** against a `cross-account-role` deployment that someone else already provisioned. Same access model as [option-b-cross-account.md](option-b-cross-account.md) — org-wide `CorgiroReadOnlyRole` assumed from a tooling account — but nothing is deployed and no organization setting is touched.

Use this when a colleague has already run Option B and you are joining as an **additional operator**.

> **No payer access, no org changes, no redeploy.** `CorgiroReadOnlyRole`'s trust matches a principal _pattern_ — `AWSReservedSSO_<PermissionSetName>_*` under `identity-center`, or a named role under `saml-external` (see [`../../../assets/corgiro-readonly-role.yaml`](../../../assets/corgiro-readonly-role.yaml)). Any operator holding that principal is already trusted. Adding you requires no StackSet update and no trust-policy edit.

## What you need before starting

| Requirement                                                                    | Who provides it              | Discoverable by Path C?                            |
| ------------------------------------------------------------------------------ | ---------------------------- | -------------------------------------------------- |
| The `CorgiroOperator` identity assigned to you                                  | Identity Center / IdP admin  | Verified in Step 1 — **hard stop** if missing       |
| Tooling account ID                                                              | —                            | Yes, Step 1                                         |
| `authMethod`                                                                    | you (asked in MODE.md Step 1) | —                                                  |
| Member role name                                                                | —                            | Yes, defaulted then proven in Step 5                |
| External ID                                                                     | —                            | Usually, Step 4 — falls back to asking you          |
| Account scope (`accountFilter`)                                                 | operator who set Corgiro up  | **No** — see Step 6                                 |

Your IdP admin needs to do exactly one thing, and it is not a Corgiro operation:

- **`identity-center`** — assign the existing `CorgiroOperator` permission set to you (or your group) in the tooling account.
- **`saml-external`** — add you to the AWS app's role claim for the existing operator role in the IdP.

## Step 1: Find your operator identity

This step both locates the tooling account and proves your identity was granted. Run the branch matching your `authMethod`.

### `identity-center`

Register a session and sign in first. **Reuse an existing `sso-session` if you already have one** — a Path C operator usually already signs in to this Identity Center for other work, and Step 4 tier 2 may need that other access anyway:

```bash
grep '^\[sso-session' ~/.aws/config          # reuse one of these if present
aws configure sso-session                    # only if none exists (default name: corgiro)
aws sso login --sso-session <sessionName>
```

Then enumerate what you are assigned and find the account offering the operator permission set. This reuses the token pattern from [option-a-identity-center.md](option-a-identity-center.md):

```bash
TOKEN=$(jq -r 'select(.accessToken) | .accessToken' ~/.aws/sso/cache/*.json | head -1)

aws sso list-accounts --access-token "$TOKEN" --region <ssoRegion> \
  --query 'accountList[].accountId' --output text

# For each account returned:
aws sso list-account-roles --access-token "$TOKEN" --account-id <id> --region <ssoRegion> \
  --query "roleList[?roleName=='CorgiroOperator'].roleName" --output text
```

| Result                | Meaning                                                                    |
| --------------------- | -------------------------------------------------------------------------- |
| Exactly one match     | That account is `TOOLING_ACCOUNT_ID`; the grant is confirmed. Continue.     |
| More than one match    | Ask the operator which tooling account to use. Do not guess.                |
| No match              | **Hard stop** — see below.                                                  |

If no account offers `CorgiroOperator`, the permission set may exist under a different name. Show the operator the role names `list-account-roles` returned and ask whether one of them is Corgiro's operator permission set before concluding it is unassigned.

**Hard stop message** (fill in what you know, then stop — do not continue to Step 2):

> No `CorgiroOperator` permission set is assigned to you, so Corgiro cannot reach the tooling account. Send this to whoever set Corgiro up:
>
> _"Please assign the existing `CorgiroOperator` permission set to me in the Corgiro tooling account. No StackSet, trust-policy or external-ID change is needed — `CorgiroReadOnlyRole` trusts `AWSReservedSSO_CorgiroOperator_*` by pattern, so an assignment is sufficient."_
>
> Then re-run `/corgiro setup-corgiro` and choose Path C again.

### `saml-external`

Log in with your IdP helper, then verify all three preconditions from [`credential-resolution.md`](../../../references/credential-resolution.md#preconditions-for-saml-external). The caller ARN gives you both the tooling account and the operator role name:

```bash
aws-azure-login --profile <yourProfile>          # or saml2aws / gimme-aws-creds
aws sts get-caller-identity --profile <yourProfile> --output json
```

`.Account` is `TOOLING_ACCOUNT_ID`; the role name in `.Arn` is `OPERATOR_ROLE_NAME`. An `arn:aws:iam::…:user/` ARN is a hard stop (long-lived access keys, not a federated session).

**Hard stop message** when the helper cannot obtain a session for the operator role:

> Your IdP does not offer the Corgiro operator role. Send this to whoever set Corgiro up:
>
> _"Please add me to the AWS app's role claim for the Corgiro operator role in the IdP. No AWS-side change is needed — the role's trust admits any principal federated through the SAML provider."_

## Step 2: Configure `~/.aws/config` — without clobbering anything

You are configuring a machine that already has working AWS access. **Never overwrite an existing profile.**

Check the base profile name before writing it:

```bash
aws configure get sso_account_id --profile corgiro 2>/dev/null
```

| Result                              | Action                                                                   |
| ----------------------------------- | ------------------------------------------------------------------------ |
| Empty / profile absent              | Safe. Write `[profile corgiro]`.                                          |
| Already equals `TOOLING_ACCOUNT_ID` | Already configured for Corgiro. Reuse it as-is.                            |
| Some other account                  | **Ask** — offer overwrite, or a different name such as `corgiro-ops`.      |

Under `identity-center`, the profile references the session you reused or created in Step 1:

```ini
[profile corgiro]
sso_session = <sessionName>
sso_account_id = <TOOLING_ACCOUNT_ID>
sso_role_name = CorgiroOperator
region = us-east-1
output = json
```

Under `saml-external`, your helper already writes the profile; just record its name.

> Whatever name you settle on is the **base identity every mode operates from**, and it is recorded as `auth.profile` in `config.json` (Step 5). Do not assume it is literally `corgiro` — see [`credential-resolution.md`](../../../references/credential-resolution.md#via--assume-role--accessmode-cross-account-role).

## Step 3: Resolve the member role name

Start from the shared default and let Step 5's hard gate prove it:

```
MEMBER_ROLE_NAME=CorgiroReadOnlyRole        # default, per cross-account-defaults.md
```

The role name cannot be read from AWS with an operator-only identity, so it is not discovered — it is assumed and then verified. If Step 5 fails, you will be asked for the real name there. The usual reason for a different name is the collision-avoidance rename in [option-b-cross-account.md](option-b-cross-account.md#step-25-check-for-an-existing-corgiro-deployment).

Resolve this **before** Step 4 — tier 1 needs the role name to look the role up.

## Step 4: Resolve the external ID

The external ID appears in plaintext in `CorgiroReadOnlyRole`'s trust policy and is returned by `iam:GetRole` to any principal with IAM read in that account. Path C uses that to onboard you without payer access. Read [`credential-resolution.md`](../../../references/credential-resolution.md#what-the-external-id-does-and-does-not-protect) for what this control actually provides.

Try the tiers in order and stop at the first that succeeds. **Never echo the value** — capture it into a variable and write it only to `config.json`.

### Tier 1 — the tooling account's own copy of the role (no input needed)

The StackSet targets the whole root OU, and the tooling account is itself an org member, so it normally carries its own copy of `CorgiroReadOnlyRole`:

```bash
EXTERNAL_ID=$(aws iam get-role --role-name "$MEMBER_ROLE_NAME" --profile <baseProfile> \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals."sts:ExternalId"' \
  --output text 2>/dev/null)
```

| Result        | Meaning                                                                                             |
| ------------- | --------------------------------------------------------------------------------------------------- |
| A value       | Done. Continue to Step 5.                                                                            |
| `AccessDenied` | Expected on a stock deployment — the shipped operator policy grants no `iam:*`. Fall through to tier 2. |
| `NoSuchEntity` | The tooling account is outside the StackSet's deployment scope. Fall through to tier 2.               |

> **One-line upgrade for zero-prompt onboarding.** Tier 1 is denied by default because neither [`../../../assets/corgiro-operator-role.yaml`](../../../assets/corgiro-operator-role.yaml) nor the permission set in [option-b-cross-account.md](option-b-cross-account.md#step-4-create-corgirooperator-permission-set-console) grants IAM read. Whoever administers the tooling account can add this once, after which every future operator onboards with no prompts at all:
>
> ```yaml
> - Sid: ReadOwnMemberRoleTrust
>   Effect: Allow
>   Action: iam:GetRole
>   Resource: arn:aws:iam::<TOOLING_ACCOUNT_ID>:role/CorgiroReadOnlyRole
> ```
>
> Scoped to one role in one account, so it grants no other IAM visibility.

### Tier 2 — another profile you already hold

If you have read access to any account in this org outside Corgiro (a day-job permission set, for instance), the role's trust policy is readable there. Ask the operator for a profile name rather than guessing:

> "Do you have AWS read access to any account in this organization **outside** of Corgiro? If so, which profile? I need one `iam:GetRole` call to read the external ID out of `CorgiroReadOnlyRole`'s trust policy."

```bash
aws sts get-caller-identity --profile <otherProfile> --query Account --output text
aws iam get-role --role-name "$MEMBER_ROLE_NAME" --profile <otherProfile> \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals."sts:ExternalId"' \
  --output text
```

`NoSuchEntity` means that account has no Corgiro role — try another profile if they have one. `AccessDenied` means the profile lacks `iam:GetRole` there. Either way, fall through to tier 3.

### Tier 3 — ask

> "I could not read the external ID from any trust policy. Please get it from the operator who set Corgiro up — they generated it during setup and should hold it in a password manager. Paste it here; it is never echoed and is written only to `~/.corgiro/config.json` at mode `600`."

## Step 5: Write config, then prove it (hard gate)

Write `~/.corgiro/config.json`. Note `auth` is populated under **both** auth methods — it carries the base profile name:

```json
{
  "accessMode": "cross-account-role",
  "authMethod": "identity-center",
  "ssoSession": {
    "sessionName": "<sessionName>",
    "startUrl": "https://ORG.awsapps.com/start",
    "ssoRegion": "us-east-1"
  },
  "identityCenter": null,
  "auth": {
    "profile": "<baseProfile>",
    "loginCommand": null,
    "operatorRoleArn": null
  },
  "crossAccount": {
    "toolingAccountId": "<TOOLING_ACCOUNT_ID>",
    "externalId": "<EXTERNAL_ID>",
    "memberRoleName": "<MEMBER_ROLE_NAME>",
    "accountFilter": { "include": [], "exclude": [] }
  }
}
```

Under `saml-external`, set `ssoSession` to `null` and fill `auth.loginCommand` (your helper's command) and `auth.operatorRoleArn` (from Step 1's caller ARN).

Restrict permissions immediately — the file now holds the external ID:

```bash
chmod 700 ~/.corgiro ~/.corgiro/state
chmod 600 ~/.corgiro/config.json
```

Then prove the whole chain against one member account. Pick any active account from `aws organizations list-accounts --profile <baseProfile>`:

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::<SAMPLE_ACCOUNT_ID>:role/<MEMBER_ROLE_NAME> \
  --role-session-name corgiro-onboard-check \
  --external-id "$EXTERNAL_ID" \
  --profile <baseProfile> \
  --query 'AssumedRoleUser.Arn' --output text
```

**`AccessDenied` here is a hard stop.** It is ambiguous across four causes, and AWS returns the same message for all of them — present all four rather than guessing:

> AssumeRole failed. Any of these could be the cause:
>
> 1. The role is not named `CorgiroReadOnlyRole` — the operator may have renamed it to avoid a collision (see option-b Step 2.5). **What role name was deployed?**
> 2. The external ID does not match what the StackSet was deployed with.
> 3. `CorgiroReadOnlyRole` is not deployed to this particular account — try another account before assuming the config is wrong.
> 4. Your operator identity is not the one the role trusts (wrong permission set name, or wrong `OperatorRoleName`).

Re-ask for the role name (Step 3) and/or the external ID (Step 4 tier 3) and retry. Do not proceed to Step 6 until this call succeeds.

## Step 6: Account scope

`accountFilter` lives only in the setting-up operator's local `config.json`. **AWS holds no record of it, so Path C cannot detect it.** Ask once:

> "Did the operator who set Corgiro up restrict which accounts are in scope? This is stored only in their local config, so I cannot detect it.
>
> 1. No / don't know — use the whole organization (default)
> 2. Yes, exclude specific account IDs
> 3. Yes, include only specific account IDs"

Default to `{ "include": [], "exclude": [] }` on answer 1 or no answer.

> **Scope can legitimately differ between operators.** If the operator who onboarded you excluded accounts and you did not, your reports will be **wider** than theirs. The Step 7 summary prints the effective scope and account count so this is visible when two operators compare output.

Then build the roster from the org and save it:

```bash
aws organizations list-accounts --profile <baseProfile> --output json
```

Write `~/.corgiro/state/roster.json` with one Roster Entry per ACTIVE account after applying `accountFilter`, per the authoritative schema in [`credential-resolution.md`](../../../references/credential-resolution.md#roster-entry-schema-authoritative): `role: "<MEMBER_ROLE_NAME>"`, `via: "assume-role"`, `readOnlyEnforced: true`. `readOnlyEnforced` is always `true` on this path — the member-account privilege boundary is `CorgiroReadOnlyRole`, which is unaffected by how you joined.

## Step 7: Detect and disclose what you cannot reach

A Path C operator is **not** automatically equivalent to the operator who ran Option B. That operator had payer access; you do not. Detect this and say so rather than letting it surface as a mode failure later.

Service-managed StackSets do not deploy to the management account, so `CorgiroReadOnlyRole` normally does not exist there. Option B's operator covers the payer with their own payer credentials — a Path C operator has none.

```bash
# The management account
aws organizations describe-organization --profile <baseProfile> \
  --query 'Organization.MasterAccountId' --output text

# Does the tooling account hold any delegated administration that substitutes for payer access?
aws organizations list-delegated-services-for-account \
  --account-id <TOOLING_ACCOUNT_ID> --profile <baseProfile> \
  --query 'DelegatedServices[].ServicePrincipal' --output text
```

If the management account probes as unreachable, include a `LIMITED CAPABILITY` block in the Step 7 summary (MODE.md Step 3 prints it):

> **LIMITED CAPABILITY — management account.** `<payerAccountId>` is not reachable with your credentials: `CorgiroReadOnlyRole` is not deployed there, because service-managed StackSets skip the management account. Affected:
>
> - `ri-sp-coverage-analysis` — **unavailable.** It requires the payer in the roster and reachable. Cost Explorer, Cost Optimization Hub and `savingsplans:Describe*` are payer-scoped. This works only if the tooling account is a delegated administrator for a billing/cost service (checked above).
> - `defaultRegions: auto` region discovery — **degraded.** Cost Explorer is payer-level; modes fall back to the shared `fallbackRegions` set.
>
> To lift this, the operator with payer access can deploy [`../../../assets/corgiro-readonly-role.yaml`](../../../assets/corgiro-readonly-role.yaml) as a standalone stack in the management account with the same `ToolingAccountId` and `ExternalId`. Weigh it first — it grants payer read access to every operator identity.

Then return to setup **MODE.md Step 3 (Validate access & finalize)**, which probes every roster account, writes the coverage snapshot, and prints the summary.

## Removing an operator

Revocation is IdP-side and needs no AWS change at all:

- **`identity-center`** — unassign the `CorgiroOperator` permission set from the user or group in the tooling account.
- **`saml-external`** — remove them from the AWS app's role claim in the IdP.

Nothing on the AWS side changes: no StackSet update, no trust-policy edit, no external-ID rotation. `CorgiroReadOnlyRole` trusts a principal _pattern_, and that pattern is unchanged when one person loses the identity that matches it. Have the departing operator delete `~/.corgiro/` — it holds the external ID and the account roster.
