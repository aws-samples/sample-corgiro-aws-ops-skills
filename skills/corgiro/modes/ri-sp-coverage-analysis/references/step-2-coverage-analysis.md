# Step 2: Coverage Analysis

Compute per-service coverage from Savings Plans and Reserved Instances, gather the RI inventory, and detect region gaps. All calls run against the payer account in `us-east-1`. Resolve credentials per [`../../../references/credential-resolution.md`](../../../references/credential-resolution.md).

## Why the coverage window is fixed at 30 days

Coverage is a **point-in-time** signal — it tells you how much of your current running usage is covered by commitments. Longer windows dilute the answer with historical purchases and expiries that no longer reflect the current fleet. This mode uses a fixed 30-day trailing window regardless of `lookback_months` (which controls decomposition history).

## Fire in parallel

Three groups of calls are independent and all target the payer. Run them concurrently, bounded by the concurrency ceiling in MODE.md.

## 2a. Savings Plans coverage

```bash
aws ce get-savings-plans-coverage \
  --region us-east-1 \
  --time-period Start=<30d_ago_iso>,End=<today_iso> \
  --granularity MONTHLY \
  --group-by '[{"Type":"DIMENSION","Key":"SERVICE"}]' \
  --output json > sp-coverage.json
```

Extract per service: `CoveragePercentage`, `SpendCoveredBySavingsPlans`, `OnDemandCost`, `TotalCost`.

## 2b. Reserved Instance coverage (per RI-eligible service)

Important CE mechanics:

- `get-reservation-coverage` **defaults to EC2** when no SERVICE filter is provided. That is why EC2 does not need a filter — every other service does.
- Adding a `SERVICE` dimension filter returns RI coverage for that specific service. No service-specific coverage APIs are needed.

Run one call per RI-eligible service that has spend in step 1. Fire in parallel:

```bash
aws ce get-reservation-coverage \
  --region us-east-1 \
  --time-period Start=<30d_ago_iso>,End=<today_iso> \
  --group-by '[{"Type":"DIMENSION","Key":"INSTANCE_TYPE"}]' \
  --filter '{
    "Dimensions": {
      "Key": "SERVICE",
      "Values": ["<service_filter_value>"]
    }
  }' \
  --output json > ri-coverage-<service_slug>.json
```

SERVICE filter values (must match CE's expected strings exactly):

| Service | CE SERVICE filter value |
|---------|-------------------------|
| EC2 | _(omit — CE defaults to EC2)_ |
| RDS | `Amazon Relational Database Service` |
| ElastiCache | `Amazon ElastiCache` |
| OpenSearch | `Amazon OpenSearch Service` |
| MemoryDB | `Amazon MemoryDB` |
| Redshift | `Amazon Redshift` |

> The older `Amazon Elasticsearch Service` string returns empty. Always use `Amazon OpenSearch Service`.

Extract per (service, instance type): `CoverageHoursPercentage`, `OnDemandHours`, `ReservedHours`, `TotalRunningHours`.

## 2c. RI inventory detail (supplemental)

The CE calls in 2b give coverage percentages but not RI metadata (expiry dates, offering type, count). For the "Existing Commitments" table in the report and the expiry analysis in step 5, also query service-specific RI describe APIs. Fire in parallel:

```bash
aws rds describe-reserved-db-instances --region us-east-1 --output json > rds-reserved.json
aws elasticache describe-reserved-cache-nodes --region us-east-1 --output json > elasticache-reserved.json
aws opensearch describe-reserved-instances --region us-east-1 --output json > opensearch-reserved.json
aws redshift describe-reserved-nodes --region us-east-1 --output json > redshift-reserved.json
aws memorydb describe-reserved-nodes --region us-east-1 --output json > memorydb-reserved.json
```

For EC2 RIs use `aws ec2 describe-reserved-instances` (also region-scoped — see the multi-region note below).

For each active RI, extract:

- service
- instance type
- count
- state (only keep `active`, filter out `retired` and `payment-failed`)
- offering type (No Upfront / Partial Upfront / All Upfront)
- start date
- end date
- region

If any RI describe call returns `AccessDenied`, skip that service in the inventory (coverage percentages from 2b remain valid) and note it in the report.

## Combining into the unified coverage view

For each RI-eligible service, produce a row combining SP coverage (2a) and RI coverage (2b):

| Column | Source |
|--------|--------|
| Service | 2a / 2b service name |
| Instance Type | 2b `INSTANCE_TYPE` grouping |
| Total Spend | step 1 `total_spend` for that service |
| SP Coverage % | 2a `CoveragePercentage` |
| RI Coverage % | 2b `CoverageHoursPercentage` |
| Combined Coverage % | `SpendCoveredBySavingsPlans` + (`ReservedHours` × avg on-demand rate) ÷ total addressable |
| On-Demand Gap $ | step 1 `monthly_avg_on_demand` (coverable bucket only) − currently-covered |

## Region gap detection

The service-specific RI describe APIs are **regional** — running them in `us-east-1` only returns RIs in that region. Cross-reference the region distribution of on-demand instance spend (from step 1's USAGE_TYPE drill-down, which surfaces region-suffixed usage types) against the regions where RIs actually exist.

If a service has significant on-demand instance spend in a region with no RI coverage (e.g. `ca-central-1` RDS spend but RIs only in `us-east-1`), flag it:

> Region gap: `<service>` has $`<amount>`/month instance spend in `<region>` with no RI coverage. RDS / ElastiCache / OpenSearch RIs are **region-locked** — they will not cover other regions.

For a full picture across regions, you can optionally repeat 2c across each region where the service has spend. This adds cost (extra API calls) but produces a complete RI inventory. Default: run 2c in `us-east-1` and flag region gaps rather than sweeping every region.

## Output

Persist to `<run_dir>/coverage.json`. Structure:

```json
{
  "sp_coverage": [
    {"service": "...", "coverage_pct": 0.00, "sp_covered_spend": 0.00, "on_demand_cost": 0.00, "total_cost": 0.00}
  ],
  "ri_coverage": [
    {"service": "...", "instance_type": "...", "coverage_hours_pct": 0.00, "on_demand_hours": 0, "reserved_hours": 0, "total_running_hours": 0}
  ],
  "ri_inventory": [
    {"service": "...", "instance_type": "...", "count": 0, "state": "active", "offering_type": "...", "start_date": "...", "end_date": "...", "region": "..."}
  ],
  "combined_view": [
    {"service": "...", "instance_type": "...", "total_spend": 0.00, "sp_coverage_pct": 0.00, "ri_coverage_pct": 0.00, "combined_pct": 0.00, "on_demand_gap": 0.00}
  ],
  "region_gaps": [
    {"service": "...", "region": "...", "monthly_on_demand": 0.00, "reason": "RIs region-locked"}
  ]
}
```
