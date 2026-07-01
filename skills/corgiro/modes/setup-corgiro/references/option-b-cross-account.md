# Option B — Cross-Account Setup (org-wide read-only role)

Provisions org-wide, consistent, read-only coverage by deploying `CorgiroReadOnlyRole` to every member account and operating from a tooling account. This is the heavier path and needs temporary elevated access.

> Unlike Option A, you do **not** log into the `corgiro` SSO session at MODE.md Step 1 — `CorgiroOperator` doesn't exist yet. Steps 0–3 run with **temporary payer (management) access**; you create and log into the `CorgiroOperator` session in Steps 4–6.

## Access Required (Temporary Payer Access)

Setup needs **temporary access to the payer (management) account**. Only the payer can call `organizations:EnableAWSServiceAccess`, `organizations:RegisterDelegatedAdministrator`, and create the service-managed StackSet.

Pick the most-scoped role available:

1. `AWSOrganizationsFullAccess` + `AWSCloudFormationFullAccess` (recommended)
2. `AdministratorAccess` in the payer
3. `OrganizationAccountAccessRole`

## Prerequisites

- An AWS Organization with all features enabled
- A dedicated **tooling account** already created in the org
- IAM Identity Center enabled on the organization
- A supported Support plan — Business, Enterprise On-Ramp, or Enterprise — on the management account (required for the Health API)
- Cost Explorer enabled
- Laptop has AWS CLI v2

## Parameters (decide upfront)

| Parameter               | Example               | Notes                                                              |
| ----------------------- | --------------------- | ------------------------------------------------------------------ |
| `MANAGEMENT_ACCOUNT_ID` | `111111111111`        | Root of the organization                                           |
| `TOOLING_ACCOUNT_ID`    | `222222222222`        | Where CorgiroOperator is assigned                                  |
| `ROOT_OU_ID`            | `r-xxxx`              | `aws organizations list-roots --query 'Roots[0].Id'`               |
| `EXTERNAL_ID`           | `corgiro-<uuid>`      | Generate once; keep in a password manager. Must match config.json. |
| `PERMISSION_SET_NAME`   | `CorgiroOperator`     | Identity Center permission set                                     |
| `MEMBER_ROLE_NAME`      | `CorgiroReadOnlyRole` | Matches StackSet template                                          |
| `STACKSET_REGION`       | `us-east-1`           | StackSet admin region                                              |

## Step 0: Prerequisite Check

Caller must be in the management account. Organizations reachable. Tooling account is a member. Identity Center instance exists.

## Step 0.5: Assess Existing State

Check which service principals already have trusted access and delegated admin. Skip whatever is already enabled.

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

For each service that needs delegated admin on the tooling account:

```bash
aws organizations register-delegated-administrator \
  --account-id $TOOLING_ACCOUNT_ID \
  --service-principal <service-principal>
```

## Step 3: Deploy CorgiroReadOnlyRole StackSet

> ⚠️ Mutating step — confirm with the operator before running.

```bash
aws cloudformation create-stack-set \
  --stack-set-name CorgiroReadOnlyRole \
  --template-body file://assets/corgiro-readonly-role.yaml \
  --parameters ParameterKey=ToolingAccountId,ParameterValue=$TOOLING_ACCOUNT_ID \
               ParameterKey=ExternalId,ParameterValue=$EXTERNAL_ID \
  --permission-model SERVICE_MANAGED \
  --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
  --region $STACKSET_REGION

aws cloudformation create-stack-instances \
  --stack-set-name CorgiroReadOnlyRole \
  --deployment-targets OrganizationalUnitIds=$ROOT_OU_ID \
  --regions us-east-1 \
  --region $STACKSET_REGION
```

Wait for `SUCCEEDED` status.

## Step 4: Create CorgiroOperator Permission Set (Console)

In IAM Identity Center:

1. Create a permission set named `CorgiroOperator`.
2. Attach an inline policy with: `sts:AssumeRole` on `arn:aws:iam::*:role/CorgiroReadOnlyRole`, org read APIs, and health / security-hub / guardduty / config read APIs.
3. Assign it to the user/group in the tooling account.

> The permission set name must match `PermissionSetNamePrefix` in the StackSet template — the role's trust policy uses `ArnLike` on `AWSReservedSSO_CorgiroOperator_*`.

## Step 5: Configure Laptop

```bash
aws configure sso --session-name corgiro
```

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
aws sts get-caller-identity
aws organizations describe-organization
aws organizations list-delegated-administrators --service-principal health.amazonaws.com
```

Then build the roster from the full org and save it:

```bash
aws organizations list-accounts --output json
```

Write `~/.corgiro/state/roster.json` with one entry per ACTIVE account: `{ "name", "role": "CorgiroReadOnlyRole", "via": "assume-role", "readOnlyEnforced": true }`. `readOnlyEnforced` is always `true` on this path -- `CorgiroReadOnlyRole` constrains access to read-only at the IAM layer.

Then return to setup **Step 3**, which validates `CorgiroReadOnlyRole` assumption across all accounts and writes the coverage snapshot. (Re-run `/corgiro account-coverage` anytime to re-validate or pick up new accounts.)
