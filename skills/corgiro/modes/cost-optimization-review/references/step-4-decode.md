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

1. Determine the service code. A NAT usage type is `AmazonEC2`; a VPC endpoint
   usage type is `AmazonVPC`. Use `aws pricing describe-services` when unsure.
   Do not infer the service from the usage-type string.
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
   quotes:

   ```
   NatGateway-Bytes   $12,400 / 410,000 GB = $0.03024/GB  effective
   list (sku 59S5R83GFPUAGVR5)              $0.04500/GB
   -> 32.8% below list
   ```

Cache decodes for the run. The same code recurs across accounts and regions, and
each decode is a billable API call.

## The catalogue key

Key cached lever knowledge on the **decoded identity**, not the raw string:

```
(service_code, productFamily, operation, unit)
```

One entry then covers every regional variant of a product, while keeping
genuinely different products apart. A regex over raw strings would fold
`NatGateway-Prvd-Bytes` into the standard NAT lever set, which is exactly the
failure this step prevents.

## Pass forward to Step 5

```json
{
  "code":             "NatGateway-Bytes",
  "catalogue_key":    "AmazonEC2|NAT Gateway|NatGateway|GB",
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
