# Step 4: Decode Usage Types (gate)

The mechanics live in
[`../../../references/aws-pricing-grounding.md`](../../../references/aws-pricing-grounding.md):
the three calls, the decode record schema, the description fallback chain, the
unit cross-check, tier walking, the effective-rate rule, and the fail-stop. Read
it. This file covers only what is specific to this mode.

## Why this is a gate and not a lookup

A misdecoded usage type does not fail loudly. It silently redirects Steps 5 and 6
to the wrong product, and the output looks correct. The code string is not
sufficient evidence of what the code means:

```
NatGateway-Bytes               unprefixed, and it IS us-east-1
USE1-NatGateway-Bytes          does not exist
USE1-RegionalNatGateway-Bytes  exists, with the prefix
NatGateway-Prvd-Bytes          a different product, billed in Gbps
```

So no lever research happens until the code resolves to a product record.

## Per selected cost line

1. **Service code comes from Step 3, not inference.** Step 3's Call B1 groups
   by `SERVICE × USAGE_TYPE`, so the CE service name that owns each code is
   authoritative output, not guesswork. Map the CE service name to the
   `pricing:*` service code once per run (RDS `Amazon Relational Database
   Service` → `AmazonRDS`, EKS `Amazon Elastic Container Service for
   Kubernetes` → `AmazonEKS`, and so on). Use `aws pricing describe-services`
   to confirm the mapping when unsure; never infer the service from the
   usage-type string. A code reading `Amazon-Q-QS-Fee` belongs to
   `AWSQuickSight`, not Amazon Q — the authoritative service is in Step 3's
   output.
2. Decode per the shared reference. Write the record to `decode/<code>.json`.
3. Cross-check the price record's `unit` against the `ce_unit` carried from
   Step 3. A mismatch means the wrong SKU resolved: verdict `NOT DECODED`.
4. Derive the effective rate:

   ```
   effective_unit_rate = monthly_avg / usage_quantity
   ```

   Both are **per-month averages over the same window**, computed the same way in
   Step 3, so the division is dimensionally correct. Mixing a windowed sum with a
   monthly average understates the rate by a factor of `lookback_months`, which
   then understates every saving computed from it. Check `lookback_months` on the
   profile before dividing; if either value is a sum, stop and fix Step 3 rather
   than compensating here.
5. Record the gap against list, because it decides whose number the report
   quotes. **Use a relative tolerance when comparing** — partial-hour billing and
   proration produce tiny rounding deltas on charges that are exactly at list.
   Exact float equality on the effective rate reports a ~0.001% discount on
   lines that are plainly list-priced:

   ```
   discount_vs_list = (list_rate - effective_rate) / list_rate     when > 0.005 (0.5%)
                    = 0.0                                          when within tolerance
   ```

   Report the computed value if above tolerance; report `0.0` and the note
   "effective rate equals list within tolerance" when below. The threshold is
   stated in the Methodology.

   ```
   NatGateway-Bytes   $12,400 / 410,000 GB = $0.03024/GB  effective
   list (sku 59S5R83GFPUAGVR5)              $0.04500/GB
   -> 32.8% below list
   ```

Cache decodes for the run. The same code recurs across accounts and regions, and
each decode is a billable API call.

## When one usage type maps to many SKUs — `DECODED_AMBIGUOUS`

Some usage types return a single product record. Many do not. A few live
examples from this mode's test runs:

```
APS1-InstanceUsage:db.t4g.micro        3 SKUs, identical $0.025/hr rate
                                       (MySQL, MariaDB, PostgreSQL)
APS1-RDS:GP3-Storage                  30 SKUs, identical $0.138/GB-Mo rate
                                       (every engine x deployment option)
APS1-InstanceUsage:db.t3.medium       17 SKUs, 5 distinct rates
                                       (per engine: Aurora, PostgreSQL, Oracle,
                                        SQL Server, Db2)
```

The unit cross-check does **not** disambiguate — every candidate has the same
unit. Neither does the effective rate alone when the resource matches list
exactly. The only thing that resolves it is live resource inspection, which is
Step 6, *after* the Step 4 gate.

**Rule.** When the price-list query returns more than one record for the usage
type, do not fail — carry the candidates forward and let Step 6 resolve them.

```
verdict           DECODED_AMBIGUOUS
candidates[]      every record returned, each with its sku, disambiguating
                  attributes (databaseEngine, deploymentOption, volumeType, ...),
                  and its rate
sku               null, filled in by Step 6 once the resource is inspected
list_rate         the common rate when all candidates share one; otherwise null,
                  filled in by Step 6
discount_vs_list  null until list_rate is known
```

