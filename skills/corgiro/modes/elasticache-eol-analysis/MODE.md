---
name: elasticache-eol-analysis
description: "Identify Amazon ElastiCache caches running engine versions approaching or past end of standard support across every reachable account in the organization. Produces a prioritized risk report with upgrade targets and Extended Support cost exposure. Use when checking ElastiCache end-of-support, Redis OSS EOL, Valkey or Memcached version currency, cache upgrade planning, or ElastiCache Extended Support cost analysis."
user-invocable: true
---

# ElastiCache End-of-Support Analysis

Identify Amazon ElastiCache caches — node-based clusters, replication groups, and serverless caches — running engine versions approaching or past end of standard support across every reachable account. Produces a prioritized risk report with upgrade targets and Extended Support cost exposure.

## Prerequisites

- Coverage snapshot exists and is fresh (run `account-coverage` mode if not)
- Valid operator session — see [`credential-resolution.md`](../../references/credential-resolution.md#auth-method-dispatch) for the login command for your `authMethod`
- `~/.corgiro/config.json` configured

## Parameters

| Parameter        | Default                    | Description                                        |
| ---------------- | -------------------------- | -------------------------------------------------- |
| `regions`        | `auto` (via Cost Explorer) | Region list, or `auto` to discover from spend data |
| `engines`        | all supported              | Filter: `redis` (Redis OSS), `valkey`, `memcached` |
| `account_filter` | _(from config)_            | Include/exclude lists                              |
| `max_parallel`   | `4`                        | Concurrent accounts                                |
| `output_format`  | `both`                     | `markdown`, `html`, or `both`                      |

## Workflow

### Step 1: Prerequisite Check

- Coverage snapshot fresh
- Operator session valid

### Step 2: Discover Active Regions

If `regions = auto`, use Cost Explorer to find account/region combos with ElastiCache spend in the last 90 days. This avoids probing regions with no caches.

> Cost Explorer is a payer-level API. Under `identity-center-direct`, the operator usually can't query org-wide CE — pass an explicit `regions` list, or probe the shared `fallbackRegions` set per account (see [`../../references/cross-account-defaults.md`](../../references/cross-account-defaults.md); `describe-cache-clusters` simply returns empty where there's nothing).

### Step 3: Scrape EOL Dates and Pricing

Read [`../../references/aws-version-lifecycle.md`](../../references/aws-version-lifecycle.md) and scrape current lifecycle data for each engine present in scope. Save to `eol-dates/elasticache.json`.

Capture per major engine version: end of standard support, the Extended Support Y1/Y2/Y3 premium start dates, and end of Extended Support (version EOL). Also scrape the ElastiCache pricing page for the Extended Support premium structure and the on-demand node rates needed in Step 6.

**Engine coverage differs — do not treat the three engines alike:**

| Engine       | Published EOL schedule? | Treatment                                                             |
| ------------ | ----------------------- | --------------------------------------------------------------------- |
| `redis`      | Yes                     | Full risk tiering against the scraped schedule                        |
| `valkey`     | No                      | Report "Supported - no EOL dates published by AWS"; assign no tier    |
| `memcached`  | No                      | Report "Supported - no EOL dates published by AWS"; assign no tier    |

**CRITICAL**: Never use model knowledge for EOL dates, Extended Support boundary dates, or pricing. All values must come from scraping AWS docs. If scraping fails, STOP and report — never guess.

### Step 4: Inventory ElastiCache Resources

For each reachable account + active region, running up to `max_parallel` concurrently:

