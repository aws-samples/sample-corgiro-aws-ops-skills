# Step 5: Research Levers (gate)

For each decoded cost line, produce the set of levers available for that product.
A **lever** is one way to reduce that cost line, with its own limitations and its
own applicability test.

This is the only step that leaves AWS APIs. It uses `web_search` and `web_fetch`
only. No MCP: Corgiro ships no `mcpServers` block and installs into whatever
agent the customer runs.

## Live research by default; optional validated cache

The mode researches levers **live every run**, from AWS documentation. The skill
folder does not carry a lever catalogue — levers for a service are discovered,
fetched and synthesized each time, so the research surfaces newly launched
levers as they appear and never relies on a stale pre-populated list.

An **operator-local cache** at `~/.corgiro/cache/cost-optimization-review/levers/`
avoids repeating the expensive LLM synthesis work for products whose
documentation has not changed since last run. The cache is a **performance
optimization with a correctness guard rail**, never an authority: every cached
lever is validated against live AWS docs before being used, and every run still
does a live **discovery search** to catch levers the cache does not know about.

```
operator-local cache layout (mode 700 on dirs, 600 on files)
  ~/.corgiro/cache/cost-optimization-review/
    levers/
      AmazonEC2--NAT-Gateway--NatGateway--GB.json
      AmazonRDS--Database-Instance--CreateDBInstance-0002--Hrs.json
      ...
  file name = slugified catalogue_key from Step 4
```

Per decoded cost line, before research:

```
load cache file for catalogue_key, if present:
  for each lever in file:
    for each source URL (mechanism_source, limitation_source):
      conditional GET using stored ETag / Last-Modified, or re-fetch
      compute sha256(content); compare to stored content_hash
      if changed  -> mark lever as "source_changed"
      if same     -> stored mechanism / limitation text stands

  always re-pull every rate from pricing API (prices move; cache stores no rates)

  then: run the DISCOVERY SEARCH (below)

  then: for each lever marked "source_changed", re-synthesize that lever
        from the newly fetched content.  Promote cached levers whose
        sources are unchanged without touching them.

if no cache file exists:
  research every lever live from scratch (the section below)
  write a new cache file at the end of the run
```

**Mandatory per-run discovery search.** The cache can only save synthesis work
for levers it already knows about. A newly launched AWS feature produces a new
lever the cache cannot anticipate, so each run issues one
`site:docs.aws.amazon.com` search for the product and compares the top URLs
against the cache's `discovery_search.known_result_urls`:

```
new URL in the top results -> treat as a candidate new lever, research it from
                              scratch, add to the cache file on success
URL known in cache and still returned -> no action (that lever is already handled)
URL previously known but NOT in today's top results -> flag the cached lever
                              for re-verification; do NOT silently drop it,
                              AWS docs reorganize
```

The discovery search is one call per product per run. Non-negotiable; it is the
only mechanism that catches positive staleness (new levers).

**Fail-open on cache errors.** A malformed cache file, a hash mismatch that
cannot be resolved, or a `web_fetch` failure on a stored URL falls through to
full live research for that product. The failed cache file is overwritten by
the fresh research output at the end of the run. The cache never blocks a
correct result.

**Operator controls:**

- `--no-cache` on invocation skips cache reads entirely for this run (still
  writes fresh cache files at the end).
- `--cache-dir <path>` overrides the default location.

## Lever classes and their grounding source

Which source supplies the mechanism and limitation depends on the lever class.
Capacity has an AWS API that returns mechanism, limitation and saving together,
which is stronger grounding than any documentation page.

| Class | Grounding source | What it supplies |
|---|---|---|
| configuration | `pricing:GetProducts` (tier 0) + docs (tier 1) | rate after; mechanism and limitation from docs |
| commitment | CE coverage (tier 0, from Step 3) + docs (tier 1) | the verified coverage gap; the SP-type trade-offs from documentation. **No purchase amount.** |
| capacity | `compute-optimizer:Get*Recommendations` (tier 0) | `recommendationOptions[].instanceType`, `savingsOpportunity`, `savingsOpportunityAfterDiscounts`, `performanceRisk`, `migrationEffort`, `platformDifferences` |
| elimination | `describe`/`list` + `cloudwatch:GetMetricData` + `compute-optimizer:idle` | activity-metric evidence that the resource is unused; see subsection below |

> **Do not call `ce:Get*PurchaseRecommendation`.** A Savings Plan's scope is the
> whole payer family: a Compute SP covers EC2, Fargate and Lambda across every
> account and region. This mode's analysis unit is one usage type in some
> accounts. Attaching a recommended hourly commitment to a single cost line
> implies a precision the data does not support, so the commitment lever reports
> the **coverage gap** and the **trade-off between SP types**, and never a number
> to buy. Sizing a commitment is an org-wide exercise against total usage.

For capacity levers the limitation fields come from the API, so no doc fetch is
required and there is no risk of a stale blog-sourced limitation. Record the API
and the call timestamp as the citation, exactly as a URL would be recorded.

