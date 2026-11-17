# Step 5: Research Levers (gate)

For each decoded cost line, produce the set of levers available for that product.
A **lever** is one way to reduce that cost line, with its own limitations and its
own applicability test.

This is the only step that leaves AWS APIs. It uses `web_search` and `web_fetch`
only. No MCP: Corgiro ships no `mcpServers` block and installs into whatever
agent the customer runs.

## Live research every run; the cache is a record, not a shortcut

The mode researches levers **live every run**, from AWS documentation. The skill
folder does not carry a lever catalogue — levers for a service are discovered,
fetched and synthesized each time, so the research surfaces newly launched
levers as they appear and never relies on a stale pre-populated list.

An **operator-local lever library** at
`~/.corgiro/cache/cost-optimization-review/levers/` accumulates what has been
researched, one file per product. It is a **record of past research, never an
input to a verdict and never a reason to skip a step.** What it is good for:

- **Consistency.** Two operators drilling the same product in different
  accounts produce the same lever set, described the same way, rather than two
  independently worded analyses.
- **Coverage ledger.** Which products have ever been analyzed, with what
  citations — answers "have we looked at NAT gateway yet".
- **Audit.** What the documented basis was on a given date, when a
  recommendation is challenged months later.

```
operator-local lever library (mode 700 on dirs, 600 on files)
  ~/.corgiro/cache/cost-optimization-review/
    levers/
      AmazonEC2--NatGateway--GB.json
      AmazonRDS--CreateDBInstance-0002--Hrs.json
      AmazonRDS--CreateDBInstance-0002--vCPU-hour.json
      ...
  file name = slugified catalogue_key from Step 4
```

Per decoded cost line:

```
research every lever live from scratch (the section below), every run.
  the discovery search runs first and is non-negotiable (below)
  every rate comes from the pricing API this run
  every mechanism and limitation is taken from a page fetched this run

then: read the library file for catalogue_key, if one exists, and compare.
  match a library lever to a researched one on `lever_id` first, then on a
    case-insensitive match of `name` — IDs drift between runs even when the
    lever is the same ("rds-es-upgrade-to-standard-support" one run,
    "rds-es-upgrade-to-standard-support-version" the next), so an ID-only
    comparison reports false gaps.
  a lever in the library that today's research did not produce
    -> state it in levers.json under "not_reproduced" with the library's
       fetch date, so a lever that quietly disappeared from the docs is
       visible rather than silently dropped
  a lever today's research produced that the library lacks
    -> new; it simply appears in the refreshed file

then: overwrite the library file with this run's research.
```

**`lever_id` naming.** Derive it from the lever `name`: lowercase, spaces and
punctuation to hyphens, prefixed with a short service token
(`rds-es-`, `aoss-`, `nat-`). Two runs that find the same lever should produce
the same id. The `name`-based fallback above exists because they sometimes
will not, not as a licence to be loose about it.

> **Why there is no cache-hit path.** An earlier design validated stored
> content hashes and skipped re-synthesizing unchanged levers. It was removed
> because it could not pay for itself: `web_fetch` exposes no HTTP headers, so
> the conditional GET it depended on is unavailable, and validating a stored
> quote still requires re-fetching the page — at which point the content needed
> to re-synthesize is already in hand. The saving was writing two sentences;
> the cost was a validation mechanism that silently failed open. Research is
> cheap relative to being wrong about what AWS currently documents.

**Mandatory per-run discovery search.** A newly launched AWS feature produces a
lever no past run could know about, so each run issues one
`site:docs.aws.amazon.com` search for the product and compares the top URLs
against the library's `discovery_search.known_result_urls`:

```
new URL in the top results -> research it from scratch; it joins this run's
                              lever set and the refreshed library file
URL known in the library and still returned -> research it again anyway; the
                              library is a record, not a skip. The match only
                              tells you this is not a newly launched lever.
URL previously known but NOT in today's top results -> research the product
                              anyway and, if the lever does not reappear,
                              record it under "not_reproduced". Do NOT silently
                              drop it; AWS docs reorganize.
```

The discovery search is one call per product per run. Non-negotiable; it is the
only mechanism that catches positive staleness (new levers).

**Fail-open on library errors.** A malformed or unreadable library file changes
nothing about the run — research was going to happen regardless. Note it and
overwrite the file at the end. The library can never block or alter a result.

**Operator controls:**

- `--no-cache` skips reading the library for this run (it is still written).
  Research is unaffected either way; this only suppresses the
  `not_reproduced` comparison.
- `--cache-dir <path>` overrides the default location.

## Lever scope: shared or engine-scoped

A selected cost line can carry several operations — three engines under one
`db.t4g.micro` usage type, for instance. Researching a full lever set per
operation would triplicate work and print three near-identical subsections for
$55.80 of spend. Most levers do not care which engine it is.

Tag every lever with a `scope`:

```
shared          the lever and its mechanism are identical across the operations
                on this cost line. Research ONCE, report once, name the
                operations it covers.
                  measured: db.t4g.micro bills $0.0250/Hrs on MySQL,
                  PostgreSQL and MariaDB alike, so rightsizing, delete-if-idle
                  and commitment coverage are one analysis

engine-scoped   the mechanism, the limitation or the deadline differs by
                operation. Research and report ONE PER OPERATION PRESENT.
                  version lifecycle: AWS publishes a separate release calendar
                  per engine, so "upgrade before <date>" has a different date
                  for each
                  engine features: pgvector exists on PostgreSQL and not MySQL,
                  so an alternative-vector-store lever applies to one and not
                  the other
```

Decide the scope from the product, as with relevance in
[`step-6-confirm.md`](step-6-confirm.md) — not from whether the evidence
happened to differ. A lever is `engine-scoped` when the documentation that
grounds it is engine-specific, even if this customer runs one engine.

The library files follow the key, so engine-scoped levers land in the file for
their own operation while a `shared` lever is written to each operation's file
with its `scope` recorded. A reader of one file therefore sees the complete set
for that product without having to know the sharing.

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

The library stores one file per `catalogue_key`; each file holds an array of
lever records with the shape below. **Rates are NOT stored** — they are pulled
from the pricing API on every run. The library stores
mechanism/limitation/proof/if-unprovable/effort, the source URLs, what each
claim rests on, and the date it was fetched.

**Every source object carries either a `quote` or a `basis` — never neither.**
The two are not interchangeable and the distinction is the point:

```
quote   the sentence from the fetched page, verbatim, that the claim rests on.
        Use this whenever the source is a documentation page. It is what makes
        the record auditable: a reader opens the URL and checks the sentence is
        still there.

basis   a one-line statement of where the claim comes from when there is no
        sentence to quote — because the evidence is tier 0 rather than prose.
        e.g. "per-vCPU-hour billing basis is the `unit` field on the price
        record itself (sku KY9YE6TN8DHNHPU3), not a documented sentence".
```

A source object with neither is not a citation, and the lever drops under the
fail-stop below. Without this rule a missing `quote` is ambiguous: a reader
cannot tell "no quote because the evidence is the price record's own unit
field" from "no quote because nobody recorded one", and the second is a lever
that should never have shipped.

```json
{
  "catalogue_key":        "AmazonEC2|NatGateway|GB",
  "lever_id":             "nat-gateway-endpoints-s3-ddb",
  "name":                 "S3 / DynamoDB gateway endpoints",
  "class":                "configuration",
  "scope":                "shared",                  // or "engine-scoped"; see Lever scope
  "covers_operations":    ["CreateDBInstance:0002", "CreateDBInstance:0014"],
  "mechanism":            "<one sentence>",
  "mechanism_source":     {
    "url":          "https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html",
    "tier":         1,
    "fetched":      "<ISO 8601 timestamp>",
    "quote":        "<the sentence the mechanism rests on, verbatim>"
  },
  "limitation":           "<what constrains it>",
  "limitation_source":    {
    "url":          "...",
    "tier":         1,
    "fetched":      "<ISO 8601 timestamp>",
    "quote":        "<the sentence the limitation rests on, verbatim>",
    "published":    null,
    "flag":         null
  },
  "proof_required":       "<a condition a describe/cloudwatch/CO call can answer>",
  "if_unprovable":        "<the verification step, phrased as an instruction>",
  "effort":               "Low"
}
```

A source grounded in tier-0 data rather than a documented sentence carries
`basis` in place of `quote`:

```json
  "mechanism_source":     {
    "tier":         0,
    "fetched":      "<ISO 8601 timestamp>",
    "basis":        "per-vCPU-hour billing is the `unit` field on the price record itself (sku KY9YE6TN8DHNHPU3), not a documented sentence"
  },
```

`url` is optional on a tier-0 source, because the Price List API response is
the evidence and it is already identified by SKU and price-list version in the
run's `decode/<code>.json`.

Per-run fields that are **not** stored in the library (populated fresh each run):

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
A source object with neither a quote
  nor a basis                            -> not a citation; drop the lever
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
today's discovery search. Overwrite any existing file — this run's research is
the current record. `chmod 600` the file.

**When:** write both files immediately after Step 5 completes, before Step 6
starts. Step 5 output is customer-agnostic product knowledge and does not
depend on Step 6's per-customer evidence; writing early means a Step 6
failure, a cancelled run, or a crash in later steps still leaves the research
recorded.

**What NOT to write to the library:**

- Dropped levers (those that failed the fail-stop for lack of citation).
  They go into `levers.json`'s dropped-lever list in the run directory only.
  Recording a dropped lever in the library would read as "already handled" to
  a future reader when the truth is the opposite.
- Any per-run field listed above (rates, effective_rate, rate_after,
  pricing_provenance). Rates move; next run pulls them again.

The run directory and the library are independent — deleting the run
directory does not affect the library, and clearing the library does not
affect past run reports or any future run's correctness. A missing library
costs nothing but the `not_reproduced` comparison.
