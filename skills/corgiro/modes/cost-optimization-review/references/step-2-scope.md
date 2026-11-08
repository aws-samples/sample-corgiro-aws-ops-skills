# Step 2: Resolve Scope and the CE Source Account

Two independent things: which accounts the evidence comes from, and which single
account the cost comes from.

## Terminology

- **CE source account** -- the account Cost Explorer is queried from.

There is deliberately no label for "what it can see". Coverage is measured, not
classified: Step 3 counts the distinct `LINKED_ACCOUNT` values Cost Explorer
actually returns and compares them to the roster. "14 of 14 accounts" is more
honest than a category, and it works identically for a payer, a Billing
Conductor primary and a single account without Corgiro needing to understand
any of their topologies.

## Accounts for evidence (Step 6)

Read `~/.corgiro/state/roster.json`. Take every entry with `reachable: true`, or
every entry if the snapshot lacks the field (reachability is re-checked
implicitly on the first call). Apply `account_filter` from config.

Credential dispatch stays in
[`../../../references/credential-resolution.md`](../../../references/credential-resolution.md).
Do not restate it.

## The CE source account: ask once, cache, never detect

**Detection is harmful here, not merely unreliable.** Customers billed through a
distributor or solution provider have no access to the payer: it belongs to the
distributor and carries the distributor's discount. The distributor gives them a
Billing Conductor primary account instead. For those customers
`organizations:describe-organization` returns the **distributor's**
`MasterAccountId`, an account they can never reach on any access mode. Corgiro
would confidently name the wrong account.

Corgiro also cannot discover the Billing Conductor path itself.
`billing:ListBillingViews` is the right primitive, but
`corgiro-operator-role.yaml` grants no `billing:*` or `billingconductor:*`
(and `ce:List*` does not cover it, the action is in the `billing` namespace), and
the operator role lives in the tooling account, which is not the billing-group
primary.

So ask, once, and cache the answer:

> "Which account should I read organization-wide cost from?
>  1. the payer / management account
>  2. the account where you view your organization's bill, if you are billed
>     through a distributor or solution provider
>  3. this account only"

The operator does not need to know what Billing Conductor is to answer option 2,
and Corgiro does not need to know either. The verification step below determines
what that account can actually see.

Cache under a `costAnalysis` block in `~/.corgiro/config.json`:

```json
"costAnalysis": {
  "ceSourceAccountId": "111111111111",
  "billingViewArn":    null,
  "rateBasis":         "chargeable"
}
```

> Any new config key must also be documented in
> [`../../../references/cross-account-defaults.md`](../../../references/cross-account-defaults.md).
> Writing keys that `setup-corgiro` never creates is an existing defect
> elsewhere in the repo and must not be repeated.

## Verify, do not trust

The answer names an account. Confirm Corgiro can actually use it.

```bash
# 1. the named account must be in the roster and reachable
#    (resolve credentials per credential-resolution.md, then:)
aws sts get-caller-identity

# 2. Cost Explorer must answer from it
aws ce get-cost-and-usage \
  --time-period Start=<last_month_start>,End=<this_month_start> \
  --granularity MONTHLY --metrics AmortizedCost \
  --region us-east-1 --output json

# 3. which billing views does THIS account see?
aws billing list-billing-views --output json
```

Call 3 is self-describing: it returns only views the caller can see, and
`billingViewType` is one of
`PRIMARY | BILLING_GROUP | CUSTOM | BILLING_TRANSFER | BILLING_TRANSFER_SHOWBACK`.

| Result | Action |
|---|---|
| a `BILLING_GROUP` view is present | use its `arn` as `BillingViewArn` and set `rateBasis: proforma`. |
| only `PRIMARY` | `rateBasis: chargeable`. |
| call denied, or `billing:*` absent from `ReadOnlyAccess` | ask the operator for the billing view ARN. Nothing else changes. |

Pass the resolved ARN as `BillingViewArn` on `ce:GetCostAndUsage` so the scope is
explicit rather than implied by whichever account happened to be used.

> **`rateBasis` is derived, never offered as a choice.** A Billing Conductor
> billing group member "cannot view historical, billable cost and usage data in
> Cost Explorer"
> (https://docs.aws.amazon.com/help-panel/billingconductor/latest/console/hp-billing-group-type.html),
> so when a `BILLING_GROUP` view is present, proforma is the only view available
> and the report states it as a fact. Do not ask the operator to pick between
> chargeable and proforma: on this path there is nothing to pick.

> **Commitment coverage stays valid at billing-group scope.** A billing group's
> "pro forma usage is computed as its own consolidated billing family", sharing
> Reserved Instance and Savings Plans benefits "only within the group"
> (https://docs.aws.amazon.com/billingconductor/latest/userguide/creating-abc.html).
> So the coverage figure measured from a billing-group view is the correct one
> for those accounts, not a degraded proxy for a payer-wide number.

If calls 1 or 2 fail, **re-ask**. Do not silently fall back to a narrower scope:
a per-account sweep presented as organization-wide is worse than a hard stop.
If no option works, hard stop. Report which accounts were tried and the three
options from `MODE.md` Prerequisites. Do not propose provisioning new access:
extending coverage to the payer is a setup decision for whoever provisioned
Corgiro.

## Regions

`regions = auto`: take the regions that appear in the Step 3 spend profile. No
separate discovery call is needed, because Step 3 already groups by `REGION` from
the same account.

`regions` explicit: use the list as given, and note in `scope.json` that regions
were not derived from spend.

Global products (IAM, S3 bucket inventory, Route 53, CloudFront, Organizations)
carry no region dimension. Drop it rather than inventing one.

## Persist

Write `scope.json`:

```json
{
  "run_id":            "cost-optimization-review-20261108-184500",
  "access_mode":       "cross-account-role",
  "ce_source_account": "111111111111",
  "billing_view_arn":  null,
  "rate_basis":        "chargeable",
  "metric":            "AmortizedCost",
  "lookback_months":   3,
  "services":          "all",
  "services_resolved": [],
  "top_n":             10,
  "min_finding_usd":   100,
  "accounts_in_roster": 14,
  "accounts_in_scope":  14,
  "regions":           "auto",
  "account_filter":    { "include": [], "exclude": [] },
  "skipped":           []
}
```

`accounts_in_roster` is the evidence fan-out set, from the roster. It is not the
same as cost coverage: Step 3 separately counts the accounts Cost Explorer
returns cost for, and both numbers appear in the report header. A run covering 9
of 14 accounts is not an organization-wide analysis and must not read like one.
