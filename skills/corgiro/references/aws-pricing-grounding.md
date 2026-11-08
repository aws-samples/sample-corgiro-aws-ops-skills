---
name: aws-pricing-grounding
description: Decode AWS usage-type codes and ground every price in the AWS Price List Query API. Use when interpreting a Cost Explorer usage type, quoting an AWS rate, or estimating a saving. Never use model knowledge for usage-type meaning or pricing.
---

# AWS Pricing Grounding

## Overview

Two jobs, both read-only and both mandatory wherever a mode interprets a cost
code or quotes a rate:

1. **Decode** a usage-type code into what it actually is, from the AWS Price List
   Query API rather than from the string or from memory.
2. **Ground** every number in that API, then correct it to what the customer
   actually pays.

**CRITICAL:**
> Never use model knowledge for usage-type meaning, rates, units, or region
> prefixes. Every value MUST come from `aws pricing` or from a fetched AWS
> documentation page. If a code cannot be decoded, STOP and report it as
> undecoded. Do not infer meaning from the string.

Model memory on usage-type codes is unreliable and a misdecode is silent: the
downstream analysis looks correct while describing the wrong product.

## Why the string cannot be trusted

Observed, live, from the Price List Query API:

```
NatGateway-Bytes               exists. Unprefixed, and it IS us-east-1.
USE1-NatGateway-Bytes          DOES NOT EXIST.
USE1-RegionalNatGateway-Bytes  exists, WITH the prefix.
USE1-VpcEndpoint-Bytes         exists, WITH the prefix.
```

us-east-1 drops the region prefix on one NAT variant and keeps it on another.
There is no rule to memorise.

Similar strings are different products with different optimization levers:

| Code | Product |
|---|---|
| `NatGateway-Hours` / `-Bytes` | standard NAT: hourly + data processing |
| `RegionalNatGateway-Hours` / `-Bytes` | regional NAT, automatic multi-AZ expansion |
| `NatGateway-Prvd-Bytes` / `-Prvd-Gbps` | provisioned throughput, billed in Gbps |

VPC endpoints have eight variants per region: `Bytes`, `Hours`, `GWLBE-Bytes`,
`GWLBE-Hours`, `Resource-Hours`, `Service-Hours`, `Tunnel-Hours`,
`ODB-Resource-Hours`.

Region codes are not guessable: `EU` (legacy eu-west-1), `APS1`-`APS9`,
`APE1`/`APE2`, `EUC1`/`EUC2`, `EUN1`, `EUS1`/`EUS2`, `MEC1`, `MES1`, `MXC1`,
`ILC1`, `AFS1`, `CAN1`/`CAN2`, `LAX1`/`PHX1` (Local Zones), `UGE1`/`UGW1`
(GovCloud).

## IAM

`pricing:DescribeServices`, `pricing:GetAttributeValues` and
`pricing:GetProducts` are Read actions, present in `ReadOnlyAccess` and absent
from `CorgiroReadOnlyRole-DataPlaneDeny`.

The Price List Query API is **global and account-agnostic**: call it from any
account, including the base profile. Endpoints are `us-east-1`, `eu-central-1`
and `ap-south-1`.

## Step 1: Decode

```bash
# a. the authoritative product record for one code
aws pricing get-products \
  --service-code <ServiceCode> \
  --filters Type=TERM_MATCH,Field=usagetype,Value=<Code> \
  --region us-east-1 --output json
```

Read these fields. Do not interpret the code string.

| Field | Gives you |
|---|---|
| `product.productFamily` | the product class, e.g. `NAT Gateway` |
| `product.attributes.groupDescription` | AWS's own plain-English description |
| `product.attributes.operation` | the billed operation |
| `product.attributes.group` | the billing group, e.g. `NGW:NatGateway` |
| `product.attributes.regionCode` / `location` | resolves the region prefix definitively |
| `product.attributes.servicename` | human-readable service |
| `product.sku` | stable identifier to cite |
| `terms.OnDemand.*.priceDimensions.*.description` | the rate, in prose |
| `terms.OnDemand.*.priceDimensions.*.unit` | the billed unit |
| `terms.OnDemand.*.priceDimensions.*.pricePerUnit.USD` | the rate |
| `terms.OnDemand.*.effectiveDate`, `version`, `publicationDate` | provenance |

Empty result means the code as written does not exist. Enumerate the real codes
before concluding anything:

```bash
# b. every valid usage type for the service, optionally pattern-filtered
aws pricing get-attribute-values \
  --service-code <ServiceCode> --attribute-name usagetype \
  --region us-east-1 --output json
```

Report the near-miss codes to the operator. Do not retry with a guess.

### Description fallback chain

`groupDescription` is excellent for some services and terse or absent for
others. Apply in order:

```
groupDescription
  -> priceDimensions.description
    -> productFamily + operation + unit
      -> NOT DECODED
```

### Decode record

