# Step 5: Research Levers (gate)

For each decoded cost line, produce the set of levers available for that product.
A **lever** is one way to reduce that cost line, with its own limitations and its
own applicability test.

This is the only step that leaves AWS APIs. It uses `web_search` and `web_fetch`
only. No MCP: Corgiro ships no `mcpServers` block and installs into whatever
agent the customer runs.

## Catalogue first, then live research

```
catalogue_key is in lever-catalogue.md
  -> load its lever records
  -> RE-FETCH each stored source URL to confirm it still says what it said
  -> RE-PULL every rate from the pricing API (prices move)
  -> zero searches

catalogue_key is absent
  -> research live, below
  -> after a successful run, offer to append the result to the catalogue
```

The catalogue is a cache, never a gate. The mode works correctly with it empty.
See [`lever-catalogue.md`](lever-catalogue.md).

## Lever classes and their grounding source

Which source supplies layers 2 and 3 depends on the lever class. Two of the three
have an AWS API that returns the mechanism, the limitation and the saving
together, which is stronger grounding than any documentation page.

| Class | Tier-0 grounding source | What the API supplies |
|---|---|---|
| configuration | `pricing:GetProducts` + docs | rate after; mechanism and limitation from docs |
| commitment | `ce:GetSavingsPlansPurchaseRecommendation`, `ce:GetReservationPurchaseRecommendation` | recommended commitment, estimated monthly saving, estimated savings percentage, ROI |
| capacity | `compute-optimizer:GetEC2InstanceRecommendations` (and the EBS, Lambda, RDS, ECS equivalents) | `recommendationOptions[].instanceType`, `savingsOpportunity`, `savingsOpportunityAfterDiscounts`, `performanceRisk`, `migrationEffort`, `platformDifferences` |

For commitment and capacity levers, the limitation fields come from the API, so
no doc fetch is required and there is no risk of a stale blog-sourced
limitation. Record the API and the call timestamp as the citation, exactly as a
URL would be recorded.

> `savingsOpportunityAfterDiscounts` is documented as the savings opportunity
> "that includes Savings Plans and Reserved Instances discounts". Use it as the
> realizable saving for capacity levers in preference to computing one from the
> purchase mix: AWS already did the arithmetic.

Still fetch docs for the **mechanism** sentence on commitment and capacity
levers, so the report explains what the change is rather than only what it saves.

## Source tiers and role limits

Tier alone is not enough. Each source has a limit on what it may be the **sole**
source for.

| Source | Tier | Sole source for |
|---|---|---|
| `pricing:GetProducts` | 0 | every NUMBER. Always. |
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
  - and that limitation MUST NOT be used to mark the lever NOT APPLICABLE
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
| `proof_required` | derived | the exact observable condition that proves it applies here |
| `effort` | 1 | Low / Medium / High, with what drives it |

`proof_required` must be a condition a `describe` call can answer, stated
precisely. "VPCs without a gateway endpoint" is not precise enough: the
documentation is explicit that subnet route-table association, not VPC presence,
determines whether a gateway endpoint takes effect. Write the condition at the
granularity the docs describe.

## Breakeven, when a lever has a fixed cost

Levers that trade per-unit cost for a fixed charge need the crossover computed
from live rates, not asserted:

```
fixed     $0.01/endpoint-hour x 730 x <AZ count>
variable  effective_rate - replacement_rate per unit
breakeven fixed / variable
```

State the basis. If the replacement product has no existing usage its effective
rate is not observable, so use list for that side and flag the assumption.

## Lever record

```json
{
  "catalogue_key":        "AmazonEC2|NAT Gateway|NatGateway|GB",
  "lever_id":             "nat-gateway-endpoints-s3-ddb",
  "name":                 "S3 / DynamoDB gateway endpoints",
  "mechanism":            "<one sentence>",
  "mechanism_source":     { "url": "...", "tier": 1, "fetched": "2026-11-08" },
  "rate_now":             { "value": 0.03024, "unit": "GB", "basis": "effective" },
  "rate_after":           { "value": 0.0, "unit": "GB",
                            "source": "<doc url>", "tier": 1 },
  "limitation":           "<what constrains it>",
  "limitation_source":    { "url": "...", "tier": 1, "fetched": "2026-11-08",
                            "published": null, "flag": null },
  "proof_required":       "<a condition a describe call can answer>",
  "effort":               "Low",
  "pricing_provenance":   { "sku": "...", "price_version": "..." }
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

Write `levers.json`: one array of lever records per `catalogue_key`, plus the
dropped-lever list with reasons.
