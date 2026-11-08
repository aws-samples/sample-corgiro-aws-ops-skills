# Lever Catalogue

A **cache**, not a gate. Step 5 researches levers live; this file stores results
from previous successful runs so a recognised product costs zero searches.

The mode works correctly with this file empty or absent. Nothing here is a
prerequisite, and no entry is required before a service can be analyzed.

## Key

Entries are keyed on the **decoded identity** from Step 4, never on a raw
usage-type string:

```
service_code | productFamily | operation | unit
```

So one entry covers every regional variant of a product (all ~180 NAT
usage-type codes, for instance) while keeping genuinely different products apart.
A regex over raw strings would fold `NatGateway-Prvd-Bytes` into the standard NAT
lever set, which is exactly the failure Step 4 exists to prevent.

## Using an entry

```
1  look up catalogue_key
2  RE-FETCH every stored source URL     confirm it still says what it said
3  RE-PULL every rate from pricing:GetProducts   prices move
4  proceed to Step 6
```

Never serve a cached rate. The stored SKU tells you what to re-pull, not what to
quote.

If a re-fetched page no longer supports the stored mechanism or limitation, treat
the entry as stale: fall back to live research for that lever and update the
entry afterwards.

## Appending an entry

Only after a run where the lever reached a verdict against real accounts. Mirrors
how `ask` offers to promote a validated run into a permanent mode: the catalogue
grows from engagements, not from a taxonomy guessed up front.

Record what Step 5 resolved, plus the resolved URLs. Do not record savings,
account IDs, resource IDs, or anything customer-specific.

---

## AmazonEC2 | NAT Gateway | NatGateway | GB

Per-GB data processed by NAT gateways.
`groupDescription`: "Charge for per GB data processed by NatGateways".
Pricing SKU for the current path: `59S5R83GFPUAGVR5` (us-east-1).

Related SKUs: `M2YSHUBETB3JX4M4` (`NatGateway-Hours`, hourly charge).

> Sibling products that are **not** this entry: `RegionalNatGateway-*` (regional
> NAT, automatic multi-AZ expansion) and `NatGateway-Prvd-*` (provisioned
> throughput, billed in Gbps). Different `operation` or `unit`, different levers.

### L1 -- S3 / DynamoDB gateway endpoints

| Field | Value |
|---|---|
| mechanism | Gateway VPC endpoints provide connectivity to Amazon S3 and DynamoDB without requiring an internet gateway or a NAT device for the VPC. |
| mechanism source | https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html (tier 1) |
| rate after | `$0.00`. "There is no additional charge for using gateway endpoints." Same page. Corroborated by the absence of any gateway-endpoint usage type in the pricing API, though the citation is the authority, not the absence. |
| limitation 1 | Amazon S3 and DynamoDB only. No other service. |
| limitation 2 | Same-region only. "Traffic that's destined for the service (Amazon S3 or DynamoDB) in a different Region goes to the internet gateway because prefix lists are specific to a Region." |
| limitation 3 | Route-table association, **not** VPC presence, determines effect. "All instances in the subnets associated with a route table associated with a gateway endpoint automatically use the gateway endpoint [...] Instances in subnets that aren't associated with these route tables use the public service endpoint, not the gateway endpoint." |
| limitation source | same page, tier 1, current documentation |
| proof_required | A private subnet whose route table sends `0.0.0.0/0` to a NAT gateway **and** which is not associated with an S3 or DynamoDB gateway endpoint route. Evaluate **per route table**, not per VPC. |
| evidence calls | `ec2:DescribeRouteTables`, `ec2:DescribeVpcEndpoints` (filter `vpc-endpoint-type=Gateway`), `ec2:DescribeNatGateways`, `ec2:DescribeSubnets` |
| saving bound | Bounded by the S3/DynamoDB share of NAT egress, which no read-only API exposes. Report a bound and its condition, never a point estimate. |
| effort | Low. Additive, no data-path change for other traffic. |

### L2 -- Interface (PrivateLink) endpoints for other AWS services

| Field | Value |
|---|---|
| mechanism | A PrivateLink interface endpoint keeps traffic to a supported AWS service off the NAT path. SKU attribute `endpointType: PrivateLink`. |
| rate after | `$0.01` per endpoint-hour (`EN2N5TATXE673A3B`) plus tiered data processing from `$0.010/GB` (`DQYYEZBCWSW5XS2R`). **Tiered: walk the dimensions, sorted by `beginRange`.** |
| rate source | pricing API, service code `AmazonVPC` (tier 0) |
| limitation | The hourly charge is per endpoint **per AZ**, so fixed cost scales with AZ count. The lever only pays off above a traffic threshold. |
| proof_required | Per-destination-service split of NAT egress. |
| evidence calls | none sufficient. The split is only in VPC Flow Logs, and `logs:FilterLogEvents` is denied by `CorgiroReadOnlyRole-DataPlaneDeny`. |
| expected verdict | `INDETERMINATE` on a stock deployment. Report the breakeven and name the data gap. |
| breakeven | `(0.01 x 730 x AZ_count) / (effective_nat_rate - endpoint_rate_per_GB)`. At list rates with 3 AZs: `$21.90 / $0.035` = ~626 GB/month per service. Recompute at the customer's effective rate. |
| effort | Medium. Per-service, and DNS behaviour changes for the targeted service. |

