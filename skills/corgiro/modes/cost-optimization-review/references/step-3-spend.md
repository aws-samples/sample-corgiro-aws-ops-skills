# Step 3: Analyze Spend

This step runs in two phases that share Step 1 and Step 2 and diverge here:

- **Overview** — rank services, name themes, produce a short overview report.
  Ends at the service-selection gate. Independently useful; can be the whole
  run via `--overview-only`.
- **Drill** — the operator has picked **one** service. Within that service,
  break down usage types, derive purchase/record-type mix, and attribute to
  accounts and regions. Ends at the decode confirmation gate.

Credentials, source accounts and the metric rule are defined in
[`access-pattern.md`](access-pattern.md). Do not restate them.

## Metric

`AmortizedCost` by default, at every tier the Step 2 cascade produced. **No
silent fallback to `UnblendedCost`** — if an amortized query returns
`DataUnavailableException`, Step 2 had already made that a hard stop. If the
operator passed `--metric UnblendedCost` as an explicit override, use it; the
report header and Methodology section record the override and its caveat
(misattributes No Upfront RI recurring charges to On Demand, which makes
commitment-coverage figures in Call 4 unreliable when coverage is non-zero).

All CE calls in this step accept the same optional `--billing-view-arn` that
Step 2 derived; pass it when `billing_view_arn` is non-null in `scope.json`.

## Phase A: Overview

The overview is one CE call plus two small enrichment calls. It never decodes
a usage type and never calls `describe`/`list`. Its purpose is to rank
services honestly and produce the artifact a TAM can read on its own.

### Call A1 — rank services

```bash
aws ce get-cost-and-usage \
  --time-period Start=<lookback_start>,End=<this_month_start> \
  --granularity MONTHLY \
  --metrics AmortizedCost UsageQuantity \
  --group-by '[{"Type":"DIMENSION","Key":"SERVICE"}]' \
  --filter '{"Not":{"Dimensions":{"Key":"RECORD_TYPE",
             "Values":["Credit","Refund","Tax"]}}}' \
  [--billing-view-arn <arn>] \
  --region us-east-1 --output json
```

Aggregate across the lookback window by **averaging, not summing**:

```
service_monthly_avg = sum(AmortizedCost across N months) / N
```

Rank descending by `service_monthly_avg`. Apply `min_service_usd` (default
`50`) as a pre-selection threshold — services below it are marked "below
threshold" rather than dropped from display, because the operator may still
pick one. `top_n` applies **within** a chosen service in Phase B and does not
apply to the overview ranking (every service above the threshold is shown).

### Call A2 — accounts visible to this source

```bash
aws ce get-cost-and-usage \
  --time-period Start=<lookback_start>,End=<this_month_start> \
  --granularity MONTHLY --metrics AmortizedCost \
  --group-by '[{"Type":"DIMENSION","Key":"LINKED_ACCOUNT"}]' \
  [--billing-view-arn <arn>] \
  --region us-east-1 --output json
```

Record the distinct `LINKED_ACCOUNT` values as `accounts_visible`. On tier 3
(per-account), `accounts_visible` is computed differently — it is the number
of accounts whose per-account CE call returned data, carried forward from
`tier3_status` in `scope.json`. A tier 3 run captioned "organization-wide"
when only a subset succeeded is wrong; the honest figure is "N of M in
scope".

### Call A3 — org-level commitment coverage (RECORD_TYPE)

```bash
aws ce get-cost-and-usage \
  --time-period Start=<lookback_start>,End=<this_month_start> \
  --granularity MONTHLY --metrics AmortizedCost \
  --group-by '[{"Type":"DIMENSION","Key":"RECORD_TYPE"}]' \
  [--billing-view-arn <arn>] \
  --region us-east-1 --output json
```

Resolve the record-type values rather than assuming them:

```bash
aws ce get-dimension-values \
  --dimension RECORD_TYPE \
  --time-period Start=<lookback_start>,End=<this_month_start> \
  [--billing-view-arn <arn>] \
  --region us-east-1 --output json
```

