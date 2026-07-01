---
name: eks-eol-analysis
description: "Identify Amazon EKS clusters running Kubernetes versions approaching or past end of standard support (end-of-life) across every reachable account in the organization. Produces a prioritized risk report with upgrade paths and extended support cost estimates. Use when checking EKS end-of-support, Kubernetes version EOL, cluster upgrade planning, or EKS extended support cost analysis."
user-invocable: true
---

# EKS End-of-Support Analysis

Identify Amazon EKS clusters running Kubernetes versions that are approaching or past end of standard support across every reachable account. Produces a prioritized risk report with upgrade paths and extended support cost estimates.

## Prerequisites

- Coverage snapshot exists and is fresh (run `account-coverage` mode if not)
- Valid SSO session
- `~/.corgiro/config.json` configured

## Parameters

| Parameter        | Default                    | Description                                        |
| ---------------- | -------------------------- | -------------------------------------------------- |
| `regions`        | `auto` (via Cost Explorer) | Region list, or `auto` to discover from spend data |
| `account_filter` | _(from config)_            | Include/exclude lists                              |
| `max_parallel`   | `4`                        | Concurrent accounts                                |
| `output_format`  | `both`                     | `markdown`, `html`, or `both`                      |

## Workflow

### Step 1: Prerequisite Check

- Coverage snapshot fresh
- SSO session valid

### Step 2: Discover Active Regions

If `regions = auto`, use Cost Explorer to find account/region combos with EKS spend in the last 90 days. This avoids probing regions with no clusters.

> Cost Explorer is a payer-level API. Under `identity-center-direct`, the operator usually can't query org-wide CE — pass an explicit `regions` list, or probe a default region set per account (`aws eks list-clusters` simply returns empty where there's nothing).

### Step 3: Scrape EOL Dates

Read [`../../references/aws-version-lifecycle.md`](../../references/aws-version-lifecycle.md) and scrape current Kubernetes version lifecycle dates for EKS — standard support end and extended support end per minor version. Save to `eol-dates/eks.json`. Also scrape the EKS pricing page for extended support cost figures.

**CRITICAL**: Never use model knowledge for EOL dates or pricing. All dates and prices must come from scraping AWS docs. If scraping fails, STOP and report — never guess.

### Step 4: Inventory EKS Clusters

For each reachable account + active region:

1. Resolve credentials per [`../../references/credential-resolution.md`](../../references/credential-resolution.md) — dispatch on the account's `via` field.
2. `aws eks list-clusters` (paginate on `nextToken` until exhausted)
3. `aws eks describe-cluster --name <name>` for each cluster — capture Kubernetes version, status, platform version, ARN, and tags (look for `Group`, `Environment`, `Team`, `Application`)
4. Save to `per-account/<account_id>/<region>/eks-clusters.json`

### Step 5: Risk Scoring

Match each cluster's Kubernetes minor version against the scraped EOL dates:

| Risk        | Criteria                                                                            |
| ----------- | ----------------------------------------------------------------------------------- |
| 🔴 Critical | Already past end of standard support (in extended support, or fully out of support) |
| 🟠 High     | Standard support ends within 6 months                                               |
| 🟡 Medium   | Standard support ends within 12 months                                              |
| 🟢 Low      | 12+ months of standard support remaining                                            |

If a cluster's version is missing from the scraped data, mark it 🔴 Critical with "EOL date unknown — manual verification required." Do not skip it.

### Step 6: Extended Support Cost Estimation

For clusters past or approaching end of standard support, estimate extended support cost using the pricing scraped in Step 3. EKS extended support runs **12 months at a single per-cluster-hour rate** — there are no escalating yearly tiers like RDS. In the findings, distinguish clusters **in extended support** (incurring the surcharge now) from those **past all support** (no longer eligible for extended support).

### Step 7: Generate Report

Render per the shared [`../../references/report-format.md`](../../references/report-format.md) — self-contained HTML + Markdown, Corgiro branding, KPI cards, tables, badges, footer. Risk tiers → badges: 🔴 Critical `badge--red`, 🟠 High `badge--orange`, 🟡 Medium `badge--amber`, 🟢 Low `badge--green`. Write `EKS-EOL-Analysis-<DATE>.md` and/or `.html` (`output_format`):

1. Executive Summary — total clusters, risk breakdown (KPI cards)
2. Critical findings (past EOL) with upgrade paths
3. High-risk findings (EOL within 6 months)
4. Per-account breakdown
5. Cost impact — estimated extended support charges
6. Upgrade recommendations — for each cluster not on the latest standard-support version: **target** = latest version still in standard support; **upgrade path** = sequential minor-version hops (EKS upgrades one minor at a time, e.g. `1.28 → 1.29 → 1.30`); **effort** = 1 hop Low, 2–3 hops Medium, 4+ hops High; flag add-on compatibility (VPC CNI, CoreDNS, kube-proxy) and any deprecated Kubernetes APIs to review before upgrading
7. Methodology — tools used, scope, limitations

## Output

```
./<run_id>/
├── scope.json
├── eol-dates/eks.json
├── per-account/<account_id>/<region>/eks-clusters.json
├── aggregated.json
├── EKS-EOL-Analysis-<DATE>.md
└── EKS-EOL-Analysis-<DATE>.html
```

## EKS upgrade notes

- EKS clusters do **not** auto-upgrade — upgrades are performed manually via the console, `aws eks update-cluster-version`, eksctl, or your IaC tooling.
- You can only move **one minor version at a time** (e.g. `1.28 → 1.29 → 1.30`); plan sequential hops.
- Each Kubernetes version gets **14 months of standard support**, then **12 months of extended support** at additional cost.
- Before upgrading: test in non-production, review add-on compatibility (VPC CNI, CoreDNS, kube-proxy), and check workloads for removed/deprecated Kubernetes APIs.

## Error Handling

| Symptom                                     | Action                                                                                                        |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Cost Explorer AccessDenied                  | CE needs payer/org access — under `identity-center-direct`, pass an explicit `regions` list instead of `auto` |
| Scraping failure for EOL dates or pricing   | STOP and report — never guess dates or pricing                                                                |
| Credential resolution fails for one account | Skip, note in report, continue with others (see credential-resolution.md)                                     |
| No clusters found                           | Report "No EKS clusters found in scope" and stop                                                              |
