# Step 3: Analyze Spend

This step runs in two phases that share Step 1 and Step 2 and diverge here:

- **Overview** — rank services, name themes, produce a short overview report.
  Ends at the service-selection gate. Independently useful; can be the whole
  run via `--overview-only`.
- **Drill** — the operator has picked **one** service. Within that service,
  rank usage types, show the per-line account breakdown, derive purchase and
  record-type mix, then proceed directly to Step 4. No gate here; the
  service-selection gate in the overview phase is the only interactive
  gate in the drill flow.

Credentials, source account and the metric rule are defined in
[`access-pattern.md`](access-pattern.md). Do not restate them.

## Metric

`AmortizedCost` by default, against the one CE source account Step 2 resolved.
**No silent fallback to `UnblendedCost`** — if an amortized query returns
`DataUnavailableException`, Step 2 had already made that a hard stop. If the
operator passed `--metric UnblendedCost` as an explicit override, use it; the
report header and Methodology section record the override and its caveat
(misattributes No Upfront RI recurring charges to On Demand, which makes the
commitment-coverage figures in Call B4 unreliable when coverage is non-zero).

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
pick one. The drill-phase selection rules (`coverage_share` Pareto cutoff +
`noise_floor_pct` noise floor) apply **within** a chosen service in Phase B
and do not apply to the overview ranking (every service above the threshold
is shown).

### Call A2 — accounts visible to this source

```bash
aws ce get-cost-and-usage \
  --time-period Start=<lookback_start>,End=<this_month_start> \
  --granularity MONTHLY --metrics AmortizedCost \
  --group-by '[{"Type":"DIMENSION","Key":"LINKED_ACCOUNT"}]' \
  [--billing-view-arn <arn>] \
  --region us-east-1 --output json
```

Record the distinct `LINKED_ACCOUNT` values the CE source returned as
`accounts_visible`. This is the one account's view of the world:

- Named account is a **Billing Conductor primary**: `accounts_visible` is
  every member of the billing group.
- Named account is a **single member**: `accounts_visible` is one — the named
  account itself.

If `accounts_visible` differs from `accounts_in_scope` (the drill-phase
evidence set resolved in Step 2), the overview report states both honestly
and never captions a partial view as "organization-wide".

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

Classify into three buckets exactly as Call B4 does (see Phase B below), and
compute org-level coverage. **Do not hardcode the value strings; AWS has been
known to add new ones as commitment products launch.** If a returned value
cannot be classified, mark org coverage "unavailable" rather than guessing.

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
  output, it is flagged as "sprawling" — the pattern that makes service-first
  ranking preferable to ranking by usage type. The theme is informational:
  the service's cost may be significant even when no single usage type is.

### Overview report

Rendered per [`../../../references/report-format.md`](../../../references/report-format.md).
Sections:

1. **KPI cards** — org total /mo, services count, commitment coverage,
   extended-support footprint /mo, days to the nearest scheduled rate change
   if any was researched during overview (none are by default).
2. **Service ranking table** — service, $/mo, share, # usage types, billed
   unit (first-ranked within the service, chosen by $/mo).
3. **Themes** — the list above, each with its figure.
4. **Coverage statement** — CE source account, `rate_basis`,
   `accounts_visible of accounts_in_scope`, lookback window, metric and any
   override.
5. **Recommended drill-downs** — a prose paragraph suggesting which services
   to analyze first, with the reason (big + growing, infrastructure service
   with lever variety, extended-support bearing). Not deterministic; this is
   the agent's judgment, surfaced as recommendations rather than defaults.
6. **Methodology** — APIs called (three CE calls), what was not covered
   (decode, research, per-resource evidence).

Output path: `<run_dir>/<run_id>/Cost-Optimization-Review-<ce_source_account>-Overview-<DATE>.{html,md}`.

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

The drill runs **four CE calls**, in this order. All four complete before
Step 4 runs, producing the classification (analyzed / roll-up / noise) and
the per-line account breakdown that the final report renders:

```
B1   SERVICE × USAGE_TYPE           usage-type ranking (primary table)
                                     + authoritative CE service code for Step 4
B2   USAGE_TYPE × LINKED_ACCOUNT    per-line account breakdown
                                     ("Where this cost lives" table at the gate
                                     and under each recommendation in the report)
B3   USAGE_TYPE × PURCHASE_TYPE     purchase mix for display
B4   USAGE_TYPE × RECORD_TYPE       precise commitment coverage per line
                                     (for commitment-eligible services only)
```

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

**Rank by `monthly_avg` descending, then classify each line against the two
drill-phase selection parameters:**

```
exclude   monthly_avg <= noise_floor_pct * service_monthly
          (noise - typically rounding-zero lines; not even shown in the
          Spend Profile table)

analyze   line is above the noise floor AND the cumulative share of the
          lines ABOVE it is < coverage_share
          (the Pareto head. Test the running total BEFORE this line, not
           through it, so the line that crosses the cutoff is included --
           "select until cumulative share reaches coverage_share", as the
           parameter is defined in MODE.md. Testing the total THROUGH the
           line excludes the crossing line always, and silently splits a
           tie: two lines at 50% each put the second at a cumulative 1.00,
           rolling it up while its identical twin is analysed end-to-end.)

roll up   line is above the noise floor AND the cumulative share of the
          lines above it has already reached coverage_share
          (listed in the Spend Profile table for completeness but not
          individually decoded, researched, or confirmed; entangled savings
          still surface via Step 6's resource-level view where applicable)
```

Only the **analyze** set feeds B2, B3 and B4 — those subsequent calls are
filtered to this specific list of usage-type codes, not the full set.
The **roll up** set is rendered in the Spend Profile table with a note
("roll-up band") and summarised in a one-paragraph closer at the end of
Recommendations (Step 7).

Both parameters scale with the service total, so the same defaults work for
a $600/mo test account and a $100k/mo production account. Override per-run
with `--coverage-share` (e.g. `0.80` for sprawling services, `0.99` for
completeness) or `--noise-floor-pct` (e.g. `0.01` for very fine detail).

### Call B2 — per-line account breakdown ("Where this cost lives")

For each selected usage type, show which accounts carry the cost. Filter to
the selected codes, group by `LINKED_ACCOUNT`:

```bash
aws ce get-cost-and-usage \
  --time-period Start=<lookback_start>,End=<this_month_start> \
  --granularity MONTHLY --metrics AmortizedCost \
  --group-by '[
    {"Type":"DIMENSION","Key":"USAGE_TYPE"},
    {"Type":"DIMENSION","Key":"LINKED_ACCOUNT"}
  ]' \
  --filter '{"Dimensions":{"Key":"USAGE_TYPE","Values":["<code1>","<code2>",...]}}' \
  [--billing-view-arn <arn>] \
  --region us-east-1 --output json
```

For each `(usage_type, account)` cell, record `$/mo` and its share of the
usage-type total. The result feeds two places:

- **Drill gate** — a secondary "Where this cost lives" table beneath the
  primary usage-type table, so the operator sees per-line account placement
  while deciding what to pursue.
- **Final report** — under each cost-line subsection in Recommendations, a
  short account table above the levers.