Classify into three buckets exactly as Step 3 Call 4 does (see Phase B
below), and compute org-level coverage. **Do not hardcode the value strings;
Slack has been known to add new ones as commitment products launch.** If a
returned value cannot be classified, mark org coverage "unavailable" rather
than guessing.

### Themes

The overview report calls out patterns the service ranking alone would miss.
Themes are **derived from Call A1 output + scope.json**, not researched:

- **Extended support footprint.** Any service whose name or whose top
  usage-type substrings include `ExtendedSupport`, `extendedSupport`, or
  `extended-support` is flagged. Sum the ExtendedSupport portion across
  services and report as "`$X/mo`, `Y%` of org total". This is the single
  highest-signal theme most TAMs can act on, and it is visible without
  decoding anything.
- **Commitment coverage.** From Call A3. "Zero RI/SP coverage anywhere" is a
  theme; so is "X% covered, Y% uncovered". The uncovered amount is a sizing
  figure, not a purchase recommendation.
- **Services with many usage types.** If any service has more than a
  configurable threshold (default 20) of distinct usage types in Call A1
  output, it is flagged as "sprawling" — this is the pattern that produced
  the original mode's "fragmentation below threshold" bug when ranking was
  by usage type. The theme is informational: the service's cost may be
  significant even when no single usage type is.

### Overview report

Rendered per [`../../../references/report-format.md`](../../../references/report-format.md).
Sections:

1. **KPI cards** — org total /mo, services count, commitment coverage,
   extended-support footprint /mo, days to the nearest scheduled rate change
   if any was researched during overview (none are by default).
2. **Service ranking table** — service, $/mo, share, # usage types, billed
   unit (first-ranked within the service, chosen by $/mo).
3. **Themes** — the list above, each with its figure.
4. **Coverage statement** — CE source tier, `rate_basis`,
   `accounts_visible of accounts_in_scope`, lookback window, metric and any
   override.
5. **Recommended drill-downs** — a prose paragraph suggesting which services
   to analyze first, with the reason (big + growing, infrastructure service
   with lever variety, extended-support bearing). Not deterministic; this is
   the agent's judgment, surfaced as recommendations rather than defaults.
6. **Methodology** — APIs called (three CE calls), what was not covered
   (decode, research, per-resource evidence).

Output path: `./<run_id>/Cost-Optimization-Review-Overview-<DATE>.{html,md}`.

### Service-selection gate

After rendering, present a gate. The exact wording:

```
OVERVIEW COMPLETE.  Which service should I drill into?

   recommended    <service-A>  <service-B>  <service-C>   (reasons printed above)
   or any ranked  <N> services listed in the overview

Enter one service name. Multiple services require separate runs
(one service per drill, by design).

Options: <name>  or  cancel  or  --overview-only (stop here)
```

The operator supplies **one** name. Matching rules:

- Case-insensitive exact match against the CE service names from Call A1.
- Case-insensitive match against obvious short forms the agent resolved in
  the recommended list (e.g., "RDS" matches "Amazon Relational Database
  Service"). Ambiguity halts and asks.
- Operator can also pass `--service <name>` on the invocation to skip the
  overview phase entirely; the match is resolved the same way, after a
  minimal Call A1 run to produce the authoritative service list.

Record `service_chosen` in `scope.json` and proceed to Phase B.

## Phase B: Drill

Phase B queries CE and the Price List API inside the chosen service only.
All CE calls add a `SERVICE` filter to the single service picked.

### Call B1 — usage-type ranking within the service

Two grouping dimensions is the CE API maximum:

```bash
aws ce get-cost-and-usage \
  --time-period Start=<lookback_start>,End=<this_month_start> \
  --granularity MONTHLY \
  --metrics AmortizedCost UsageQuantity \
  --group-by '[
    {"Type":"DIMENSION","Key":"SERVICE"},
    {"Type":"DIMENSION","Key":"USAGE_TYPE"}
  ]' \
  --filter '{"And":[
      {"Not":{"Dimensions":{"Key":"RECORD_TYPE",
               "Values":["Credit","Refund","Tax"]}}},
      {"Dimensions":{"Key":"SERVICE","Values":["<service_chosen>"]}}
    ]}' \
  [--billing-view-arn <arn>] \
  --region us-east-1 --output json
```

**Grouping by `SERVICE × USAGE_TYPE` is deliberate**, even though every row
has the same service value. It makes the service code that owns each usage
type explicit in the result, which Step 4 cites instead of inferring from the
code string. The misdecode trap `step-4-decode.md` is built to prevent
(`USW2-Amazon-Q-QS-Fee` -> Amazon Q when it is really Amazon QuickSight) is
closed here, by construction, for every code that came from a CE grouping.

Aggregate each usage type the same way as the overview — monthly averages,
not sums:

```
monthly_avg     = sum(AmortizedCost  over N months) / N
usage_quantity  = sum(UsageQuantity  over N months) / N
```

Cost Explorer returns `UsageQuantity` with its own unit. Record it; Step 4
cross-checks it against the Price List record's `unit` to catch misdecodes.

### Call B2 — purchase mix per selected usage type

Only for lines that survive `top_n` and `min_finding_usd`. Filter to those
usage types:

```bash
aws ce get-cost-and-usage \
  --time-period Start=<lookback_start>,End=<this_month_start> \
  --granularity MONTHLY --metrics AmortizedCost \
  --group-by '[
    {"Type":"DIMENSION","Key":"USAGE_TYPE"},
    {"Type":"DIMENSION","Key":"PURCHASE_TYPE"}
  ]' \
  --filter '{"Dimensions":{"Key":"USAGE_TYPE","Values":["<code1>","<code2>",...]}}' \
  [--billing-view-arn <arn>] \
  --region us-east-1 --output json
```

`PURCHASE_TYPE` is the readable On Demand / Reserved / Savings Plans split
used for display and for selecting the lever classes worth researching:

```
mostly On Demand on a commitment-eligible service   configuration, commitment, capacity
mostly Reserved or Savings Plans                    configuration, capacity
On Demand on a non-eligible service                 configuration, elimination
```

### Call B3 — attribution (account × region) per selected usage type

```bash
aws ce get-cost-and-usage \
  --time-period Start=<lookback_start>,End=<this_month_start> \
  --granularity MONTHLY --metrics AmortizedCost UsageQuantity \
  --group-by '[
    {"Type":"DIMENSION","Key":"LINKED_ACCOUNT"},
    {"Type":"DIMENSION","Key":"REGION"}
  ]' \
  --filter '{"Dimensions":{"Key":"USAGE_TYPE","Values":["<code1>","<code2>",...]}}' \
  [--billing-view-arn <arn>] \
  --region us-east-1 --output json
```

Keep `NoRegion` / `global` cost in each line's total; exclude it from the
resolved region set. Drop the region dimension entirely for global products
(S3 bucket inventory, Route 53, CloudFront) rather than inventing one.

### Resolve regions here

The `REGION` grouping in Call B3 **is** the region data; `regions` resolves
from it rather than from a separate discovery call:

```
regions = auto       the distinct REGION values this call returned
regions = explicit   the list as given; scope.json records that regions were
                     not derived from spend
```

Drop the `NoRegion` / `global` pseudo-region from the resolved set. Write the
result back to `scope.json` as `regions_resolved`. Step 6's fan-out uses
that, not the raw parameter.

### Call B4 — commitment coverage per selected usage type (RECORD_TYPE)

For commitment-eligible services only (compute, RDS, OpenSearch, SageMaker).
Skip entirely for services where a commitment cannot apply (NAT, data
transfer, EIP, S3 storage, CloudWatch). An empty result for those is not a
gap.

```bash
aws ce get-cost-and-usage \
  --time-period Start=<lookback_start>,End=<this_month_start> \
  --granularity MONTHLY --metrics AmortizedCost UsageQuantity \
  --group-by '[
    {"Type":"DIMENSION","Key":"USAGE_TYPE"},
    {"Type":"DIMENSION","Key":"RECORD_TYPE"}
  ]' \
  --filter '{"Dimensions":{"Key":"USAGE_TYPE","Values":["<code1>","<code2>",...]}}' \
  [--billing-view-arn <arn>] \
  --region us-east-1 --output json
```

Classify RECORD_TYPE values (resolved via `get-dimension-values` as in A3)
into three buckets, and compute coverage from the first two:

```
covered-usage values   SP covered-usage; RI discounted-usage
on-demand usage value  plain Usage
accounting values      commitment fees, negations, upfront charges.
                       EXCLUDED from the denominator.

coverage = covered-usage / (covered-usage + on-demand usage)
```

Commitment coverage from **Call B4 (RECORD_TYPE) is the figure that feeds
realizable saving**, not the purchase-mix percentage from Call B2. B2 is for
display; B4 is precise.

### Optional — spike attribution

Only if the operator asked why costs changed. Uses `ce:GetCostComparisonDrivers`
with calendar-month-aligned periods. Omitted here for length; see the previous
revision of this reference for the exact shape, unchanged in this rewrite.

## Build the drill cost lines

Per usage-type code, carry forward:

```json
{
  "service":         "Amazon Relational Database Service",
  "code":            "APS1-ExtendedSupport:Yr3:MySQL5.7",
  "monthly_avg":     353.28,
  "usage_quantity":  1472.0,
  "lookback_months": 3,
  "ce_unit":         "vCPU-hour",
  "purchase_mix":    { "On Demand Instances": 100.0 },
  "record_type_mix": { "Usage": 100.0 },
  "coverage":        0.0,
  "accounts":        ["111111111111"],
  "regions":         ["ap-southeast-1"]
}
```

Rank by `monthly_avg` descending. Select the top `top_n` lines at or above
`min_finding_usd` (default `25`). Both parameters now apply **within** the
chosen service, as intended.

## Drill confirmation gate

Present the selected lines and take one confirmation before decode (Step 4),
research (Step 5), and confirmation (Step 6) run unattended.

```
DRILL — <service_chosen>   source tier <N> · <rate_basis> · AmortizedCost
                           visible: <X> of <Y> accounts · <Z> regions
                           service total: $<S>/mo (<P>% of org) · <L> months

 #  usage type                                      $/mo  purchase    record  coverage
 1  APS1-ExtendedSupport:Yr3:MySQL5.7              353.28  OD 100%    U 100%      0.0%
 2  APS1-InstanceUsage:db.t3.medium                185.47  OD 100%    U 100%      0.0%
 ...
 N  APS1-Aurora:StorageIOUsage                       4.39  OD 100%    U 100%      0.0%

 below min_finding_usd ($<T>):    <K> lines, $<U>/mo total

 Next: decode <N> lines, research levers, verify across <Z> accounts.
 Estimate: <N> pricing calls · ~<D> doc fetches · ~<R> describe/CW calls.

 Proceed, adjust (top_n / min_finding_usd / drop a line), or cancel?
```

Wait for explicit approval. Edits re-render the gate. Steps 4-7 then run
unattended.

## Persist

Write `spend-profile.json`:

```json
{
  "run_id":             "...",
  "phase":              "drill",
  "service_chosen":     "Amazon Relational Database Service",
  "service_monthly":    981.83,
  "service_share_of_org": 0.390,
  "accounts_visible":   6,
  "accounts_in_scope":  6,
  "lookback_months":    3,
  "ce_source_tier":     3,
  "rate_basis":         "chargeable",
  "metric":             "AmortizedCost",
  "metric_override":    false,

  "org_commitment_coverage": 0.0,
  "org_record_type_mix":     { "Usage": 100.0 },

  "lines":              [ /* the ranked drill lines */ ],
  "below_threshold":    { "lines": 4, "monthly": 4.41 }
}
```

Update `scope.json`: `regions_resolved`, `service_chosen`, the selection the
operator approved. The overview phase, when run on its own, writes an
analogous `overview-profile.json` with the ranked service list, themes, and
coverage statement — no drill fields.
