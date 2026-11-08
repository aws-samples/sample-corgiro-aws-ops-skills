# Access Pattern

The executable matrix for this mode. Every step cites this reference rather than
restating credentials, metrics, or source accounts inline — so there is one place
to change the rules and no quiet drift between prose.

## Credential matrix

Which credential each API call uses, and from which account. All member-account
credentials come from `credential-resolution.md` (`CorgiroReadOnlyRole` via
AssumeRole under `cross-account-role`, or the per-account SSO profile under
`identity-center-direct` — this mode does not care which, provided the roster
entry resolves).

| API | Credential | Source account | Notes |
|---|---|---|---|
| `pricing:GetProducts`, `DescribeServices`, `GetAttributeValues` | `CorgiroReadOnlyRole` | Tooling account (preferred), or any roster member | Account-agnostic. Pin to tooling so decode calls do not scatter across customer workload accounts in CloudTrail. See [`../../../references/aws-pricing-grounding.md`](../../../references/aws-pricing-grounding.md). |
| `billing:ListBillingViews` | `CorgiroReadOnlyRole` | The account under examination | Used to derive `rate_basis` per tier. Returns only views the caller can see. |
| `ce:*` — tier 1 (payer) | `CorgiroReadOnlyRole` | Organization management account, if the role has been manually deployed there | Service-managed StackSets cannot target the management account; this is an optional post-setup step. Falls through to tier 2 if the role is absent. |
| `ce:*` — tier 2 (BC primary) | `CorgiroReadOnlyRole` | Billing Conductor primary account, if one exists and is in the roster | Detected by probing each roster account's `ListBillingViews` for a `BILLING_GROUP` view. |
| `ce:*` — tier 3 (per-account) | `CorgiroReadOnlyRole` | Each roster account, in its own fan-out | Last resort. Covers every account Corgiro can reach, at the cost of one CE query shape per account. |
| `describe` / `list` on resource services | `CorgiroReadOnlyRole` | The account that owns the resource | Fan-out per [`../../../references/credential-resolution.md`](../../../references/credential-resolution.md). |
| `cloudwatch:GetMetricData`, `ListMetrics` | `CorgiroReadOnlyRole` | The account that owns the resource | Same. |
| `compute-optimizer:Get*Recommendations` | `CorgiroReadOnlyRole` | The account that owns the resource | Call per-account during fan-out, not org-wide from a payer. |

**Never use the base operator profile for an API call in this mode.** The
operator profile is a `CorgiroOperator` permission set used only to assume
`CorgiroReadOnlyRole`. It does not carry `pricing:*`, `ce:*`, `billing:*`, or
most `describe`/`list` actions, and its `AccessDenied` error reads as a
capability gap when the real problem is the credential choice — exactly the
class of error this reference exists to prevent.

**Never reach the payer through the operator's own Identity Center assignment**
to work around the absence of `CorgiroReadOnlyRole` in the management account.
That path bypasses the member-account boundary that `readOnlyEnforced: true`
rests on, and attributes reads in CloudTrail to an SSO user session rather
than a `corgiro-<operator>-<run_id>` role session. The correct response to an
absent management-account role is the hard-stop message in Step 2 with its
remediation instructions, not a credential detour.

## Cost Explorer source cascade

Cost analysis has one preferred source per deployment. Attempt each tier with
`CorgiroReadOnlyRole` and `metric: AmortizedCost`. A tier is **succeeded** only
when the metric-bearing query returns data; `AccessDenied` on AssumeRole, an
absent role, and `DataUnavailableException` on the metric all count as **failed**
and move to the next tier.

```
tier 1 — payer
  attempt     AssumeRole into CorgiroReadOnlyRole in the roster's management
              account; ce:GetCostAndUsage with AmortizedCost
  succeed     rate_basis = chargeable; scope is org-wide
  fail        AccessDenied (role not deployed) or DataUnavailableException
              -> tier 2

tier 2 — Billing Conductor primary
  attempt     for each reachable roster account (ascending size of the
              expected spend, or any stable order), call billing:ListBillingViews
              under CorgiroReadOnlyRole; the first account whose views include
              a billingViewType == "BILLING_GROUP" is a BC primary
  succeed     rate_basis = proforma; the billing-group view ARN is
              passed on every ce:* call via --billing-view-arn
  fail        no roster account returns a BILLING_GROUP view -> tier 3

tier 3 — per-account
  attempt     fan out ce:GetCostAndUsage under CorgiroReadOnlyRole into each
              reachable roster account with AmortizedCost
  succeed     every (or almost every, per the partial-tier-3 rule below)
              account returns data; rate_basis = chargeable; scope is
              per-account, aggregated
  fail        DataUnavailableException on AmortizedCost from all accounts
              -> hard stop

none         hard stop; see the hard-stop message below
```

Operator confirmation is retained as an **override**, not the primary path.
The cascade's result is presented at the end of Step 2; the operator can name
a different reachable roster account as the CE source, and the mode uses
whichever ARN the cascade would have attached (per-account for tier 3; billing
view for tier 2; nothing for tier 1 via the management account).

## Partial tier 3

