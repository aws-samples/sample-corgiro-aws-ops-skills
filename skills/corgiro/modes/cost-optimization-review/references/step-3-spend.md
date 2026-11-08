# Step 3: Analyze Spend

One call set, from the CE source account resolved in Step 2. This is the only
step that touches Cost Explorer.

## Why `AmortizedCost` is the default

`UnblendedCost` classifies No Upfront RI recurring charges as "On Demand
Instances", because the hourly fee is billed after usage. A customer at 80% RI
coverage can look like 20%. `AmortizedCost` attributes commitment spend
correctly.

Use `NetAmortizedCost` when the operator wants negotiated-discount-adjusted
figures. Use `UnblendedCost` only on explicit request, and state the caveat.

## Resolve `services` first, if it is set

CE service names are exact strings (`Amazon Relational Database Service`, not
"RDS"). Do not construct them. Enumerate what the customer actually spends on and
match against that:

```bash
aws ce get-dimension-values \
  --dimension SERVICE \
  --time-period Start=<lookback_start>,End=<this_month_start> \
  --billing-view-arn <billingViewArn> \
  --region us-east-1 --output json
```

Match each operator-supplied name case-insensitively against the returned values
and their obvious short forms. One unambiguous match resolves silently. Zero
matches, or more than one, is a question:

> "`RDS` could be: Amazon Relational Database Service, Amazon RDS Service Proxy.
>  Which did you mean?"

Never substitute a near match on the operator's behalf. Record both the input and
the resolved CE value in `scope.json`.

With `services` resolved, `top_n` and `min_finding_usd` apply **within** the
filtered set. Otherwise a drill-down into RDS would return the top 10 lines
org-wide and then discard the ones that are not RDS.

## Call 1: the cost lines

```bash
aws ce get-cost-and-usage \
  --time-period Start=<lookback_start>,End=<this_month_start> \
  --granularity MONTHLY \
  --metrics AmortizedCost UsageQuantity \
  --group-by '[
    {"Type":"DIMENSION","Key":"USAGE_TYPE"},
    {"Type":"DIMENSION","Key":"PURCHASE_TYPE"}
  ]' \
  --filter '{"And":[
      {"Not":{"Dimensions":{"Key":"RECORD_TYPE",
               "Values":["Credit","Refund","Tax"]}}},
      {"Dimensions":{"Key":"SERVICE","Values":["<resolved>","..."]}},
      {"Dimensions":{"Key":"LINKED_ACCOUNT","Values":["<accounts_resolved>"]}}
    ]}' \
  # drop the SERVICE clause when services = all
  # drop the LINKED_ACCOUNT clause when accounts = all
  # drop the And wrapper when neither applies
  --billing-view-arn <billingViewArn>   # omit when null
  --region us-east-1 --output json
```

`UsageQuantity` is requested alongside cost because Step 4 needs it twice: to
cross-check the unit against the price record, and to derive the effective rate.

Paginate on `NextPageToken` until exhausted.

## Call 2: where each line sits

For the lines that survive `top_n` and `min_finding_usd`, attribute them:

```bash
aws ce get-cost-and-usage \
  --time-period Start=<lookback_start>,End=<this_month_start> \
  --granularity MONTHLY --metrics AmortizedCost UsageQuantity \
  --group-by '[
    {"Type":"DIMENSION","Key":"LINKED_ACCOUNT"},
    {"Type":"DIMENSION","Key":"REGION"}
  ]' \
  --filter '{"Dimensions":{"Key":"USAGE_TYPE","Values":["<code>"]}}' \
  --billing-view-arn <billingViewArn> \
  --region us-east-1 --output json
```

Two grouping dimensions is the API maximum, which is why account and region come
from a second call filtered to the selected codes rather than from one wide call.

Drop the `NoRegion` / `global` pseudo-region from the region set, but keep its
cost in the line total.

### Measure cost coverage here

The distinct `LINKED_ACCOUNT` values this call returns are the accounts the CE
source account can actually see cost for. Count them and compare to the roster:

```
accounts_with_cost   distinct LINKED_ACCOUNT values returned
accounts_in_roster   roster size after account_filter
```

Both go in `spend-profile.json` and in the report header. This replaces any
attempt to classify what the CE source account "is": a payer, a Billing
Conductor billing-group primary whose group spans every account, and a single
account all report their true coverage through the same count, with no need to
understand their topology.

A roster account with no cost in the window is normal (new account, billing lag)
and is not a coverage gap. A roster account the CE source cannot see at all is a
coverage gap, and the report says which.

## Call 3: precise coverage, for commitment-eligible lines only

`PURCHASE_TYPE` gives a readable On Demand / Reserved / Savings Plans split, which
is what the gate displays. For the coverage figure that feeds the realizable
saving, use `RECORD_TYPE`, which separates covered usage from the commitment fee:

```bash
aws ce get-cost-and-usage \
  --time-period Start=<lookback_start>,End=<this_month_start> \
  --granularity MONTHLY --metrics AmortizedCost UsageQuantity \
  --group-by '[
    {"Type":"DIMENSION","Key":"USAGE_TYPE"},
    {"Type":"DIMENSION","Key":"RECORD_TYPE"}
  ]' \
  --filter '{"Dimensions":{"Key":"USAGE_TYPE","Values":["<code>"]}}' \
  --billing-view-arn <billingViewArn> \
  --region us-east-1 --output json
```

```
coverage = SavingsPlanCoveredUsage / (SavingsPlanCoveredUsage + Usage)
```

`DiscountedUsage` is the RI equivalent. `SavingsPlanRecurringFee`,
`SavingsPlanNegation`, `RIFee` and `Fee` are commitment accounting lines, not
usage: exclude them from the denominator.

Skip this call for lines on services that cannot be covered by a commitment
(NAT, data transfer, EIP, S3, CloudWatch). An empty result there is not a gap.

## Optional: spike attribution

Only when the operator asked why costs changed:

```bash
aws ce get-cost-comparison-drivers \
  --baseline-time-period Start=<prev_start>,End=<prev_end> \
  --comparison-time-period Start=<curr_start>,End=<curr_end> \
  --metric-for-comparison AmortizedCost \
  --region us-east-1 --output json

aws ce get-anomalies --date-interval StartDate=<start>,EndDate=<end> \
  --region us-east-1 --output json
```

`get-cost-comparison-drivers` returns the factors driving change between two
periods within the last 13 months (38 with multi-year data enabled), including
usage changes, discount changes and commitment-based savings. Prefer it over
hand-rolled month-over-month arithmetic.

## Build the spend profile

Per usage-type code, aggregate across months:

```json
{
  "code":            "NatGateway-Bytes",
  "monthly_avg":     12400.00,
  "usage_quantity":  410000,
  "ce_unit":         "GB",
  "purchase_mix":    { "On Demand": 100.0, "Savings Plans": 0.0, "Reserved": 0.0 },
  "accounts":        ["111111111111", "222222222222"],
  "regions":         ["us-east-1"]
}
```

Rank by `monthly_avg` descending. Select the top `top_n` lines at or above
`min_finding_usd`.

### No lines are excluded

Every line above `min_finding_usd` proceeds to decode. The purchase mix does not
disqualify a line, it selects which lever classes are worth researching:

| Purchase mix | Lever classes worth researching |
|---|---|
| mostly On Demand on a commitment-eligible service | configuration, **commitment**, capacity |
| mostly Reserved or Savings Plans | configuration, capacity. A commitment lever is already taken. |
| On Demand on a non-eligible service (NAT, data transfer, EIP, S3, CloudWatch) | configuration only |

A commitment-*covered* line is analyzed like any other. Step 6 reports a reduced
realizable saving rather than dropping the finding, because an idle resource is
waste whether or not a commitment currently pays for it.

### Carry `purchase_mix` forward

Step 6 needs it. A lever that eliminates commitment-covered usage does not
reduce the bill until the freed commitment is absorbed elsewhere or the plan
expires, so gross saving and realizable saving diverge. The mix is what tells
them apart.

## Confirmation gate

Present the profile and take one confirmation. The cost lines are unknown until
now, so this is the first point at which a question has information behind it.

```
SPEND PROFILE   cost: 14 of 14 roster accounts · 4 regions · AmortizedCost
                rate basis: chargeable
                CE source 111111111111 (org) · Aug-Oct 2026
                services: all

 #  usage type                 $/mo      purchase mix        accounts
 1  NatGateway-Bytes         12,400      OD 100%             2
 2  BoxUsage:m6i.large        9,800      SP 94% / OD 6%      5
 3  USE2-USW2-AWS-Out-Bytes   6,200      OD 100%             3
 4  EBS:VolumeUsage.gp2       4,100      OD 100%             7
 ...
10  CW:Requests                 640      OD 100%             4

 below min_finding_usd ($100):        31 lines, $1,480/mo total

 Next: decode 9 lines, research their levers, verify across 14 accounts.
 Estimate: 9 pricing calls · ~25 doc fetches · ~150 describe calls.

 Proceed, adjust (top_n / min_finding_usd / drop or add lines), or cancel?
```

Wait for explicit approval. Edits re-render the gate. Steps 4 through 7 then run
unattended.

Three reasons the gate sits here and not at Step 2: the operator may know line 3
is an accepted workload, the purchase-mix column changes priorities in a way no
default could predict, and Steps 5 and 6 are the slow parts so their volume
should be visible before they start.

## Persist

Write `spend-profile.json` with the ranked lines, the deferred lines, the
below-threshold total, and the approved selection.