Account IDs are resolved to names from `~/.corgiro/state/roster.json` for
display. IDs absent from the roster are shown as the bare ID (Billing
Conductor billing groups can include accounts outside Corgiro's roster).

### Call B3 — purchase mix per selected usage type

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

`PURCHASE_TYPE` is the readable On Demand / Reserved / Savings Plans split,
used for display and for selecting the lever classes worth researching:

```
mostly On Demand on a commitment-eligible service   configuration, commitment, capacity
mostly Reserved or Savings Plans                    configuration, capacity
On Demand on a non-eligible service                 configuration, elimination
```

### Resolve regions here

Regions do not warrant their own CE call. Step 6's fan-out already needs to
know which regions each cost line touched, and B1's output already carries
each usage-type code's region prefix (when present) and the pricing API's
`regionCode` attribute resolves it canonically. The step-3 `regions` parameter
is therefore informational:

```
regions = auto       trust what Step 6 discovers per resource. scope.json
                     records regions_resolved after Step 6 completes.
regions = explicit   the list as given; Step 6 restricts its describe calls
                     to this set.
```

Drop any `NoRegion` / `global` pseudo-region from the resolved set and the
region dimension entirely for global products (S3 bucket inventory, Route 53,
CloudFront) rather than inventing one.

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
realizable saving**, not the purchase-mix percentage from Call B3. B3 is for
display; B4 is precise.

### Optional — spike attribution

Only if the operator asked why costs changed. Uses `ce:GetCostComparisonDrivers`
with calendar-month-aligned periods. Not part of the default drill.

## Build the drill cost lines

Per usage-type code, carry forward:

```json
{
  "service":         "<CE service name>",
  "code":            "<usage type code>",
  "monthly_avg":     <float>,
  "usage_quantity":  <float>,
  "lookback_months": <int>,
  "ce_unit":         "<unit>",
  "accounts":        [
    { "account_id": "<12-digit>", "name": "<roster name>", "monthly": <float>, "share": <0..1> }
  ],
  "purchase_mix":    { "On Demand Instances": <percent>, "Reserved": <percent>, "Savings Plans": <percent> },
  "record_type_mix": { "Usage": <percent>, "<covered-usage value>": <percent>, ... },
  "coverage":        <0..1>
}
```

`accounts` here is the B2 breakdown, not the Step-2 fan-out set.

## Proceed to Step 4

There is **no gate at the end of the drill phase.** Once B1-B4 have
classified the usage types (analyzed / roll-up / noise) and
`spend-profile.json` is written, the mode proceeds directly to Step 4
(decode), then Step 5 (research), Step 6 (confirm), and Step 7 (report).

Agent output at this transition is a short progress line so the operator
knows what was selected and what runs next:

```
Drill — <service_chosen> · <N> lines analyzed (~<pct>% of service), <K> in roll-up,
<M> excluded as noise · proceeding to decode, research, and resource
inspection (~<N> pricing calls + ~<D> doc fetches + ~<R> describe/CW calls).
```

To change the selection, the operator re-runs the mode with
`--coverage-share` or `--noise-floor-pct` (or `--service` to pick a
different service). The service-selection gate at the end of the overview
phase is the only interactive gate in the drill flow.

## Persist

Write `spend-profile.json`:

```json
{
  "run_id":             "...",
  "phase":              "drill",
  "service_chosen":     "<CE service name>",
  "service_monthly":    <float>,
  "service_share_of_org": <0..1>,
  "accounts_visible":   <int>,
  "accounts_in_scope":  <int>,
  "lookback_months":    <int>,
  "ce_source_account":  "<12-digit>",
  "rate_basis":         "<chargeable|proforma|chargeable (unverified)>",
  "metric":             "AmortizedCost",
  "metric_override":    false,

  "org_commitment_coverage": <0..1>,
  "org_record_type_mix":     { "Usage": <percent>, "<covered-usage value>": <percent>, ... },

  "coverage_share":     <0..1>,
  "noise_floor_pct":    <0..1>,
  "noise_floor_abs":    <float>,       // computed: noise_floor_pct * service_monthly
  "selection": {
    "analyzed":  { "lines": <int>, "monthly": <float>, "cumulative_share": <0..1> },
    "roll_up":   { "lines": <int>, "monthly": <float> },
    "excluded":  { "lines": <int>, "monthly": <float> }    // noise band
  },

  "lines":              [ /* every line above noise, each carrying
                           "selection": "analyzed"|"roll_up" */ ]
}
```

Update `scope.json`: `regions_resolved` (filled by Step 6), `service_chosen`,
the selection the operator approved. The overview phase, when run on its
own, writes an analogous `overview-profile.json` with the ranked service
list, themes, and coverage statement — no drill fields.