Tier 3 is the only tier that can succeed partially — one member account may
return `DataUnavailableException` while others succeed. The rule for this case
is **honest coverage at the Step 3 gate**, not silent proceeding and not strict
abort:

- Record every failing account in `scope.json` with its exception.
- Report `accounts_visible` at the Step 3 gate as `<succeeded> of <in-scope>`.
- Proceed only after the operator confirms, exactly like the service-selection
  gate; the gate wording states that partial coverage was observed and names
  the missing accounts.
- The report header carries the same figures. A run that covered 4 of 6
  accounts is never captioned "organization-wide".

A hard failure of tier 3 (zero accounts return data for `AmortizedCost`) hits
the hard-stop below.

## Metric rule

**`AmortizedCost` is the only automatic metric.** No tier silently falls back
to `UnblendedCost` on `DataUnavailableException`. The reasoning in
`step-3-spend.md` for preferring amortized is sound at every tier that can
return it, and silently degrading to unblended would:

- misattribute No Upfront RI recurring charges to On Demand, which is the
  problem the amortized metric exists to solve;
- make Step 3 Call 4's commitment-coverage figure unreliable whenever coverage
  is non-zero;
- hide the degradation from the report reader.

The operator may pass `--metric UnblendedCost` as an **explicit override**.
When set, the override runs tier 3 only (the other tiers can always return
amortized), skips the hard stop, and the report header records that the
override was used, with the caveat above stated in the Methodology section.
`--metric NetAmortizedCost` and `--metric NetUnblendedCost` are accepted on
the same path as their default-metric counterparts.

## Hard stop

When every tier fails on `AmortizedCost`, the mode stops and prints a message
of this exact shape (with values resolved for the deployment at hand):

```
Cost Explorer with AmortizedCost returned no data from any sanctioned source:

  tier 1 — payer <mgmt_account_id>
    CorgiroReadOnlyRole not present in the organization management account
    (service-managed StackSets cannot target the management account under
    cross-account-role deployments; this must be a manual deploy).

    fix: an administrator in <mgmt_account_id> runs this ONCE, from that
    account, with cloudformation:CreateStack and iam:CreateRole permissions:

      aws cloudformation create-stack \
        --stack-name CorgiroReadOnlyRole \
        --template-body file://<assets>/corgiro-readonly-role.yaml \
        --parameters \
            ParameterKey=ToolingAccountId,ParameterValue=<tooling_account_id> \
            ParameterKey=ExternalId,ParameterValue=<external_id> \
        --capabilities CAPABILITY_NAMED_IAM \
        --region us-east-1

      aws cloudformation wait stack-create-complete \
        --stack-name CorgiroReadOnlyRole --region us-east-1

    The template is the same corgiro-readonly-role.yaml used by the
    org-wide StackSet. The role carries the same guard rails; it just
    lives in a different account because AWS requires it.

    Then re-run /corgiro account-coverage to refresh the roster, and
    this mode will pick up tier 1 on the next invocation.

  tier 2 — Billing Conductor primary
    No roster account returned a billingViewType == BILLING_GROUP view.
    This is normal for organizations that are not on Billing Conductor.

  tier 3 — per-account
    DataUnavailableException on AmortizedCost from every reachable roster
    account.

    fix: in the payer, enable Cost Management Preferences -> General ->
    "Linked account discounts". CE refreshes within 24 hours
    (https://docs.aws.amazon.com/cost-management/latest/userguide/ce-enable.html).

Hard stop. No cost source with the required metric is reachable.

Override: --metric UnblendedCost runs tier 3 anyway. This misattributes
No Upfront RI recurring charges to On Demand and makes commitment-coverage
figures unreliable when coverage is non-zero. The report records the
override in its header.
```

The message is load-bearing for correctness, not just helpfulness: it is the
only place in the skill that documents the manual management-account deploy.
Keep the template path, parameters, and verification step complete and
self-contained.

## Overview and drill phases

This mode has two phases with different access profiles. Both resolve their
credentials through the matrix above; what differs is which calls run.

```
overview phase       Steps 1-3 at service granularity (SERVICE grouping,
                     no decode, no describe). Needs only the CE cascade and
                     pricing is not called. Independently useful; can be
                     the entire run via --overview-only.

drill phase          Operator picks ONE service from the overview. Steps 3
                     drill-down + 4 (decode) + 5 (research) + 6 (confirm)
                     + 7 (report) run against that service. Pricing fires
                     from the tooling account; describe/CloudWatch/CO fan
                     out across the accounts holding the chosen service's
                     spend.
```

One service per drill, full stop. A second service is a second run.
`--service <name>` skips the overview phase and runs the drill directly, for
operators who already know what they want to analyze.

## What this reference does not cover

- The base operator session mechanism (how the operator signs in to produce
  the session that assumes `CorgiroReadOnlyRole`). That is in
  [`../../../references/credential-resolution.md`](../../../references/credential-resolution.md)
  under `authMethod`, and is unchanged by this mode.
- IAM role deployment. That is in the `setup-corgiro` mode and its
  `option-b-cross-account.md` reference. The one gap — manual
  management-account deployment — is handled by the hard-stop message above.
- Call budgets and rate limiting. Those are in
  [`../../../references/cross-account-defaults.md`](../../../references/cross-account-defaults.md).
