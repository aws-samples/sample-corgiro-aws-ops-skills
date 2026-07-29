---
name: rds-eol-analysis
description: "Identify RDS instances and Aurora clusters approaching or past end-of-support dates across every reachable account in the organization. Produces a prioritized risk report with upgrade recommendations and extended support cost estimates. Use when checking RDS end-of-support, Aurora EOL, database upgrade planning, or extended support cost analysis."
user-invocable: true
---

# RDS End-of-Support Analysis

Identify RDS instances and Aurora clusters approaching or past end-of-support dates across every reachable account. Produces a prioritized risk report with upgrade recommendations and extended support cost estimates.

## Prerequisites

- Coverage snapshot exists and is fresh (run `account-coverage` mode if not)
- Valid SSO session
- `~/.corgiro/config.json` configured

## Parameters

| Parameter        | Default                    | Description                                                                 |
| ---------------- | -------------------------- | --------------------------------------------------------------------------- |
| `regions`        | `auto` (via Cost Explorer) | Region list, or `auto` to discover from spend data                          |
| `engines`        | all supported              | Filter: `mysql`, `postgres`, `mariadb`, `aurora-postgresql`, `aurora-mysql` |
| `account_filter` | _(from config)_            | Include/exclude lists                                                       |
| `max_parallel`   | `4`                        | Concurrent accounts                                                         |
| `output_format`  | `both`                     | `markdown`, `html`, or `both`                                               |

## Workflow

### Step 1: Prerequisite Check

- Coverage snapshot fresh
- SSO session valid

### Step 2: Discover Active Regions

If `regions = auto`, use Cost Explorer to find account/region combos with RDS spend in last 90 days. This avoids probing regions with no RDS resources.

> Cost Explorer is a payer-level API. Under `identity-center-direct`, the operator usually can't query org-wide CE — pass an explicit `regions` list, or probe the shared `fallbackRegions` set per account (see [`../../references/cross-account-defaults.md`](../../references/cross-account-defaults.md); `describe-db-instances` simply returns empty where there's nothing).

### Step 3: Scrape EOL Dates

Read [`../../references/aws-version-lifecycle.md`](../../references/aws-version-lifecycle.md) and scrape current lifecycle dates for all RDS/Aurora engines. Save to `eol-dates/rds.json`.

**CRITICAL**: Never use model knowledge for EOL dates. All dates must come from scraping AWS docs.

### Step 4: Inventory RDS Resources

For each reachable account + active region:

1. Resolve credentials per [`../../references/credential-resolution.md`](../../references/credential-resolution.md) — dispatch on the account's `via` field.
2. `aws rds describe-db-instances`
3. `aws rds describe-db-clusters`
4. Save to `per-account/<account_id>/<region>/rds-instances.json` and `rds-clusters.json`

### Step 5: Risk Scoring

Match each instance/cluster engine version against scraped EOL dates:

| Risk        | Criteria                                 |
| ----------- | ---------------------------------------- |
| 🔴 Critical | Already past standard support end date   |
| 🟠 High     | Standard support ends within 6 months    |
| 🟡 Medium   | Standard support ends within 12 months   |
| 🔵 Low      | 12+ months of standard support remaining |

> **Engines without scrapeable AWS lifecycle dates.** Per [`../../references/aws-version-lifecycle.md`](../../references/aws-version-lifecycle.md), engines such as Oracle, SQL Server, DocumentDB, and Neptune have no AWS-published EOL calendar. Do not assign a risk tier — report them as "Vendor-managed lifecycle — consult vendor documentation."

### Step 6: Extended Support Cost Estimation

For instances past or approaching EOL, calculate estimated extended support costs using the pricing tiers from AWS documentation.

### Step 7: Generate Report

Render per the shared [`../../references/report-format.md`](../../references/report-format.md) — self-contained HTML + Markdown, Corgiro branding, KPI cards, tables, badges, footer. Risk tiers → badges: 🔴 Critical `badge--red`, 🟠 High `badge--orange`, 🟡 Medium `badge--amber`, 🔵 Low `badge--blue`. Write `RDS-EOL-Analysis-<DATE>.md` and/or `.html` (`output_format`):

1. Executive Summary — total instances, risk breakdown (KPI cards)
2. Critical findings (past EOL) with upgrade paths
3. High-risk findings (EOL within 6 months)
4. Per-account breakdown
5. Cost impact — estimated extended support charges
6. Upgrade recommendations — target versions per engine
7. Methodology — tools used, scope, limitations

## Output

```
./<run_id>/
├── scope.json
├── eol-dates/rds.json
├── per-account/<account_id>/<region>/rds-*.json
├── aggregated.json
├── RDS-EOL-Analysis-<DATE>.md
└── RDS-EOL-Analysis-<DATE>.html
```

## Error Handling

| Symptom                                     | Action                                                                                                        |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Cost Explorer AccessDenied                  | CE needs payer/org access — under `identity-center-direct`, pass an explicit `regions` list instead of `auto` |
| Scraping failure for EOL dates              | STOP and report — never guess dates                                                                           |
| Credential resolution fails for one account | Skip, note in report, continue with others (see credential-resolution.md)                                     |
