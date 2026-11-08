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

## Resolve `accounts` first: it decides everything else

Read `~/.corgiro/state/roster.json`, then resolve the analysis set:

- **Org-wide (default)** -- `accounts` omitted or `all`: every roster entry with
  `reachable: true`, or every entry if the snapshot lacks the field (reachability
  is re-checked implicitly on the first call).
- **Specific accounts** -- `accounts` is a list of account IDs or roster names.
  Resolve each entry against the roster:
  - a 12-digit ID present in the roster resolves directly
  - a name is matched case-insensitively against roster `name` values. One
    unambiguous match resolves silently; zero or several is a question, listing
    the candidates. Never guess which account was meant.
  - an ID or name not in the roster is skipped and recorded as `not_in_roster`.
    Corgiro can only reach accounts set up by `setup-corgiro` and refreshed by
    `account-coverage`.

Apply `account_filter` from config on top of either set.

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

Resolve one CE source account on every run, regardless of what `accounts` is set
to. Ask the operator; never detect it.

> "Which account should I read cost from? Give me the account ID.
>
>  Usually your payer or management account. If you are billed through a
>  distributor or solution provider, it is the account where you view your
>  organization's bill."

One question, one answer type. The operator does not need to know what Billing
Conductor is, and Corgiro does not need to know either: the verification step
below determines what that account can actually see.

> **Resolve the source even for a scoped analysis.** Reading one source and
> adding a `LINKED_ACCOUNT` filter is strictly better than querying each
> account's own Cost Explorer: one rate basis, far fewer requests, and no
> dependence on the payer having enabled member-account access, which is an
> org-wide all-or-none setting. Skipping the question on a scoped run only defers
> it, and the deferred version fails mid-run after burning calls. Per-account
> Cost Explorer is a fallback, never a default.

**Do not write this to `~/.corgiro/config.json`.** Only `setup-corgiro` and
`account-coverage` write there, and a mode that invents config keys creates state
nothing else knows how to manage. Record the answer in the run's `scope.json`
instead, and ask again next run.

If the operator wants to stop being asked, the right fix is for `setup-corgiro`
to collect it, which is a separate change to that mode.

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

## Regions are not resolved here

`regions` is resolved in Step 3, because that is where the data appears: the
spend profile already groups by `REGION` from the same account, so no separate
discovery call is needed. Step 2 records the parameter value and nothing more.

## Persist

Write `scope.json`. `regions_resolved` is left `null` and filled in by Step 3:

```json
{
  "run_id":            "cost-optimization-review-20261108-184500",
  "access_mode":       "cross-account-role",
  "ce_source_account": "111111111111",
  "billing_view_arn":  null,
  "rate_basis":        "chargeable",
  "metric":            "AmortizedCost",
  "lookback_months":   3,
  "accounts":           "all",
  "accounts_in_scope":  [],
  "not_in_roster":      [],
  "services":          "all",
  "services_resolved": [],
  "top_n":             10,
  "min_finding_usd":   100,
  "regions":           "auto",
  "regions_resolved":  null,
  "account_filter":    { "include": [], "exclude": [] },
  "skipped":           []
}
```

Two counts, deliberately distinct, and both printed in the report header:

```
accounts_in_scope   written here. The evidence fan-out set: roster entries
                    matching `accounts`, after account_filter.
accounts_visible    written by Step 3. The accounts Cost Explorer actually
                    returns cost for from the CE source account.
```

They are not interchangeable. `accounts_in_scope` says where Step 6 will look;
`accounts_visible` says how much of the bill Step 3 could see. A run where
`accounts_visible` is 9 of 14 is not an organization-wide analysis and must not
read like one.
