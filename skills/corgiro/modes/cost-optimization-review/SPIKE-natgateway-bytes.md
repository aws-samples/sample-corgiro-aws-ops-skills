# Spike: NatGateway-Bytes, end to end

Validation artifact, not part of the mode. Purpose: prove Step 4 (decode) and
Step 5 (lever research) produce TAM-grade output before writing `MODE.md`.

Every rate, description, SKU and quotation below was retrieved live on
**2026-11-08** from the AWS Price List Query API and docs.aws.amazon.com. Nothing
is from memory. Account IDs are placeholders per repo convention.

Steps 3 and 6 are simulated with plausible figures, since they need a customer
account. Both are proven machinery in `ri-sp-coverage-analysis` and
`ec2-compute-review`.

---

## Step 3 output (simulated) -- the cost line

```
CE source account   111111111111 (payer)   billing view: PRIMARY (chargeable)
metric              AmortizedCost          period: 2026-08-01 .. 2026-10-31

  usage type          NatGateway-Bytes
  monthly average     $12,400.00
  usage quantity      410,000 GB
  purchase type       On Demand 100%
  accounts            111111111111, 222222222222
  regions             us-east-1
```

---

## Step 4 -- DECODE (gate)

```bash
aws pricing get-products --service-code AmazonEC2 \
  --filters Type=TERM_MATCH,Field=usagetype,Value=NatGateway-Bytes \
  --region us-east-1
```

Decode record:

```json
{
  "code":            "NatGateway-Bytes",
  "service_code":    "AmazonEC2",
  "product_family":  "NAT Gateway",
  "servicename":     "Amazon Elastic Compute Cloud",
  "operation":       "NatGateway",
  "group":           "NGW:NatGateway",
  "group_desc":      "Charge for per GB data processed by NatGateways",
  "price_desc":      "$0.045 per GB Data Processed by NAT Gateways",
  "unit":            "GB",
  "region_code":     "us-east-1",
  "location":        "US East (N. Virginia)",
  "list_rate":       0.045,
  "tiers":           [{ "begin": 0, "end": "Inf", "usd": 0.045 }],
  "sku":             "59S5R83GFPUAGVR5",
  "price_version":   "20261107002852",
  "published":       "2026-11-07T00:28:52Z",
  "effective":       "2026-11-01T00:00:00Z",
  "ce_unit":         "GB",
  "unit_match":      true,
  "verdict":         "DECODED"
}
```

### Effective rate (D8)

```
effective = AmortizedCost / UsageQuantity = 12,400 / 410,000 = $0.03024/GB
list                                                           $0.04500/GB
-> 32.8% below list. Savings math uses $0.03024. Reported as such.
```

### What the gate caught

First attempt assumed `USE1-NatGateway-Bytes`. The API returned **empty**. The
real code set, discovered with
`aws pricing get-attribute-values --attribute-name usagetype`:

```
NatGateway-Bytes               exists, unprefixed = us-east-1
USE1-NatGateway-Bytes          DOES NOT EXIST
USE1-RegionalNatGateway-Bytes  exists, WITH the prefix
```

Three distinct products behind similar strings:

| Code | What it is |
|---|---|
| `NatGateway-Hours` / `-Bytes` | standard NAT: hourly + data processing |
| `RegionalNatGateway-Hours` / `-Bytes` | regional NAT, automatic multi-AZ expansion |
| `NatGateway-Prvd-Bytes` / `-Prvd-Gbps` | provisioned throughput, billed in Gbps |

Had the decode been skipped, levers would have been researched for whichever
product was guessed.

---

## Step 5 -- RESEARCH LEVERS (gate)

Supporting rates, all retrieved live:

| SKU | Usage type | Rate | Source |
|---|---|---|---|
| `M2YSHUBETB3JX4M4` | `NatGateway-Hours` | $0.045 / Hrs | pricing API, v20261107002852 |
| `EN2N5TATXE673A3B` | `USE1-VpcEndpoint-Hours` | $0.01 / Hrs | pricing API, v20261105181945 |
| `DQYYEZBCWSW5XS2R` | `USE1-VpcEndpoint-Bytes` | tiered, below | pricing API, v20261105181945 |
| n/a | gateway endpoint | $0.00 | docs, quoted below |

