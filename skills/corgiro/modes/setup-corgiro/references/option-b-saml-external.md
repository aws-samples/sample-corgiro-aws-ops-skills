# Option B (SAML) — Cross-Account Setup via an External IdP

Same access model as [option-b-cross-account.md](option-b-cross-account.md) — org-wide `CorgiroReadOnlyRole` assumed from a tooling account — but the operator reaches the tooling account through an **external identity provider** instead of IAM Identity Center. Use this when your org federates AWS CLI access with Azure AD / Entra ID, Okta, PingFederate or ADFS via a helper such as `aws-azure-login`, `saml2aws` or `gimme-aws-creds`.

Recorded as `authMethod: "saml-external"` in `~/.corgiro/config.json`. See [`credential-resolution.md`](../../../references/credential-resolution.md#auth-method-dispatch) for the dispatch rules, preconditions and residual risk.

> **This file covers Steps 4–6 only.** Steps 0–3 (prerequisite check, trusted access, delegated admin, StackSet deploy) are identical to the Identity Center path and are **not repeated here** — that content, including the delegated-admin validation gate and the existing-deployment collision check, lives in one place on purpose. Complete [option-b-cross-account.md](option-b-cross-account.md) Steps 0–3 first, with the one delta below, then return here.

> **Not available on Option A.** `authMethod: saml-external` requires `accessMode: cross-account-role`. Option A discovers accounts through `aws sso list-accounts` / `list-account-roles`, which need an Identity Center access token; an external IdP exposes the account list only inside the SAML assertion, with no AWS API to enumerate it.

## Prerequisites (in addition to Option B's)

- A SAML identity provider already registered in the **tooling account** (`aws iam list-saml-providers`). Create it from your IdP's federation metadata before starting; the templates do not create it.
- Your IdP helper installed and able to log in to the tooling account (`aws-azure-login --configure`, `saml2aws configure`, …).
- The AWS-side app/enterprise-application configured in your IdP, with the operator role included in its role claim.

## Parameters (delta from Option B)

| Parameter            | Example                                                | Notes                                                                       |
| -------------------- | ------------------------------------------------------ | --------------------------------------------------------------------------- |
| `OPERATOR_ROLE_NAME` | `CorgiroOperator`                                      | Operator role in the tooling account. Must match everywhere it appears.     |
| `SAML_PROVIDER_ARN`  | `arn:aws:iam::222222222222:saml-provider/AzureAD`      | Existing provider in the tooling account                                    |
| `AUTH_PROFILE`       | `corgiro`                                              | Base CLI profile your helper writes credentials into                        |
| `LOGIN_COMMAND`      | `aws-azure-login --profile corgiro`                     | Printed as remediation on `auth_expired`; Corgiro never executes it         |

`PERMISSION_SET_NAME` does not apply. If your org has no Identity Center at all, pass `PermissionSetNamePrefix=""` in Step 3 so the member role does not carry an inert `AWSReservedSSO_CorgiroOperator_*` trust pattern that would start matching if you later adopted Identity Center and named a permission set `CorgiroOperator`.

## Delta to Option B Step 3

Add `OperatorRoleName` to the StackSet parameters so `CorgiroReadOnlyRole` trusts your operator role:

```bash
  --parameters ParameterKey=ToolingAccountId,ParameterValue=$TOOLING_ACCOUNT_ID \
               ParameterKey=ExternalId,ParameterValue=$EXTERNAL_ID \
               ParameterKey=OperatorRoleName,ParameterValue=$OPERATOR_ROLE_NAME \
               ParameterKey=PermissionSetNamePrefix,ParameterValue=""
```

Everything else in Step 3 — `--permission-model SERVICE_MANAGED`, `--auto-deployment`, `--capabilities CAPABILITY_NAMED_IAM`, `--operation-preferences`, and the `--call-as DELEGATED_ADMIN` variant — is unchanged.

> **Deploy order does not matter.** The operator role need not exist when the StackSet runs. `OperatorRoleName` is consumed as an `ArnLike` condition on `aws:PrincipalArn` — a string comparison, not a principal reference — so CloudFormation does not validate that the role exists. (A `Principal: { AWS: <role-arn> }` *would* fail for a missing role; this template deliberately does not use one.)

## Step 4: Deploy the Operator Role (tooling account)

> ⚠️ Mutating step — confirm with the operator before running.

Sign in to the **tooling account** with a role that can create IAM roles, then:

```bash
aws cloudformation deploy \
  --stack-name corgiro-operator-role \
  --template-file assets/corgiro-operator-role.yaml \
  --parameter-overrides \
      SamlProviderArn=$SAML_PROVIDER_ARN \
      RoleName=$OPERATOR_ROLE_NAME \
      MemberRoleName=$MEMBER_ROLE_NAME \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $STACKSET_REGION
```

`CAPABILITY_NAMED_IAM` is required — the template creates a named role and a named managed policy.

Then add `$OPERATOR_ROLE_NAME` to the AWS app's role claim in your IdP and assign the operators who should hold it.

> **Already have an operator role?** Skip this template and reuse it, as long as it grants `sts:AssumeRole` on `arn:aws:iam::*:role/CorgiroReadOnlyRole` plus the org/health/config/securityhub/guardduty/ce read actions. Set `OPERATOR_ROLE_NAME` to its name. Corgiro does not require the role to have been created by this template — but it also cannot warn you if an existing role is over-scoped, so check it against the template's policy before reusing.

## Step 5: Configure Laptop

Configure your helper to write the tooling-account session into the base profile. For `aws-azure-login`, `--configure` writes `~/.aws/config`:

```ini
[profile corgiro]
azure_tenant_id = <tenant-uuid>
azure_app_id_uri = https://signin.aws.amazon.com/saml
azure_default_username = operator@example.com
azure_default_role_arn = arn:aws:iam::222222222222:role/CorgiroOperator
azure_default_duration_hours = 1
region = us-east-1
output = json
```

`azure_default_role_arn` must name the same role as `OPERATOR_ROLE_NAME`. Setup cross-checks these and hard-stops on a mismatch, because a mismatch otherwise surfaces only as `AccessDenied` on every member account.

> **`auth.profile` is the base identity every mode operates from** — `corgiro` by default, and the `saml-external` analogue of the Identity Center path's base profile. Member accounts are reached by assuming `CorgiroReadOnlyRole` *from* this profile, so there is only ever one profile. Downstream modes select it with `--profile <auth.profile>` (or `export AWS_PROFILE=<auth.profile>`). See [`credential-resolution.md`](../../../references/credential-resolution.md) (`via = "assume-role"`).

Write `~/.corgiro/config.json`:

```json
{
  "accessMode": "cross-account-role",
  "authMethod": "saml-external",
  "ssoSession": null,
  "identityCenter": null,
  "auth": {
    "profile": "corgiro",
    "loginCommand": "aws-azure-login --profile corgiro",
    "operatorRoleArn": "arn:aws:iam::222222222222:role/CorgiroOperator"
  },
  "crossAccount": {
    "toolingAccountId": "222222222222",
    "externalId": "<EXTERNAL_ID>",
    "memberRoleName": "CorgiroReadOnlyRole",
    "accountFilter": { "include": [], "exclude": [] }
  }
}
```

> `crossAccount.externalId` must equal the `ExternalId` passed to the StackSet in Step 3, or every AssumeRole will fail.

Restrict permissions immediately — the file now holds the external ID:

```bash
chmod 700 ~/.corgiro ~/.corgiro/state
chmod 600 ~/.corgiro/config.json
```

## Step 6: Smoke Test

```bash
aws-azure-login --profile corgiro          # or your helper's login command
aws sts get-caller-identity --profile corgiro
aws organizations describe-organization --profile corgiro
```

Verify all three preconditions from [`credential-resolution.md`](../../../references/credential-resolution.md#preconditions-for-saml-external) — the caller account equals `toolingAccountId`, the ARN is an `assumed-role/` (not an IAM `user/`), and the role name matches `OPERATOR_ROLE_NAME`. Then confirm the cross-account hop actually works against one member account before building the full roster:

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::<SAMPLE_ACCOUNT_ID>:role/CorgiroReadOnlyRole \
  --role-session-name corgiro-smoketest \
  --external-id <EXTERNAL_ID> \
  --profile corgiro \
  --query 'AssumedRoleUser.Arn' --output text
```

`AccessDenied` here means the operator role ARN or the external ID does not match what the StackSet was deployed with — see the `trust_mismatch` note in [`credential-resolution.md`](../../../references/credential-resolution.md#reachability-categories-shared-vocabulary). Both causes produce an identical error, so check the role ARN as well as the external ID.

Then build the roster:

```bash
aws organizations list-accounts --profile corgiro --output json
```

Write `~/.corgiro/state/roster.json` with one Roster Entry per ACTIVE account, per the authoritative schema in [`credential-resolution.md`](../../../references/credential-resolution.md#roster-entry-schema-authoritative): `role: "CorgiroReadOnlyRole"`, `via: "assume-role"`, `readOnlyEnforced: true`. `readOnlyEnforced` is `true` on this path exactly as it is under Identity Center — the member-account privilege boundary is `CorgiroReadOnlyRole`, which is unaffected by how the operator authenticated.

Then return to setup **MODE.md Step 3 (Validate access & finalize)**, which validates `CorgiroReadOnlyRole` assumption across all accounts and writes the coverage snapshot. Its residual-risk summary must include the IdP-side entitlement note from [`credential-resolution.md`](../../../references/credential-resolution.md#residual-risk-saml-external).
