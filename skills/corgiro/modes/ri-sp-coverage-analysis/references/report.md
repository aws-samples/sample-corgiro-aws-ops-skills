# Step 6: Generate Report

Aggregate the five persisted JSON files (`spend-decomposition.json`, `coverage.json`, `utilization.json`, `recommendations.json`, `expiring.json`) into `aggregated.json`, then render a self-contained HTML report plus a Markdown sibling.

Follow every rule in the shared [`../../../references/report-format.md`](../../../references/report-format.md) — do not restate its content here. This step describes only the mode-specific sections and the badge/KPI mapping.

## Aggregation

Read the five step files back from the run directory and combine into `aggregated.json`:

```json
{
  "meta": {
    "run_id": "ri-sp-coverage-analysis-YYYYMMDD-HHMMSS",
    "date": "YYYY-MM-DD",
    "payer_account_id": "111111111111",
    "lookback_months": 3,
    "metric": "AmortizedCost",
    "scope_description": "1 payer · consolidated billing family · us-east-1 (Cost Explorer)"
  },
  "spend_decomposition": {},
  "coverage": {},
  "utilization": {},
  "recommendations": {},
  "expiring": {}
}
```

The `scope_description` string appears in the report header (`Scope:` line). Use "1 payer · consolidated billing family" rather than an account count, because CE reports at payer level and does not enumerate members in this mode.

## Report sections

Follow the section order in `report-format.md` (header, KPI grid, sections, footer). The mode-specific sections come between the KPI grid and the Methodology footer:

### 1. Executive Summary

KPI cards (`kpi-grid`) — apply the accent classes from `report-format.md`:

| KPI | Value | Accent |
|-----|-------|--------|
| Total monthly avg spend | `$X` | `is-ok` |
| Optimizable on-demand (addressable) | `$X` | `is-medium` if > 0 else `is-ok` |
| Combined SP + RI coverage | `X%` | `is-ok` if ≥ 70%, `is-medium` 50-69%, `is-high` < 50% |
| Est. monthly savings from recommendations | `$X` | `is-ok` |
| SP utilization | `X%` | `is-ok` ≥ 90%, `is-medium` 80-89%, `is-high` < 80% |
| RI utilization | `X%` | `is-ok` ≥ 90%, `is-medium` 80-89%, `is-high` < 80% |
| Expiring commitments (Immediate / Plan / Awareness) | `X / Y / Z` | `is-critical` if Immediate > 0, else `is-medium` |

### 2. Spend by Service & Purchase Type

`data-table` with columns: Service, On-Demand $, Reserved $, Savings Plans $, Spot $, Total $, On-Demand %, Monthly Avg OD, Category.

Sort by On-Demand $ descending. Show the "Category" column with values `Optimizable` (green badge) or `Inherently on-demand` (zinc badge). For services with a USAGE_TYPE drill-down, add a `<details>` row underneath showing the coverable vs non-reservable split.

On-Demand % badge: `badge--red` > 80%, `badge--orange` > 50%, otherwise no badge.

### 3. Coverage Analysis

`data-table` with columns: Service, Instance Type, Total Spend, SP Coverage %, RI Coverage %, Combined %, On-Demand Gap $.

Combined % badge: `badge--green` ≥ 70%, `badge--amber` 50-69%, `badge--orange` 30-49%, `badge--red` < 30%.

Below the table, list any `region_gaps` from `coverage.json` as a warning callout.

### 4. Existing Commitments

`data-table` with columns: Type (RI / SP), ID, Service, Instance Type, Region, Commitment $/hr, Start, End, Utilization %, Status, Days Until Expiry.

Utilization % badge per step 3's mapping. Status column shows one of: `badge--green` Active, `badge--amber` Expiring (within 90 days), `badge--red` Expiring Soon (within 30 days).

If any RI describe returned `AccessDenied`, add a note above the table: "Some RI inventory unavailable (`<service_list>`) — coverage percentages remain accurate."

### 5. Purchase Recommendations

`data-table` with columns: Source (CE / COH), Type, Hourly Commitment, Term, Payment, Est. Monthly Savings, Est. Savings %, Est. Monthly OD After Purchase, ROI.

If the cross-reference showed disagreement between CE and COH, add a `<details>` block below the table titled "CE vs COH divergence" that lists each `cross_reference` entry.

If both sources returned nothing, replace the table with: "AWS does not recommend additional commitments at this time based on current usage patterns." (Not an error state.)

### 6. Expiring Commitments Action Plan

`data-table` with columns: Type, ID, Service, Region, Commitment, Expiry Date, Days Remaining, Current Utilization, Recommended Action.

Sort by Days Remaining ascending. Days Remaining badge: `badge--red` ≤ 30, `badge--amber` ≤ 60, `badge--blue` ≤ 90.

If `expiring.counts_by_bucket` totals zero, replace the table with: "No commitments expiring in the next 90 days."

### Methodology (required closing section)

- Tools/APIs used: `aws ce get-cost-and-usage`, `aws ce get-savings-plans-coverage`, `aws ce get-reservation-coverage`, `aws ce get-savings-plans-utilization`, `aws ce get-reservation-utilization`, `aws ce get-savings-plans-purchase-recommendation`, `aws cost-optimization-hub list-recommendation-summaries`, `aws cost-optimization-hub list-recommendations`, `aws rds describe-reserved-db-instances`, `aws elasticache describe-reserved-cache-nodes`, `aws opensearch describe-reserved-instances`, `aws redshift describe-reserved-nodes`, `aws memorydb describe-reserved-nodes`, `aws savingsplans describe-savings-plans`.
- Scope: payer account `<payer_account_id>` (consolidated billing family), `<lookback_months>` months of history for decomposition, 30-day trailing window for coverage/utilization, `<term>` / `<payment>` for SP recommendations.
- What was NOT covered: per-account or per-resource cost drill-down (this mode reports at service-and-instance-type granularity — for CUR-level analysis run a dedicated CUR review). Non-RI/SP-addressable optimization opportunities (rightsizing, Graviton migration, idle resources) — those are covered by other Corgiro modes and by the wider set of COH recommendations.

## Rendering rules (reminders from report-format.md)

- Inline the CSS placeholder and logo data URI via the Python injection step in `report-format.md` rule 9 — never hand-transcribe them.
- HTML-entity-escape every string from AWS output (subscription IDs, service names, region strings) before inserting into the HTML. Truncate to 256 raw characters first, then escape (`&` → `&amp;` first, then `<`, `>`, `"`, `'`), then wrap in code / literal formatting.
- After writing HTML, `chmod 700 ./<run_dir>` and `chmod 600 ./<run_dir>/*`, then `open ./<run_dir>/RI-SP-Coverage-<DATE>.html`.
- Verify logo landed intact: `grep -c 'src="data:image/png;base64,iVBOR' <run_dir>/RI-SP-Coverage-<DATE>.html` should return `1`.

## Markdown sibling

When `output_format` includes `markdown`, produce `RI-SP-Coverage-<DATE>.md` with the same six sections in the same order. Plain Markdown — no styling. Wrap any resource-derived string in inline code / fenced blocks (never as bare text or as a Markdown link target) so a Markdown viewer that renders embedded HTML cannot execute it. Lead with the title, generated date, run id, and scope, matching the header block from `report-format.md`.