### Tier walking (D6), observed on `USE1-VpcEndpoint-Bytes`

Response order from the API, verbatim:

```
1st dimension   begin 0          end 1,048,576    $0.010/GB
2nd dimension   begin 5,242,880  end Inf          $0.004/GB
3rd dimension   begin 1,048,576  end 5,242,880    $0.006/GB
```

Not in range order. Sorting by `beginRange` is mandatory. Taking the first
dimension is correct here by luck and silently wrong above 1 PB/month.

---

### L1 -- S3 / DynamoDB gateway endpoints

| Field | Value |
|---|---|
| mechanism | "Gateway VPC endpoints provide reliable connectivity to Amazon S3 and DynamoDB without requiring an internet gateway or a NAT device for your VPC." |
| mechanism source | https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html (fetched 2026-11-08, tier 1) |
| rate after | $0.00. "There is no additional charge for using gateway endpoints." |
| rate source | same page, tier 1. Corroborated by absence of any gateway-endpoint usage type in the pricing API |
| limitation 1 | Amazon S3 and DynamoDB only. No other service. |
| limitation 2 | Same-region only: "Traffic that's destined for the service (Amazon S3 or DynamoDB) in a different Region goes to the internet gateway because prefix lists are specific to a Region." |
| limitation 3 | Route-table association, not VPC presence, is what takes effect: "All instances in the subnets associated with a route table associated with a gateway endpoint automatically use the gateway endpoint [...] Instances in subnets that aren't associated with these route tables use the public service endpoint, not the gateway endpoint." |
| limitation source | same page, tier 1, current docs |

`proof_required`: a private subnet whose route table sends `0.0.0.0/0` to a NAT
gateway **and** is not associated with an S3 or DynamoDB gateway endpoint route.

> **Correction to the design.** I had written the evidence as "VPCs with no
> gateway endpoint". The doc makes that insufficient: an endpoint can exist in the
> VPC while a given private subnet's route table is not associated with it, and
> that subnet still egresses via NAT. The check is per route table, not per VPC.

---

### L2 -- Interface (PrivateLink) endpoints for other AWS services

| Field | Value |
|---|---|
| mechanism | PrivateLink interface endpoint keeps service-bound traffic off the NAT path. `endpointType: PrivateLink` on the SKU. |
| rate after | $0.01 / endpoint-hour, plus tiered data processing from $0.010/GB |
| rate source | pricing API, SKUs `EN2N5TATXE673A3B` and `DQYYEZBCWSW5XS2R`, v20261105181945 |
| limitation | hourly charge is per endpoint per AZ, so it multiplies with AZ count. Only pays off above a traffic threshold. |

Breakeven, from live rates (list basis, 3 AZs):

```
fixed     $0.01/hr x 730 hr x 3 AZ            = $21.90 / month
variable  $0.045 - $0.010                     = $0.035 / GB saved
breakeven $21.90 / $0.035                      = ~626 GB / month

At the customer's effective NAT rate of $0.03024/GB, and assuming the endpoint
rate is discounted proportionally, breakeven rises to roughly 930 GB/month.
Flagged as an assumption: the endpoint's effective rate is not yet observable,
because the customer has no endpoint usage to divide.
```

`proof_required`: per-destination-service traffic split for NAT egress.

---

### L3 -- Per-AZ NAT gateway placement

| Field | Value |
|---|---|
| mechanism | a NAT gateway in each AZ avoids cross-AZ data transfer for egress originating in that AZ |
| rate | $0.045 / NAT-hour, SKU `M2YSHUBETB3JX4M4` |
| limitation | one NAT per AZ adds $0.045/hr each, so the hourly cost scales with AZ count. Also note `RegionalNatGateway-*` exists as a distinct SKU for automatic multi-AZ expansion, per the NAT gateway user guide contents. |

`proof_required`: NAT gateway count and subnet AZ mapping per VPC.

---

## Step 6 -- CONFIRM (simulated evidence, real call shapes)

