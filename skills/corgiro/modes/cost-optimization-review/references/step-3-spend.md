# Step 3: Analyze Spend

All Cost Explorer calls for the analysis run here, from the CE source account
resolved in Step 2. Step 2 issues one small CE probe to verify that account is
usable; this step does the work.

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
      {"Dimensions":{"Key":"SERVICE","Values":["<services_resolved>"]}},
      {"Dimensions":{"Key":"LINKED_ACCOUNT","Values":["<accounts_in_scope>"]}}
    ]}' \
  --billing-view-arn <billing_view_arn> \
  --region us-east-1 --output json
```

Filter assembly, applied before the call is built:

| Condition | Change to `--filter` |
|---|---|
| `services = all` | drop the `SERVICE` clause |
| `accounts = all` | drop the `LINKED_ACCOUNT` clause |
| both of the above | drop the `And` wrapper, leaving the bare `Not` clause |
| `billing_view_arn` is null | omit `--billing-view-arn` entirely |

`UsageQuantity` is requested alongside cost because Step 4 needs it twice: to
cross-check the unit against the price record, and to derive the effective rate.

Paginate on `NextPageToken` until exhausted.

### Both metrics are per-month averages

Aggregate across the lookback window by **averaging, not summing**, and average
cost and quantity the same way:

```
monthly_avg     = sum(AmortizedCost  over N months) / N
usage_quantity  = sum(UsageQuantity  over N months) / N
```

Step 4 divides one by the other to get the effective unit rate, so mixing a sum
with an average understates the rate by a factor of `lookback_months`. Record
`lookback_months` on the profile so the arithmetic is auditable.

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

Keep `NoRegion` / `global` cost in each line's total; it is excluded only from
the resolved region set, below.

### Resolve regions here

The `REGION` grouping in this call is the region data, so `regions` resolves from
it rather than from a separate discovery call.

```
regions = auto        take the distinct REGION values this call returned
regions = explicit    use the list as given, and record in scope.json that
                      regions were not derived from spend
```

Drop the `NoRegion` / `global` pseudo-region from the resolved set, and drop the
region dimension entirely for global products (S3 bucket inventory, Route 53,
CloudFront) rather than inventing one.

Write the result back to `scope.json` as `regions_resolved`. Step 6's fan-out
uses that, not the raw parameter.

## Call 3: how many accounts the CE source can actually see

One cheap call, grouped by `LINKED_ACCOUNT` alone and **not** filtered to the
selected usage types:

```bash
aws ce get-cost-and-usage \
  --time-period Start=<lookback_start>,End=<this_month_start> \
  --granularity MONTHLY --metrics AmortizedCost \
  --group-by '[{"Type":"DIMENSION","Key":"LINKED_ACCOUNT"}]' \
  --billing-view-arn <billing_view_arn> \
  --region us-east-1 --output json
```

> **Do not derive this from Call 2.** Call 2 is filtered to the selected
> usage types, so its `LINKED_ACCOUNT` values are "accounts with cost in the
> analyzed lines", not "accounts the CE source can see". An account with
> substantial spend entirely outside the top `top_n` would be counted as
> invisible, understating coverage and misreporting the run as narrower than it
> was.

```
accounts_visible    distinct LINKED_ACCOUNT values from THIS call
accounts_in_scope   accounts resolved in Step 2, after account_filter
```

Both go in `spend-profile.json` and the report header. This replaces any attempt
to classify what the CE source account "is": a payer, a Billing Conductor
billing-group primary whose group spans every account, and a single account all
report their true coverage through the same count, with no need to understand
their topology.

A roster account visible to the CE source but with no cost in the window is
normal (new account, billing lag) and is not a coverage gap. A roster account the
CE source cannot see at all is a coverage gap, and the report names it.

## Call 4: precise commitment coverage, for commitment-eligible lines only

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
  "lookback_months": 3,
  "ce_unit":         "GB",
  "purchase_mix":    { "On Demand": 100.0, "Savings Plans": 0.0, "Reserved": 0.0 },
  "accounts":        ["111111111111", "222222222222"],
  "regions":         ["us-east-1"]
}
```

Rank by `monthly_avg` descending. Select the top `top_n` lines at or above
`min_finding_usd`.

### No lines are excluded; the purchase mix selects lever classes

Every line above `min_finding_usd` proceeds to decode. The mix does not
disqualify a line, it narrows what is worth researching in Step 5:

| Purchase mix | Lever classes worth researching |
|---|---|
| mostly On Demand on a commitment-eligible service | configuration, **commitment**, capacity |
| mostly Reserved or Savings Plans | configuration, capacity. A commitment lever is already taken. |
| On Demand on a non-eligible service (NAT, data transfer, EIP, S3, CloudWatch) | configuration only |

Carry `purchase_mix` forward: Step 6 needs it to separate gross from realizable
saving, because a lever that eliminates commitment-covered usage does not reduce
the bill until the freed commitment is absorbed or the plan expires. An idle
resource is still waste whether or not a commitment currently pays for it, which
is why the line is analyzed rather than dropped.

## Confirmation gate

Present the profile and take one confirmation. The cost lines are unknown until
now, so this is the first point at which a question has information behind it.

```
SPEND PROFILE   CE source 111111111111 · rate basis chargeable · AmortizedCost
                visible: 14 of 14 accounts in scope · 4 regions
                Aug-Oct 2026 (3 months) · services: all

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

The gate sits here rather than at Step 2 because this is the first point with
information behind it: the operator can drop a line they know is an accepted
workload, and the purchase-mix column changes priorities in a way no default
could predict.

## Persist

Write `spend-profile.json`: the ranked lines, the below-threshold total,
`accounts_visible`, `lookback_months`, and the selection the operator approved.
Write `regions_resolved` back to `scope.json`.