### L3 -- Per-AZ NAT gateway placement

| Field | Value |
|---|---|
| mechanism | A NAT gateway in each AZ avoids cross-AZ data transfer for egress originating in that AZ. |
| rate | `$0.045` per NAT-hour (`M2YSHUBETB3JX4M4`, us-east-1) |
| limitation | One NAT per AZ adds a full hourly charge each, so the fixed cost scales with AZ count. Consider `RegionalNatGateway-*` where automatic multi-AZ expansion is preferable. |
| proof_required | NAT gateway count per VPC versus the set of in-use AZs for its private subnets. |
| evidence calls | `ec2:DescribeNatGateways`, `ec2:DescribeSubnets` |
| expected verdict | Frequently `NOT APPLICABLE`: most estates already run one NAT per AZ. Report it as already-implemented rather than omitting it. |
| effort | Low to Medium. Route-table changes per subnet. |

---

## AmazonEC2 | Compute Instance | RunInstances | Hrs

EC2 instance hours. Carries two lever classes beyond configuration.

### L1 -- capacity: rightsize an over-provisioned instance

| Field | Value |
|---|---|
| class | capacity |
| mechanism | Move the instance to a smaller or newer type whose projected utilization still meets the workload. |
| rate after | `recommendationOptions[].instanceType` priced via `pricing:GetProducts`, or take `savingsOpportunity` directly. |
| grounding source | `compute-optimizer:GetEC2InstanceRecommendations` (tier 0). Supplies the verdict, the evidence and the limitations in one call. |
| limitation | `performanceRisk`, `migrationEffort` and `platformDifferences`, all returned per recommendation option. |
| proof_required | `finding == Overprovisioned`, with `utilizationMetrics` as the evidence and `lookBackPeriodInDays` as the window. |
| evidence calls | `compute-optimizer:GetEC2InstanceRecommendations`. Fallback when not opted in: `cloudwatch:GetMetricData` on `CPUUtilization`, `NetworkIn`, `NetworkOut`, with stated thresholds. |
| saving | gross `savingsOpportunity`; realizable `savingsOpportunityAfterDiscounts`, which already includes SP and RI discounts. |
| effort | From `migrationEffort`. Usually requires a stop/start or replacement. |
| notes | `Memory` appears in `utilizationMetrics` only with the CloudWatch agent installed. Report its absence rather than ruling the lever out on CPU alone. Compute Optimizer not being opted in is itself a finding; the basic tier is free. |

### L2 -- commitment: cover stable on-demand usage

| Field | Value |
|---|---|
| class | commitment |
| mechanism | Commit to a 1 or 3 year hourly spend in exchange for a discounted rate on matching usage. |
| rate after | `estimatedSavingsPercentage` and `estimatedMonthlySavings` from the recommendation. |
| grounding source | `ce:GetSavingsPlansPurchaseRecommendation` (tier 0). Use `ce:GetReservationPurchaseRecommendation` for service-specific RIs. |
| limitation | The commitment is binding for the term. Flexibility varies by type: Compute SP spans EC2, Fargate and Lambda; EC2 Instance SP locks to family and region for a deeper discount. Carry `term` and `paymentOption` on the recommendation. |
| proof_required | A material on-demand share in `purchase_mix` on a commitment-eligible service, **and** a non-empty purchase recommendation. One without the other is not a finding. |
| evidence calls | `purchase_mix` from Step 3, plus the recommendation API. |
| expected verdict | `INDETERMINATE` when the recommendation comes back empty: AWS declines to recommend on volatile or insufficient usage history, which is information, not an error. |
| effort | Low to execute, high to reverse. Flag the term length as the real cost. |
| notes | Run it only for commitment-eligible services. NAT, data transfer, EIP, S3 and CloudWatch are not eligible, so skip the call rather than reporting an empty result as a gap. |

---

## Entry template

```markdown
## <service_code> | <productFamily> | <operation> | <unit>

<one-line description, quoting groupDescription>
Pricing SKU for the current path: `<sku>` (<region>).

### L<n> -- <lever name>

| Field | Value |
|---|---|
| mechanism | |
| mechanism source | <url> (tier <n>) |
| rate after | |
| rate source | |
| limitation | |
| limitation source | <url> (tier <n>, published <date> if tier 3) |
| proof_required | |
| evidence calls | |
| expected verdict | |
| effort | |
```

Fields follow the lever record in
[`step-5-research.md`](step-5-research.md). A lever with no citable mechanism or
no citable limitation does not belong in this file, for the same reason it does
not ship from live research.