> `savingsOpportunityAfterDiscounts` is documented as the savings opportunity
> "that includes Savings Plans and Reserved Instances discounts". Use it as the
> realizable saving for capacity levers in preference to computing one from the
> purchase mix: AWS already did the arithmetic.

Still fetch docs for the **mechanism** sentence on commitment and capacity
levers, so the report explains what the change is rather than only what it saves.

### Elimination class — special characteristics

An elimination lever removes the cost line entirely rather than reducing it:
delete the resource, stop it, or deprovision it. The "should this resource
exist" question has no single AWS API answer, so the grounding is a
**combination** of signals rather than a single tier-0 source.

**Grounding (all tier 0; no documentation is the sole source for activity):**

- `describe`/`list` on the service to enumerate the resources and confirm they
  are of the type the usage type names.
- `cloudwatch:GetMetricData` on an activity metric whose zero-value reading is
  near-definitive evidence the resource is unused. The metric is service-
  specific:
  - RDS: `DatabaseConnections` (Maximum, 14-day window)
  - EC2: `NetworkIn` + `NetworkOut` (CPU alone is not enough; CPU can be
    above zero on a resource receiving no useful traffic)
  - ALB/NLB: `RequestCount` / `ActiveFlowCount`
  - Lambda: `Invocations`
  - ElastiCache: `CacheHits` + `CacheMisses`
- `compute-optimizer:Get*Recommendations` `idle: true` (where the service is
  covered by Compute Optimizer). This is an independent AWS judgment that
  cross-validates the CloudWatch reading.

**Proof shape:**

```
proof_required   <activity metric> at or near zero across the full metric
                 window, corroborated by Compute Optimizer idle: true where
                 available
```

**Why `if_unprovable` is nearly always set:** Corgiro can observe that no
client connected, that no request arrived, that no invocation occurred. It
cannot observe whether the resource is still required by a human. A batch job
that runs monthly would not appear in a 14-day window, and a disaster-recovery
standby by definition has no traffic in normal operation. So:

```
if_unprovable    "Confirm with the resource owner whether each of these
                 resources is still required, and delete the ones that are
                 not. Take a snapshot first when deletion is irreversible."
```

**Relationship to the other classes.** Elimination is examined **in parallel**
with the other classes, not as a fallback. A database with zero connections is
simultaneously a candidate for elimination (delete) and for upgrade (remove
extended support), and both levers are reported — with the composition rule
phrasing. The operator decides which to pursue; if the database turns out to
be in use after all, the upgrade lever applies; if not, elimination supersedes
it.

**Interaction with capacity verdicts.** Compute Optimizer `finding: Optimized`
with `savingsOpportunity: 0%` **does not mean** there is no optimization
opportunity — only that there is no **capacity** opportunity. Check `idle`
alongside `finding`; when `idle: true` and `finding: Optimized` co-occur, the
resource is a candidate for elimination, not rightsizing. The two fields are
independent in the Compute Optimizer response. See
[`step-6-confirm.md`](step-6-confirm.md) metrics-failure table.

## Source tiers and role limits

Tier alone is not enough. Each source has a limit on what it may be the **sole**
source for.

| Source | Tier | Sole source for |
|---|---|---|
| `pricing:GetProducts` | 0 | every NUMBER. Always. |
| `describe`/`list` + `cloudwatch:GetMetricData` | 0 | elimination-class proof. Activity metrics are the authority on "unused". |
| docs.aws.amazon.com | 1 | mechanism, limitation, quotas, behaviour |
| AWS What's New | 2 | availability, launch dates, region spread |
| AWS Blogs | 3 | approach, sequencing, worked examples. **Not** a rate. **Not** a limitation on its own. |
| re:Post | 4 | nothing load-bearing. Label as community-sourced. |

Search in that order, constrained: `site:docs.aws.amazon.com` first, then What's
New, then `aws.amazon.com/blogs`, then re:Post.

## Two rules

**1. Search results are leads, never citable sources.** Fetch the page and take
the fact from the fetched page. Use `mode="full"` on documentation fetches:
selective extraction drops table rows, and quotas and limits live in tables. Same
rule [`../../../references/aws-version-lifecycle.md`](../../../references/aws-version-lifecycle.md)
already mandates for EOL dates.

**2. Record publication dates, and distrust stale limitations.** Blogs are
point-in-time and unmaintained. A 2022 post saying "X does not support Y" is
routinely wrong by now, and a lever whose limitation rests on it reads
authoritative while being false.

```
Every lever carries limitation_source and limitation_source_date.

If the ONLY source for a limitation is a blog older than ~18 months:
  - the lever ships flagged "limitation needs re-verification"
  - and that limitation MUST NOT be used to rule the lever out
```

The second clause is the important one. A stale limitation can suppress a lever
that now works, which is a silent loss of savings and invisible in the output.

## What to research per cost line

Start from the decoded identity, not the code string. For
`productFamily: "NAT Gateway", operation: NatGateway, unit: GB`, the question is
"what reduces per-GB NAT data processing", not "what do people do about NAT".

Per lever, resolve:

| Field | Source tier | Notes |
|---|---|---|
| `mechanism` | 1 | how the lever removes or reduces this charge |
| `rate_after` | 0 | the replacement rate, from the pricing API. `$0.00` must still be cited to a doc. |
| `limitation` | 1 (3 only if flagged) | what constrains it. The field that decides applicability. |
| `proof_required` | derived | the exact observable condition that sizes it here. For elimination, an activity metric with its zero threshold and window. |
| `if_unprovable` | derived | the step the operator takes when `proof_required` is unobtainable. This becomes the first sentence of the recommendation. See the composition rule in [`step-6-confirm.md`](step-6-confirm.md). |
| `effort` | 1 | Low / Medium / High, with what drives it |

`proof_required` must be a condition a `describe`, `cloudwatch`, or
`compute-optimizer` call can answer, stated precisely. "VPCs without a gateway
endpoint" is not precise enough: the documentation is explicit that subnet
route-table association, not VPC presence, determines whether a gateway endpoint
takes effect. Write the condition at the granularity the docs describe.

`if_unprovable` is mandatory, not optional. Many levers rest on a premise no
read-only API exposes, and that is the normal case rather than an edge case. The
field holds the verification step the operator performs, phrased as an
instruction:

```
lever            S3 / DynamoDB gateway endpoints
proof_required   a private route table sending 0.0.0.0/0 to NAT and not
                 associated with an S3 or DynamoDB gateway endpoint route
if_unprovable    "Identify the destinations of traffic through NAT. Where it is
                  bound for an AWS service, use a VPC endpoint."
```

Without `if_unprovable`, Step 6 has nothing to write except an assertion it
cannot support or an apology. Both are the failure this mode exists to avoid.

## Breakeven, when a lever has a fixed cost

Levers that trade per-unit cost for a fixed charge need the crossover computed
from live rates, not asserted:

```
fixed     <hourly_rate_from_pricing_api> x 730 x <AZ count>
variable  effective_rate - replacement_rate per unit
breakeven fixed / variable
```

Every term is pulled at run time. No rate in this file may be used as an input;
figures that appear here are illustrations of the shape, and prices move.

State the basis. If the replacement product has no existing usage its effective
rate is not observable, so use list for that side and flag the assumption.

## Lever record

The cache stores one file per `catalogue_key`; each file holds an array of
lever records with the shape below. **Rates are NOT stored in the cache** —
they are re-pulled from the pricing API on every run. The cache stores
mechanism/limitation/proof/if-unprovable/effort and the content hashes needed
to validate on next run.

```json
{
  "catalogue_key":        "AmazonEC2|NAT Gateway|NatGateway|GB",
  "lever_id":             "nat-gateway-endpoints-s3-ddb",
  "name":                 "S3 / DynamoDB gateway endpoints",
  "class":                "configuration",
  "mechanism":            "<one sentence>",
  "mechanism_source":     {
    "url":          "https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html",
    "tier":         1,
    "fetched":      "2026-11-08T22:53:00Z",
    "content_hash": "sha256:...",
    "etag":         "W/\"...\"",
    "last_modified":"Mon, 03 Nov 2026 12:00:00 GMT"
  },
  "limitation":           "<what constrains it>",
  "limitation_source":    {
    "url":          "...",
    "tier":         1,
    "fetched":      "2026-11-08T22:53:00Z",
    "content_hash": "sha256:...",
    "published":    null,
    "flag":         null
  },
  "proof_required":       "<a condition a describe/cloudwatch/CO call can answer>",
  "if_unprovable":        "<the verification step, phrased as an instruction>",
  "effort":               "Low"
}
```

Per-run fields that are **not** stored in the cache (populated fresh each run):

```json
{
  "effective_rate":     { "value": 0.03024, "unit": "GB", "basis": "effective" },
  "rate_after":         { "value": 0.0,     "unit": "GB", "source": "<doc url>", "tier": 1 },
  "pricing_provenance": { "sku": "...", "price_version": "..." },
  "discovery_evidence": { "search_query": "...", "known_result_urls_at_run": [...] }
}
```

## Fail-stop

```
No citable source for the mechanism      -> drop the lever
No citable source for the limitation     -> drop the lever
A number with no SKU or no doc citation  -> drop the lever
```

Do not soften an uncitable lever into "consider ...". An uncited lever is worse
than a missing one: it reads authoritative, and the customer cannot tell which
recommendations were verified.

Record dropped levers in the run data so the Methodology can state that research
was attempted and did not resolve.

## Persist

Write `levers.json` into the **run directory**: one array of lever records per
`catalogue_key`, plus the dropped-lever list with reasons. Rates and
`effective_rate` / `rate_after` are populated inline for this run.

Write `~/.corgiro/cache/cost-optimization-review/levers/<slug>.json` for each
product researched: the lever records **without** per-run fields, plus the
`discovery_search` block with `known_result_urls` set to the top results from
today's discovery search. `chmod 600` the file.

The run directory and the operator-cache are independent — deleting the run
directory does not invalidate the cache, and clearing the cache does not
affect past run reports.
