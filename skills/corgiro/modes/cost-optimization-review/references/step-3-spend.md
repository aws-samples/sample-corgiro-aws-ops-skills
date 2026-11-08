# Step 3: Analyze Spend

One call set, from the CE source account resolved in Step 2. This is the only
step that touches Cost Explorer.

## Why `AmortizedCost` is the default

`UnblendedCost` classifies No Upfront RI recurring charges as "On Demand
Instances", because the hourly fee is billed after usage. A customer at 80% RI
coverage can look like 20%. `AmortizedCost` attributes commitment spend
correctly. Same default and same rationale as `ri-sp-coverage-analysis`.

Use `NetAmortizedCost` when the operator wants negotiated-discount-adjusted
figures. Use `UnblendedCost` only on explicit request, and state the caveat.

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
  --filter '{"Not":{"Dimensions":{"Key":"RECORD_TYPE",
             "Values":["Credit","Refund","Tax"]}}}' \
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

### Apply the two deferrals here, before decoding

- `purchase_mix` is predominantly `Savings Plans` or `Reserved`, or the line is
  unused commitment -> do not decode it as an optimization target. Record it and
  point at `ri-sp-coverage-analysis`.
- The code is EC2 instance usage (`BoxUsage:*`, `*-BoxUsage:*`) -> point at
  `ec2-compute-review`.

Record every deferred line in the profile so the report accounts for the whole
bill, not only the part this mode handles.

### Carry `purchase_mix` forward

Step 6 needs it. A lever that eliminates commitment-covered usage does not
reduce the bill until the freed commitment is absorbed elsewhere or the plan
expires, so gross saving and realizable saving diverge. The mix is what tells
them apart.

## Confirmation gate

Present the profile and take one confirmation. The cost lines are unknown until
now, so this is the first point at which a question has information behind it.

```
SPEND PROFILE   14 of 14 accounts · 4 regions · AmortizedCost · chargeable
                CE source 111111111111 (org) · Aug-Oct 2026

 #  usage type                 $/mo      purchase mix        accounts
 1  NatGateway-Bytes         12,400      OD 100%             2
 2  BoxUsage:m6i.large        9,800      SP 94% / OD 6%      5   -> deferred
 3  USE2-USW2-AWS-Out-Bytes   6,200      OD 100%             3
 4  EBS:VolumeUsage.gp2       4,100      OD 100%             7
 ...
10  CW:Requests                 640      OD 100%             4

 deferred to ri-sp-coverage-analysis:  1 line,  $9,800/mo
 deferred to ec2-compute-review:       0 lines
 below min_finding_usd ($500):        23 lines, $3,210/mo total

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