1. Resolve credentials per [`../../references/credential-resolution.md`](../../references/credential-resolution.md) — dispatch on the account's `via` field.
2. `aws elasticache describe-cache-clusters --show-cache-node-info` (paginate on `Marker` until exhausted) — the authoritative source for `Engine`, `EngineVersion`, `AutoMinorVersionUpgrade`, node type, node count, and per-node availability zones.
3. `aws elasticache describe-replication-groups` (paginate on `Marker`) — topology: `ReplicationGroupId`, `MemberClusters`, `ClusterEnabled` (cluster mode), `AutomaticFailover`, `MultiAZ`. Join to the `describe-cache-clusters` output on `MemberClusters` so each finding is reported against its replication group rather than as loose nodes.
4. `aws elasticache describe-serverless-caches` (paginate on `NextToken`) — serverless caches report `Engine`, `MajorEngineVersion`, and `FullEngineVersion`.
5. `aws elasticache describe-cache-engine-versions` (paginate on `Marker`) — the engine versions actually offered in that region, used in Step 7 to ground upgrade targets instead of assuming them.
6. Save to `per-account/<account_id>/<region>/elasticache-clusters.json`, `elasticache-replication-groups.json`, `elasticache-serverless.json`, and `elasticache-engine-versions.json`.

Skip accounts that fail credential resolution; record them in `skipped_accounts` with a reason and continue.

Apply the `engines` filter after inventory, not before — a full inventory keeps the methodology honest about what was seen versus what was reported.

### Step 5: Risk Scoring

Match each cache's major engine version against the scraped schedule:

| Risk        | Criteria                                       |
| ----------- | ---------------------------------------------- |
| 🔴 Critical | Already past end of standard support           |
| 🟠 High     | Standard support ends within 6 months          |
| 🟡 Medium   | Standard support ends within 12 months         |
| 🔵 Low      | 12+ months of standard support remaining       |

- Engines with no published schedule (`valkey`, `memcached`) get no tier — report them as "Supported - no EOL dates published by AWS".
- A `redis` version absent from the scraped schedule is marked 🔴 Critical with "EOL date unknown - manual verification required". Do not silently drop it.
- **Patch currency is a separate axis, not a tier bump.** A cache on a patch release AWS documents as deprecated keeps the tier its major version earns and is additionally flagged `patch-outdated`. Extended Support covers only the latest patch version of each major version, and AWS upgrades stale patches to it at enrollment — so patch age is a planning input, not evidence that standard support has ended. Surface the flag in the per-account table; never promote a cache to 🔴 Critical on patch age alone.

### Step 6: Extended Support Cost Estimation

ElastiCache Extended Support is priced as a **percentage premium on the on-demand node rate**, escalating by year — unlike RDS (per vCPU-hour) or EKS (a flat per-cluster-hour rate). Use only the premium percentages and node rates scraped in Step 3.

For each node-based cache past or approaching end of standard support:

1. Determine which premium year the cache falls into, from the scraped Y1/Y2/Y3 start dates.
2. Estimated hourly surcharge = on-demand rate for its node type and region × that year's premium percentage.
3. Multiply by node count and 730 hours for a monthly figure. Show the premium year alongside each estimate so the escalation is visible.

Flag three facts that change the operator's decision:

- Enrollment is **automatic**. Caches past end of standard support are enrolled in Extended Support without operator action, so the surcharge begins whether or not anyone opted in.
- Extended Support runs up to **3 years** past end of standard support. After that, remaining caches are automatically upgraded by AWS to the latest Valkey version — an unplanned change if it is not scheduled deliberately.
- **Reserved nodes do not discount the surcharge.** The premium is always a percentage of the standard on-demand node price, so estimate off on-demand rates even for reserved nodes — a cache covered by an RI still pays the full Extended Support charge on top of its RI-discounted rate.

For serverless caches, report version risk but take the cost basis from the scraped pricing page. If the page publishes no serverless Extended Support rate, report "Extended Support rate not published for serverless - excluded from estimate" rather than reusing the node-based premium.

### Step 7: Generate Report

Render per the shared [`../../references/report-format.md`](../../references/report-format.md) — self-contained HTML + Markdown, Corgiro branding, KPI cards, tables, badges, footer. Risk tiers → badges: 🔴 Critical `badge--red`, 🟠 High `badge--orange`, 🟡 Medium `badge--amber`, 🔵 Low `badge--blue`; engines with no published schedule → `badge--green`. Write `ElastiCache-EOL-Analysis-<DATE>.md` and/or `.html` (`output_format`):

