# Step 0: Prerequisite Check

Run these checks **before** prompting the user. Do not display the check list. If any fails, stop with a clear error. First read `accessMode` from `~/.corgiro/config.json`, then run the checks for that mode.

## Common

1. **Credentials resolve**: `aws sts get-caller-identity`

## Path B — `cross-account-role`

2. **Caller is management or delegated admin for Health**:
   - Get caller account from `get-caller-identity`
   - `aws organizations describe-organization --query 'Organization.MasterAccountId' --output text`
   - If not management: `aws organizations list-delegated-administrators --service-principal health.amazonaws.com --query 'DelegatedAdministrators[].Id' --output text`
3. **Trusted access enabled** for `health.amazonaws.com`:
   ```bash
   aws organizations list-aws-service-access-for-organization \
     --query "EnabledServicePrincipals[?ServicePrincipal=='health.amazonaws.com']" \
     --output text
   ```
4. **Health org API reachable** (also surfaces support-plan / permission errors):
   ```bash
   aws health describe-events-for-organization \
     --region us-east-1 \
     --max-results 1
   ```

   - `SubscriptionRequiredException` → management account not on a supported Support plan
   - `AccessDeniedException` → missing `health:Describe*ForOrganization` permissions, or org access not enabled (`EnableHealthServiceAccessForOrganization`)

## Path A — `identity-center-direct`

2. **Roster exists**: `~/.corgiro/state/roster.json` is present and fresh (else run `/corgiro account-coverage`).
3. **Per-account reachability is tested during fetch** — do not probe every account here. Each account needs Business / Enterprise On-Ramp / Enterprise Support; accounts that return `SubscriptionRequiredException` in Step 3 are skipped and reported. A quick single-account validity check is optional:
   ```bash
   aws health describe-events --region us-east-1 --profile corgiro-<one-account-id> --max-results 1
   ```

## Error output format

```
Prerequisite check failed: <short reason>

Cause: <one-line explanation>
Fix:   <actionable remediation>
Docs:  <link to relevant AWS doc>
```