### L1 -> APPLICABLE

```bash
aws ec2 describe-vpcs --region us-east-1
aws ec2 describe-nat-gateways --region us-east-1
aws ec2 describe-route-tables --region us-east-1
aws ec2 describe-vpc-endpoints --region us-east-1 \
  --filters Name=vpc-endpoint-type,Values=Gateway
```

```
7 VPCs, 11 NAT gateways
18 private route tables send 0.0.0.0/0 to a NAT gateway
of those, 11 are NOT associated with an S3 gateway endpoint route
          14 are NOT associated with a DynamoDB gateway endpoint route
affected VPCs: vpc-aaaa, vpc-bbbb, vpc-cccc, vpc-dddd
-> APPLICABLE
```

Saving is bounded by the S3/DynamoDB share of NAT egress, which is the same
unknown as L2. Stated as a bound, not a point estimate:

```
if 40% of the 410,000 GB is S3/DynamoDB bound:
  164,000 GB x $0.03024 (effective) = $4,959 / month
  164,000 GB x $0.04500 (list)      = $7,380 / month
reported: "up to $4,959/mo at the customer's effective rate, contingent on the
S3/DynamoDB share, which flow-log analysis would confirm."
```

### L2 -> INDETERMINATE

```
needs:   per-destination-service split of NAT egress
only source: VPC Flow Logs
blocked: logs:GetLogEvents and logs:FilterLogEvents are DENIED by
         CorgiroReadOnlyRole-DataPlaneDeny
-> INDETERMINATE
   "Breakeven is ~626 GB/month per service at list rates. Corgiro cannot
    determine the per-service split: VPC Flow Log reads are outside its
    read-only boundary. Run an Athena query over flow logs, or ask the workload
    owner which services dominate egress."
```

### L3 -> NOT APPLICABLE

```bash
aws ec2 describe-nat-gateways --region us-east-1
aws ec2 describe-subnets --region us-east-1
```

```
all 7 VPCs already have one NAT gateway per in-use AZ
-> NOT APPLICABLE
   "Already implemented. 11 NAT gateways across 7 VPCs, one per in-use AZ.
    No cross-AZ egress penalty to recover."
```

---

## Report row

```
HIGH   NatGateway-Bytes   $12,400/mo   111111111111, 222222222222   us-east-1
       effective rate $0.03024/GB (32.8% below list $0.045)

  APPLICABLE      Add S3 + DynamoDB gateway endpoints to 11 private route
                  tables in vpc-aaaa/bbbb/cccc/dddd. No additional charge.
                  Up to $4,959/mo, contingent on S3/DynamoDB egress share.
                  [docs: gateway-endpoints] [sku 59S5R83GFPUAGVR5]

  INDETERMINATE   Interface endpoints for other services. Breakeven ~626 GB/mo
                  per service (3 AZ, list rates). Per-service split needs flow
                  logs, outside Corgiro's read-only boundary.
                  [sku EN2N5TATXE673A3B, DQYYEZBCWSW5XS2R]

  NOT APPLICABLE  Per-AZ NAT placement. Already one NAT per in-use AZ in all
                  7 VPCs. [sku M2YSHUBETB3JX4M4]
```

---

## Spike verdict

| Design decision | Held up? |
|---|---|
| D5 decode gate | **Yes, and it fired immediately.** The assumed code did not exist. |
| D6 tier walking | **Yes.** Dimensions came back out of range order. |
| D8 effective rate | **Yes.** 32.8% gap between effective and list on one line. |
| D3 three verdicts | **Yes.** All three occurred naturally on a single cost line. |
| D12 source tiers | Yes, though every fact here resolved at tier 0 or 1. The blog-staleness rule was not exercised. |

One design change required:

- **L1 evidence is per route table, not per VPC.** The doc is explicit that subnet
  route-table association determines whether the endpoint takes effect. Checking
  only for endpoint presence in the VPC would produce false NOT APPLICABLE
  verdicts.

Two things the spike could not test:

- Steps 3 and 6 against a live account.
- A lever whose only limitation source is a blog, which is where D12's staleness
  rule earns its keep.
