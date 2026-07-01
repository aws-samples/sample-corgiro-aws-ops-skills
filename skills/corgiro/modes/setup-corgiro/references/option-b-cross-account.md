# Option B — Cross-Account Setup (org-wide read-only role)

Provisions org-wide, consistent, read-only coverage by deploying `CorgiroReadOnlyRole` to every member account and operating from a tooling account. This is the heavier path and needs temporary elevated access.

> Unlike Option A, you do **not** log into the `corgiro` SSO session at MODE.md Step 1 (`CorgiroOperator` doesn't exist yet). The setup supports two StackSet deployment modes, chosen in [StackSet Deployment Mode](#stackset-deployment-mode-decide-upfront):
>
> - **management** (default): Steps 0-3 run with **temporary payer (management) access**.
> - **delegated-admin**: the payer bootstrap (Steps 1-2) is assumed already in place; Step 3 runs from a registered StackSets delegated administrator account with `--call-as DELEGATED_ADMIN`, so no payer access is needed for the deploy.
>
> Either way, you create and log into the `CorgiroOperator` session in Steps 4-6.

## Access Required (Temporary Payer Access)

Setup needs **temporary access to the payer (management) account**. Only the payer can call `organizations:EnableAWSServiceAccess`, `organizations:RegisterDelegatedAdministrator`, and create the service-managed StackSet.

Pick the most-scoped role available:

1. `AWSOrganizationsFullAccess` + `AWSCloudFormationFullAccess` (recommended)
2. `AdministratorAccess` in the payer
3. `OrganizationAccountAccessRole`

> **Delegated-admin mode needs payer access only once, beforehand.** If you deploy the StackSet from a registered delegated administrator account (see [StackSet Deployment Mode](#stackset-deployment-mode-decide-upfront)), the payer is used only to activate trusted access and register the delegated admin. Those are assumed already done in that mode, and the deploy itself runs from the delegated admin account with no payer access.

## Prerequisites

- An AWS Organization with all features enabled
- A dedicated **tooling account** already created in the org
- IAM Identity Center enabled on the organization
- A supported Support plan — Business, Enterprise On-Ramp, or Enterprise — on the management account (required for the Health API)
- Cost Explorer enabled
- Laptop has AWS CLI v2

## Parameters (decide upfront)

| Parameter                    | Example               | Notes                                                                |
| ---------------------------- | --------------------- | -------------------------------------------------------------------- |
| `MANAGEMENT_ACCOUNT_ID`      | `111111111111`        | Root of the organization                                             |
| `TOOLING_ACCOUNT_ID`         | `222222222222`        | Where CorgiroOperator is assigned                                    |
| `ROOT_OU_ID`                 | `r-xxxx`              | `aws organizations list-roots --query 'Roots[0].Id'`                 |
| `EXTERNAL_ID`                | `corgiro-<uuid>`      | Generate once; keep in a password manager. Must match config.json.   |
| `PERMISSION_SET_NAME`        | `CorgiroOperator`     | Identity Center permission set                                       |
| `MEMBER_ROLE_NAME`           | `CorgiroReadOnlyRole` | Matches StackSet template                                            |
| `STACKSET_REGION`            | `us-east-1`           | StackSet admin region                                                |
| `STACKSET_ADMIN_MODE`        | `management`          | `management` or `delegated-admin` - see StackSet Deployment Mode     |
| `DELEGATED_ADMIN_ACCOUNT_ID` | `333333333333`        | Only for `delegated-admin` mode; the account you run the deploy from |

## StackSet Deployment Mode (decide upfront)

`CorgiroReadOnlyRole` can be created from **either** the management account **or** a registered StackSets delegated administrator account. **Ask the operator which one - do not assume.**

| Mode                 | `STACKSET_ADMIN_MODE` | Deploy runs from             | Trusted access + delegated admin registration    | `--call-as`       |
| -------------------- | --------------------- | ---------------------------- | ------------------------------------------------ | ----------------- |
| Management (default) | `management`          | Payer (management) account   | Done in this run (Steps 1-2)                     | `SELF` (implicit) |
| Delegated admin      | `delegated-admin`     | `DELEGATED_ADMIN_ACCOUNT_ID` | **Assumed already in place** - Steps 1-2 skipped | `DELEGATED_ADMIN` |

The deployer is independent of the role's trust. The template's `ToolingAccountId` parameter controls who can assume `CorgiroReadOnlyRole` at runtime; whoever _deploys_ the StackSet is separate. So `DELEGATED_ADMIN_ACCOUNT_ID` may be the tooling account or a dedicated CICD/tooling account - it does not have to equal `TOOLING_ACCOUNT_ID`.

### If the operator chooses `delegated-admin`

1. This variant **assumes** `aws cloudformation activate-organizations-access` and `aws organizations register-delegated-administrator --service-principal member.org.stacksets.cloudformation.amazonaws.com` were already run from the payer. **Skip Steps 1 and 2.**
2. Set `DELEGATED_ADMIN_ACCOUNT_ID` and sign in to that account. The reference doesn't assume a specific mechanism - pick whichever gives you a CLI session in that account:
   - **Preferred - Identity Center permission set.** If you have a permission set assigned in the delegated-admin account (needs `cloudformation:*StackSet*` and `organizations:List*`/`Describe*` at minimum), add it as a profile and use it:

     ```ini
     [profile corgiro-da]
     sso_session = corgiro
     sso_account_id = <DELEGATED_ADMIN_ACCOUNT_ID>
     sso_role_name = <YourStackSetsPermissionSet>
     region = <STACKSET_REGION>
     ```

     Then `aws sso login --sso-session corgiro` and select this profile for the deploy - either `export AWS_PROFILE=corgiro-da` (applies to all Step 2.5 and Step 3 commands) or add `--profile corgiro-da` to each.

   - **Fallback - role-chain via `OrganizationAccountAccessRole`.** If no permission set exists in the delegated-admin account, chain into the org-default admin role from a source profile that can assume it (typically the management account):

     ```ini
     [profile corgiro-da]
     role_arn = arn:aws:iam::<DELEGATED_ADMIN_ACCOUNT_ID>:role/OrganizationAccountAccessRole
     source_profile = <management-account-profile>
     region = <STACKSET_REGION>
     ```

     > Tradeoff: this fallback reintroduces a payer dependency for the sign-in only (the source profile must be the management account, which can assume `OrganizationAccountAccessRole`). The StackSet deploy itself still runs as the delegated admin. If avoiding payer access entirely is the goal, use the permission-set option instead.

   Either way, confirm the session lands in the right account before continuing: `aws sts get-caller-identity --profile corgiro-da --query Account --output text` must equal `DELEGATED_ADMIN_ACCOUNT_ID`.

3. **Validate before deploying (hard gate - stop on failure):**

   ```bash
   # a. Confirm you are signed in to the intended account
   aws sts get-caller-identity --query Account --output text

   # b. List registered StackSets delegated administrators
   aws organizations list-delegated-administrators \
     --service-principal member.org.stacksets.cloudformation.amazonaws.com \
     --query 'DelegatedAdministrators[].Id' --output text
   ```

   The caller account from (a) must equal `DELEGATED_ADMIN_ACCOUNT_ID`, **and** `DELEGATED_ADMIN_ACCOUNT_ID` must appear in the list from (b). **Throw an error and stop before Step 3 if either is false** - including when (b) is denied, since a member account that is not a delegated admin cannot call this API.

   Error to surface:

   > `DELEGATED_ADMIN_ACCOUNT_ID (<id>) is not a registered StackSets delegated administrator. From the payer, run: aws cloudformation activate-organizations-access, then aws organizations register-delegated-administrator --service-principal member.org.stacksets.cloudformation.amazonaws.com --account-id <id>. Then re-run this setup.`

4. Proceed to Step 3 and use the **delegated-admin** command variant (`--call-as DELEGATED_ADMIN`).

> Scope: this variant only moves the `CorgiroReadOnlyRole` StackSet deploy off the payer. Enabling the other org-wide services in Step 0.5 (Health, Config, Security Hub, etc.) still requires payer access and is unaffected by this choice.

## Step 0: Prerequisite Check

Caller must be signed in to the account that will create the StackSet - the **management account** in `management` mode, or `DELEGATED_ADMIN_ACCOUNT_ID` in `delegated-admin` mode. Organizations reachable. Tooling account is a member. Identity Center instance exists.

## Step 0.5: Assess Existing State

Check which service principals already have trusted access and delegated admin. Skip whatever is already enabled. (For the `CorgiroReadOnlyRole` StackSet and role, the existing-deployment check is [Step 2.5](#step-25-check-for-an-existing-corgiro-deployment), run just before the deploy.)

| Service Principal                                   | Why                                       |
| --------------------------------------------------- | ----------------------------------------- |
| `member.org.stacksets.cloudformation.amazonaws.com` | Service-managed StackSets (required)      |
| `health.amazonaws.com`                              | Org-wide Health                           |
| `config.amazonaws.com`                              | Org-wide Config data aggregation          |
| `config-multiaccountsetup.amazonaws.com`            | Config rule / conformance-pack deployment |
| `securityhub.amazonaws.com`                         | Cross-account Security Hub                |
| `guardduty.amazonaws.com`                           | Org-wide GuardDuty                        |
| `access-analyzer.amazonaws.com`                     | Org-wide Access Analyzer                  |
| `resource-explorer-2.amazonaws.com`                 | Org-wide resource search                  |

## Step 1: Enable Trusted Access

> **`delegated-admin` mode: skip this step.** Trusted access is assumed already active. Run this only in `management` mode (from the payer).

For each missing service principal:

```bash
aws organizations enable-aws-service-access \
  --service-principal <service-principal>
```

> **StackSets exception:** do not use `enable-aws-service-access` for StackSets. Activate it via CloudFormation's own API:
>
> ```bash
> aws cloudformation activate-organizations-access --region $STACKSET_REGION
> ```

## Step 2: Register Delegated Admin

> **`delegated-admin` mode: skip this step.** The delegated admin registration is assumed already in place and was verified in [StackSet Deployment Mode](#stackset-deployment-mode-decide-upfront). Run this only in `management` mode (from the payer).

For each service that needs delegated admin on the tooling account:

```bash
aws organizations register-delegated-administrator \
  --account-id $TOOLING_ACCOUNT_ID \
  --service-principal <service-principal>
```

## Step 2.5: Check for an Existing Corgiro Deployment

> Runs in **both** modes, from the account that will deploy (payer in `management`, `DELEGATED_ADMIN_ACCOUNT_ID` in `delegated-admin`). Do this before Step 3 - it catches a role-name collision that otherwise surfaces mid-rollout as a confusing per-account `FAILED`/`CANCELLED`.

`CorgiroReadOnlyRole` is created with a **fixed name** (the template pins `RoleName` and derives `ManagedPolicyName` from it). If a role by that name already exists in the target accounts - or a Corgiro StackSet already exists under a _different_ name - the new StackSet cannot create the role and the deploy fails.

### a. Look for an existing Corgiro StackSet (any name variant)

```bash
aws cloudformation list-stack-sets \
  --status ACTIVE \
  --call-as SELF \
  --region $STACKSET_REGION \
  --query "Summaries[?contains(StackSetName, 'orgiro')].{Name:StackSetName,Model:PermissionModel}" \
  --output table
```

> In `delegated-admin` mode use `--call-as DELEGATED_ADMIN` instead of `--call-as SELF`. The `'orgiro'` substring matches any capitalization (`Corgiro`, `corgiro`) and any separator, so it catches drifted names like `Corgiro-ReadOnly-Role` (hyphens) as well as `CorgiroReadOnlyRole`.

### b. Spot-check the member-account role

Pick one active member account (`SAMPLE_ACCOUNT_ID`) and check whether the role already exists. In `management` mode from the payer:

```bash
CREDS=$(aws sts assume-role \
  --role-arn arn:aws:iam::$SAMPLE_ACCOUNT_ID:role/OrganizationAccountAccessRole \
  --role-session-name corgiro-precheck --query 'Credentials' --output json)
AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .AccessKeyId) \
AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .SecretAccessKey) \
AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .SessionToken) \
aws iam get-role --role-name CorgiroReadOnlyRole \
  --query 'Role.{Arn:Arn,Created:CreateDate}' --output table
```

`NoSuchEntity` means the account is clean. A returned role means it is already deployed (note the create date - it may predate this setup).

### c. Decide: adopt, replace, or rename

| Finding                                                       | Recommended action                                                                                                                                                                                                                                   |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No StackSet, no role                                          | **Proceed** to Step 3 as written.                                                                                                                                                                                                                    |
| StackSet named `CorgiroReadOnlyRole` already exists           | **Adopt.** Skip `create-stack-set`. Auto-deployment already covers future accounts; run only `create-stack-instances` if specific accounts are missing. Confirm its `ToolingAccountId` / `ExternalId` match your `config.json` before relying on it. |
| Role exists, deployed by a **differently-named** StackSet     | **Adopt that StackSet** (use its real name for every later command), or **replace** it (delete first - see below). Do **not** create a second same-role StackSet.                                                                                    |
| Role exists with **no** managing StackSet (manual / orphaned) | **Replace** (remove the orphan role at its origin) or **rename** the new deployment (see below).                                                                                                                                                     |

**To replace an old StackSet** (⚠️ destructive - confirm with the operator first; removes the role from member accounts):

```bash
aws cloudformation delete-stack-instances \
  --stack-set-name <OldStackSetName> \
  --deployment-targets OrganizationalUnitIds=$ROOT_OU_ID \
  --regions us-east-1 --no-retain-stacks \
  --region $STACKSET_REGION            # add --call-as DELEGATED_ADMIN in delegated-admin mode
# wait for the operation to finish, then:
aws cloudformation delete-stack-set --stack-set-name <OldStackSetName> \
  --region $STACKSET_REGION            # same --call-as as above
```

**To rename instead** (keep the old role, deploy Corgiro under a new name): pass `ParameterKey=RoleName,ParameterValue=<NewRoleName>` in Step 3, and set `crossAccount.memberRoleName` to the same value in Step 5 so credential resolution assumes the right role. `ManagedPolicyName` follows `RoleName` automatically.

## Step 3: Deploy CorgiroReadOnlyRole StackSet

> ⚠️ Mutating step - confirm with the operator before running.

**`management` mode** - run from the payer:

```bash
aws cloudformation create-stack-set \
  --stack-set-name CorgiroReadOnlyRole \
  --template-body file://assets/corgiro-readonly-role.yaml \
  --parameters ParameterKey=ToolingAccountId,ParameterValue=$TOOLING_ACCOUNT_ID \
               ParameterKey=ExternalId,ParameterValue=$EXTERNAL_ID \
  --permission-model SERVICE_MANAGED \
  --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $STACKSET_REGION

aws cloudformation create-stack-instances \
  --stack-set-name CorgiroReadOnlyRole \
  --deployment-targets OrganizationalUnitIds=$ROOT_OU_ID \
  --regions us-east-1 \
  --operation-preferences FailureToleranceCount=20,MaxConcurrentCount=10 \
  --region $STACKSET_REGION
```

**`delegated-admin` mode** - run from `DELEGATED_ADMIN_ACCOUNT_ID`, only after the [StackSet Deployment Mode](#stackset-deployment-mode-decide-upfront) validation passed. Identical to above, but add `--call-as DELEGATED_ADMIN` to every StackSet call:

```bash
aws cloudformation create-stack-set \
  --stack-set-name CorgiroReadOnlyRole \
  --template-body file://assets/corgiro-readonly-role.yaml \
  --parameters ParameterKey=ToolingAccountId,ParameterValue=$TOOLING_ACCOUNT_ID \
               ParameterKey=ExternalId,ParameterValue=$EXTERNAL_ID \
  --permission-model SERVICE_MANAGED \
  --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
  --capabilities CAPABILITY_NAMED_IAM \
  --call-as DELEGATED_ADMIN \
  --region $STACKSET_REGION

aws cloudformation create-stack-instances \
  --stack-set-name CorgiroReadOnlyRole \
  --deployment-targets OrganizationalUnitIds=$ROOT_OU_ID \
  --regions us-east-1 \
  --operation-preferences FailureToleranceCount=20,MaxConcurrentCount=10 \
  --call-as DELEGATED_ADMIN \
  --region $STACKSET_REGION
```

> The stack set resource lives in the management account even when created by a delegated admin. Any later list/describe/update/delete from the delegated admin account must also pass `--call-as DELEGATED_ADMIN`.

> **`--capabilities CAPABILITY_NAMED_IAM` is required, not optional.** The template creates named IAM resources (`RoleName: CorgiroReadOnlyRole` and `ManagedPolicyName: CorgiroReadOnlyRole-DataPlaneDeny`). Without this flag, `create-stack-set` fails with `InsufficientCapabilitiesException`. `CAPABILITY_IAM` is not enough because the resources have explicit names.

> **Set `--operation-preferences` so one account's failure doesn't cancel the whole rollout.** The default `FailureToleranceCount` is `0`, so a single account failure stops the operation and the remaining accounts report `CANCELLED` - which buries the real error behind noise. A non-zero failure tolerance lets the operation continue and surface each account's actual status, making failures diagnosable. Tune the counts to your org (raise `FailureToleranceCount` toward your account count to survey everything in one pass); for large orgs the percentage forms `FailureTolerancePercentage`/`MaxConcurrentPercentage` are easier to reason about. `--operation-preferences` goes on `create-stack-instances` (and `update-stack-instances`), not on `create-stack-set`.

Wait for `SUCCEEDED` status. If the operation reports failures, use `aws cloudformation list-stack-set-operation-results --stack-set-name CorgiroReadOnlyRole [--call-as DELEGATED_ADMIN] --region $STACKSET_REGION` to see the per-account reason (a common one is a pre-existing role name collision - see [Step 2.5](#step-25-check-for-an-existing-corgiro-deployment)).

## Step 4: Create CorgiroOperator Permission Set (Console)

In IAM Identity Center:

1. Create a permission set named `CorgiroOperator`.
2. Attach an inline policy with: `sts:AssumeRole` on `arn:aws:iam::*:role/CorgiroReadOnlyRole`, org read APIs, and health / security-hub / guardduty / config read APIs.
3. Assign it to the user/group in the tooling account.

> The permission set name must match `PermissionSetNamePrefix` in the StackSet template — the role's trust policy uses `ArnLike` on `AWSReservedSSO_CorgiroOperator_*`.

## Step 5: Configure Laptop

Run `aws configure sso` to register the Identity Center session and a base profile for the **tooling account**. The interactive prompt writes to `~/.aws/config`; the result should look like this:

```ini
[sso-session corgiro]
sso_start_url = https://ORG.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile corgiro]
sso_session = corgiro
sso_account_id = <TOOLING_ACCOUNT_ID>
sso_role_name = CorgiroOperator
region = us-east-1
output = json
```

> **`corgiro` is the base identity every mode operates from.** This is the Option B analogue of Option A's per-account `corgiro-<accountId>` profiles - but Option B has only **one** profile, because member accounts are reached by assuming `CorgiroReadOnlyRole` _from_ the tooling account, not by direct SSO. Downstream modes select this base identity with `--profile corgiro` (or `export AWS_PROFILE=corgiro`), then chain into each member account via AssumeRole. See [credential-resolution.md](../../../references/credential-resolution.md) (`via = "assume-role"`).

Write `~/.corgiro/config.json`:

```json
{
  "accessMode": "cross-account-role",
  "ssoSession": {
    "sessionName": "corgiro",
    "startUrl": "https://ORG.awsapps.com/start",
    "ssoRegion": "us-east-1"
  },
  "identityCenter": null,
  "crossAccount": {
    "toolingAccountId": "<TOOLING_ACCOUNT_ID>",
    "externalId": "<EXTERNAL_ID>",
    "memberRoleName": "CorgiroReadOnlyRole",
    "accountFilter": { "include": [], "exclude": [] }
  }
}
```

> `crossAccount.externalId` must equal the `ExternalId` passed to the StackSet in Step 3, or every AssumeRole will fail.

After writing `config.json`, restrict permissions immediately — it now holds the external ID (the cross-account trust secret):

```bash
chmod 700 ~/.corgiro ~/.corgiro/state
chmod 600 ~/.corgiro/config.json
```

Keep `~/.corgiro/` on an OS-encrypted volume (FileVault / LUKS). Setup Step 3 re-applies these permissions after writing the roster and coverage snapshot.

## Step 6: Smoke Test

```bash
aws sso login --sso-session corgiro
aws sts get-caller-identity --profile corgiro
aws organizations describe-organization --profile corgiro
aws organizations list-delegated-administrators --service-principal health.amazonaws.com --profile corgiro
```

Then build the roster from the full org and save it:

```bash
aws organizations list-accounts --profile corgiro --output json
```

Write `~/.corgiro/state/roster.json` with one entry per ACTIVE account: `{ "name", "role": "CorgiroReadOnlyRole", "via": "assume-role", "readOnlyEnforced": true }`. `readOnlyEnforced` is always `true` on this path -- `CorgiroReadOnlyRole` constrains access to read-only at the IAM layer.

Then return to setup **Step 3**, which validates `CorgiroReadOnlyRole` assumption across all accounts and writes the coverage snapshot. (Re-run `/corgiro account-coverage` anytime to re-validate or pick up new accounts.)