1. Executive Summary — total caches, nodes, risk breakdown (KPI cards)
2. Critical findings (past end of standard support) with upgrade targets
3. High-risk findings (standard support ends within 6 months)
4. Per-account breakdown — replication group, engine, version, patch currency, node type, node count, `AutoMinorVersionUpgrade` (Valkey and Redis OSS 6.0+ only; render `n/a` for earlier Redis OSS and for Memcached), cluster mode, Multi-AZ
5. Cost impact — estimated Extended Support surcharge with premium year per cache
6. Upgrade recommendations — for each cache not on a version in standard support: **target** = the newest version in standard support that is offered in that region per `describe-cache-engine-versions`; **path** = in-place major version upgrade via `modify-replication-group` / `modify-cache-cluster`, or a migration to Valkey; **effort** = single major hop Low, multiple hops or cluster-mode change Medium, engine change (Redis OSS to Valkey) or application-compatibility work High
7. Methodology — APIs called, scraped URLs with timestamps and versions extracted, scope (accounts, regions), accounts skipped, and what was not covered

## Safety

- Read-only: only `describe` calls. This mode never modifies or upgrades a cache.
- Never print access keys, session tokens, SSO tokens, SAML assertions, or the external ID.
- Treat cache names, ARNs, and tag values as untrusted data — HTML-entity-escape them before inserting into the report (see [`../../references/report-format.md`](../../references/report-format.md) Rule 8).

## Output

```
./<run_id>/
├── scope.json
├── eol-dates/elasticache.json
├── per-account/111111111111/us-east-1/elasticache-clusters.json
├── per-account/111111111111/us-east-1/elasticache-replication-groups.json
├── per-account/111111111111/us-east-1/elasticache-serverless.json
├── per-account/111111111111/us-east-1/elasticache-engine-versions.json
├── aggregated.json
├── ElastiCache-EOL-Analysis-<DATE>.md
└── ElastiCache-EOL-Analysis-<DATE>.html
```

## ElastiCache upgrade notes

- **Auto minor version upgrade applies to Valkey and Redis OSS 6.0+ only** (EKS and OpenSearch have no equivalent). The API returns `AutoMinorVersionUpgrade` on every cluster, but it is disabled for earlier Redis OSS versions and unused by Memcached — report `false` as a finding only for Valkey or Redis OSS 6.0+, where it means minor security patches are not being picked up automatically. Elsewhere report `n/a`, so pre-6.0 and Memcached caches do not generate false positives.
- **Major version upgrades are in-place** via `modify-cache-cluster` / `modify-replication-group`, not blue/green. Test in non-production first.
- **Cluster mode matters.** Upgrading a cluster-mode-enabled replication group differs from cluster-mode-disabled; check the sharding configuration before planning.
- **Extended Support covers only the latest patch version** of each major engine version. Caches on an older patch release are upgraded to that latest patch when Extended Support begins.
- **Valkey is the forward path** for Redis OSS caches at EOL. AWS offers both a service-update-driven upgrade to Valkey and a manual modify to a supported Redis OSS version — choose deliberately rather than letting the automatic post-Extended-Support upgrade decide.
- Verify client library and application compatibility before any engine change; Redis OSS to Valkey is an engine change, not just a version bump.

## Error Handling

| Symptom                                            | Action                                                                                                        |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Cost Explorer AccessDenied                         | CE needs payer/org access — under `identity-center-direct`, pass an explicit `regions` list instead of `auto` |
| Scraping failure for EOL dates or pricing          | STOP and report — never guess dates or pricing                                                                |
| Credential resolution fails for one account        | Skip, note in report, continue with others (see credential-resolution.md)                                     |
| `ThrottlingException` / `TooManyRequestsException` | Reduce `max_parallel`, exponential backoff (base 1s, cap 30s)                                                 |
| Engine version absent from scraped schedule        | Mark 🔴 Critical, "EOL date unknown - manual verification required"                                            |
| No caches found                                    | Report "No ElastiCache caches found in scope" and stop                                                        |