Step 6's `rds:DescribeDBInstances` / `DescribeDBClusters` / `DescribeVolumes` /
etc. return the disambiguating attribute (engine, deployment option, volume
type), which selects one candidate SKU. The decode record is updated in place
and the final verdict is promoted to `DECODED`. If no candidate matches the
inspected resource, verdict stays `DECODED_AMBIGUOUS` and the lever research
runs on the product family's general levers, with the SKU-specific rate
replaced by the effective rate throughout.

**Rule when candidates share a rate.** `list_rate` can be populated from the
common value even while `sku` is null, so Step 5's grounding and the Step 3
gate both have a number to display. This is the common case for RDS storage
and small Graviton classes, where the engine disambiguation does not change
the price.

## The catalogue key

The decoded identity is also the key the lever library is filed under, so the
record of what was researched for a product survives across runs.

```
catalogue_key = (service_code, operation, unit)
```

Every component comes verbatim from the price record, so two runs decoding the
same code land on the same key. **`productFamily` is deliberately NOT part of
the key**, even though it reads better: it is absent on most records and, worse,
inconsistently returned for the same code across runs. Observed in two runs
against the same account:

```
APS1-InstanceUsage:db.t4g.micro   productFamily 'Database Instance'  /  null
USW2-IndexingOCU                  'Amazon OpenSearch Service Serverless' / null
                                  populated on 4 of 16 decode records
```

A key containing an agent-supplied label drifts. It already did: one run filed
RDS extended support under `RDS Extended Support`, the next under
`Extended Support`, producing two library files for one product and a
`not_reproduced` comparison that silently had nothing to compare against. Keep
`productFamily` in the decode record as description; keep it out of the key.

`unit` carries the discrimination `productFamily` was meant to provide. RDS
instance hours and the RDS extended-support surcharge share
`operation: CreateDBInstance:0002` and are separated only by unit:

```
AmazonRDS|CreateDBInstance:0002|Hrs         instance hours
AmazonRDS|CreateDBInstance:0002|vCPU-hour   extended support (both year tiers)
AmazonES|IndexingOCU|OCU-hours              serverless indexing
AmazonES|SearchOCU|OCU-hours                serverless search
```

One key covers every regional variant of a product, and every usage-type code
that shares its lever set — the Yr1-Yr2 and Yr3 extended-support codes are one
product with one set of levers, so one key is correct. It still keeps genuinely
different products apart. A regex over raw strings would fold
`NatGateway-Prvd-Bytes` into the standard NAT lever set, which is exactly the
failure this step prevents.

**`operation` is required to form a key.** A price record without it cannot
produce a stable key, so the cost line is analyzed and reported as normal but
is **not** written to the lever library — better an incomplete library than one
with entries nothing will ever match again.

The library itself is operator-local state, not part of the skill folder:

```
~/.corgiro/cache/cost-optimization-review/levers/<slugified-key>.json
```

Mode `700` on the directory, `600` on the files, same as the rest of
`~/.corgiro/`. The skill folder is never written to by a run. The library is
read for comparison only — Step 5 researches every lever live on every run
regardless of what the library holds. See Step 5 for its schema, the
`not_reproduced` comparison, and the mandatory per-run discovery search.

## Pass forward to Step 5

```json
{
  "code":             "NatGateway-Bytes",
  "catalogue_key":    "AmazonEC2|NatGateway|GB",
  "product_family":   "NAT Gateway",
  "group_desc":       "Charge for per GB data processed by NatGateways",
  "monthly_avg":      12400.00,
  "usage_quantity":   410000,
  "lookback_months":  3,
  "unit":             "GB",
  "effective_rate":   0.03024,
  "list_rate":        0.04500,
  "discount_vs_list": 0.328,
  "purchase_mix":     { "On Demand": 100.0 },
  "accounts":         ["111111111111", "222222222222"],
  "regions":          ["us-east-1"],
  "sku":              "59S5R83GFPUAGVR5",
  "price_version":    "20261107002852",
  "verdict":          "DECODED"
}
```

## Undecoded lines

Do not drop them and do not guess. Report them as unexplained spend with the
near-miss codes from `get-attribute-values`, so the report's coverage is honest:

```
UNEXPLAINED SPEND
  FooService-SomeUsage    $2,100/mo    not decoded
  nearest codes in AmazonFoo: FooService-SomeUsage-Hrs,
                              USE1-FooService-SomeUsage
  action: confirm the service code or the correct usage type, or skip
```

The report's Methodology sums undecoded spend, so a reader can see how much of
the bill the analysis did not reach.