```json
{
  "code":           "NatGateway-Bytes",
  "service_code":   "AmazonEC2",
  "product_family": "NAT Gateway",
  "servicename":    "Amazon Elastic Compute Cloud",
  "operation":      "NatGateway",
  "group":          "NGW:NatGateway",
  "group_desc":     "Charge for per GB data processed by NatGateways",
  "price_desc":     "$0.045 per GB Data Processed by NAT Gateways",
  "unit":           "GB",
  "region_code":    "us-east-1",
  "location":       "US East (N. Virginia)",
  "tiers":          [{ "begin": 0, "end": "Inf", "usd": 0.045 }],
  "sku":            "59S5R83GFPUAGVR5",
  "price_version":  "20261107002852",
  "published":      "2026-11-07T00:28:52Z",
  "effective":      "2026-11-01T00:00:00Z",
  "ce_unit":        "GB",
  "unit_match":     true,
  "verdict":        "DECODED"
}
```

### Unit cross-check (mandatory)

Cost Explorer returns `UsageQuantity` with its own unit. Compare it to the price
record's `unit`.

```
CE unit == price unit   -> unit_match: true
mismatch                -> the WRONG SKU was resolved. verdict: NOT DECODED
```

A `GB` vs `Gbps` mismatch is the `-Bytes` versus `-Prvd-Gbps` confusion, and it
returns a valid-looking record. One comparison prevents the worst class of error.

## Step 2: Walk every price dimension

Some SKUs are flat, some are tiered, and **the API does not return dimensions in
range order.** Observed on `USE1-VpcEndpoint-Bytes`, in response order:

```
1st   begin 0          end 1,048,576    $0.010/GB
2nd   begin 5,242,880  end Inf          $0.004/GB
3rd   begin 1,048,576  end 5,242,880    $0.006/GB
```

Rules:

1. Collect all `priceDimensions`, **sort by `beginRange` ascending**.
2. Apply the customer's actual `UsageQuantity` across the tiers.
3. Never take `pricePerUnit` from the first dimension returned. It is correct
   only by coincidence and silently wrong at volume.
4. Note any `appliesTo` values; a dimension scoped by `appliesTo` is not general.

## Step 3: Correct to the customer's effective rate

The Price List API returns **public list price**. Customers billed through a
distributor or solution provider, and customers with an EDP or PPA, do not pay
it. A saving computed from list is wrong for all of them, usually overstated.

Derive the real rate from Cost Explorer, which returns cost and quantity for the
same group:

```
effective_unit_rate = AmortizedCost / UsageQuantity
```

```
NatGateway-Bytes   $12,400 / 410,000 GB = $0.03024/GB  effective
list                                      $0.04500/GB
-> 32.8% below list
```

**Rule.** Savings arithmetic uses the effective rate. The Price List API is used
to decode the SKU, name the alternative, and sanity-check against list. Report
both rates and state which was used.

When a lever's target product has no existing usage, its effective rate is not
observable. Use list for that side and flag the assumption.

## Step 4: Record provenance

Every quoted number carries:

```
sku · price_version · publicationDate · retrieved_at
```

This is stronger than a scraped pricing page: it is the billing system's own
data, versioned. A number without this provenance MUST NOT appear in a report.

## Error handling: fail-stop

If a code cannot be decoded:

1. **STOP.** Do not research levers, do not quote a rate, do not estimate.
2. Report: `usage type <code> not decoded; $<amount>/mo unexplained`, and list
   the near-miss codes from Step 1b.
3. Offer: **A)** operator supplies the service code or the correct usage type,
   **B)** skip this cost line and record it as undecoded in the methodology.
4. **NEVER** infer meaning from the code string, the region prefix, or the unit
   suffix.
5. A record found with a unit mismatch is also a failure, not a partial success.

Undecoded lines are reported as unexplained spend, never silently omitted, so the
report stays honest about its own coverage.

## Best practices

1. **Discover before filtering.** `get-attribute-values` first when the code is
   not already known-good.
2. **One decode per distinct code**, cached for the run. Codes repeat across
   accounts and regions.
3. **Match service code to product.** A NAT usage type is `AmazonEC2`; a VPC
   endpoint usage type is `AmazonVPC`. Use `aws pricing describe-services` when
   unsure.
4. **Absence is not a rate.** A product with no usage type (gateway VPC
   endpoints, for example) may be free, but cite the documentation that says so.
   Do not infer `$0.00` from an empty pricing result alone.
5. **Record the provenance at fetch time**, not at report time.

## Consumers

- `cost-optimization-review` (Steps 4 and 6)
- `ec2-compute-review` could adopt this to replace its hardcoded `gp2 $0.10/GB`,
  `gp3 $0.08/GB`, `io1 $0.125/GB + $0.065/IOPS` and flat 20% Graviton figures,
  which are guessed, us-east-1 only, and the same class of error this reference
  exists to prevent.
