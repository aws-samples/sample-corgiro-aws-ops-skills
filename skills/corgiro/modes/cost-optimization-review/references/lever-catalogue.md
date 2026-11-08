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

> **No rate in this file is an input.** Every figure here illustrates the shape
> of a calculation. Prices move, and the customer's effective rate is usually
> below list. Re-pull every number from the pricing API on each run.

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

`NatGateway-Hours` (SKU `M2YSHUBETB3JX4M4`) is a **separate entry** under this
key scheme: same product family, different `unit` (`Hrs`). It is referenced by L3
below because the per-AZ lever trades GB against hours, but its levers are not
these.

> Sibling products that are **not** this entry: `RegionalNatGateway-*` (regional
> NAT, automatic multi-AZ expansion) and `NatGateway-Prvd-*` (provisioned
> throughput, billed in Gbps). Different `operation` or `unit`, different levers.

### L1 -- S3 / DynamoDB gateway endpoints

| Field | Value |
|---|---|
| class | configuration |
| mechanism | Gateway VPC endpoints provide connectivity to Amazon S3 and DynamoDB without requiring an internet gateway or a NAT device for the VPC. |
| mechanism source | https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html (tier 1) |
| rate after | `$0.00`. "There is no additional charge for using gateway endpoints." Same page. Corroborated by the absence of any gateway-endpoint usage type in the pricing API, though the citation is the authority, not the absence. |
| limitation 1 | Amazon S3 and DynamoDB only. No other service. |
| limitation 2 | Same-region only. "Traffic that's destined for the service (Amazon S3 or DynamoDB) in a different Region goes to the internet gateway because prefix lists are specific to a Region." |
| limitation 3 | Route-table association, **not** VPC presence, determines effect. "All instances in the subnets associated with a route table associated with a gateway endpoint automatically use the gateway endpoint [...] Instances in subnets that aren't associated with these route tables use the public service endpoint, not the gateway endpoint." |
| limitation source | same page, tier 1, current documentation |
| proof_required | A private subnet whose route table sends `0.0.0.0/0` to a NAT gateway **and** which is not associated with an S3 or DynamoDB gateway endpoint route. Evaluate **per route table**, not per VPC. |
| if_unprovable | "Identify the destinations of traffic through NAT. Where it is bound for an AWS service, use a VPC endpoint." Corgiro can prove the routing gap but never the destination mix, so this clause is used on essentially every run. |
| evidence calls | `ec2:DescribeRouteTables`, `ec2:DescribeVpcEndpoints` (filter `vpc-endpoint-type=Gateway`), `ec2:DescribeNatGateways`, `ec2:DescribeSubnets` |
| saving | `gross` from the full line; `bound` narrowed by the S3/DynamoDB share of NAT egress, which no read-only API exposes, with a mandatory `bound_condition`. Never a point estimate. |
| effort | Low. Additive, no data-path change for other traffic. |

**Recommendation text.** Do not write "use S3/DynamoDB gateway endpoints": that
asserts a destination mix Corgiro cannot see. Write the routing gap as the
verified fact, then the verification step, then the grounded economics:

> "<N> private route tables in <vpcs> send `0.0.0.0/0` to a NAT gateway and are
> not associated with an S3 or DynamoDB gateway endpoint route. Identify the
> destinations of that NAT traffic. Where it is bound for an AWS service, add the
> appropriate VPC endpoint: gateway endpoints for S3 and DynamoDB carry no
> additional charge, interface endpoints break even around <X> GB/month per
> service."

### L2 -- Interface (PrivateLink) endpoints for other AWS services

| Field | Value |
|---|---|
| class | configuration |
| mechanism | A PrivateLink interface endpoint keeps traffic to a supported AWS service off the NAT path. SKU attribute `endpointType: PrivateLink`. |
| rate after | `$0.01` per endpoint-hour (`EN2N5TATXE673A3B`) plus tiered data processing from `$0.010/GB` (`DQYYEZBCWSW5XS2R`). **Tiered: walk the dimensions, sorted by `beginRange`.** |
| rate source | pricing API, service code `AmazonVPC` (tier 0) |
| limitation | The hourly charge is per endpoint **per AZ**, so fixed cost scales with AZ count. The lever only pays off above a traffic threshold. |
| proof_required | Per-destination-service split of NAT egress. |
| if_unprovable | "Identify which AWS services dominate NAT egress, from VPC Flow Logs or from the workload owner. Add an interface endpoint for any service above the breakeven volume." |
| evidence calls | none sufficient. The split is only in VPC Flow Logs, and `logs:FilterLogEvents` is denied by `CorgiroReadOnlyRole-DataPlaneDeny`. |
| expected verdict | `SCOPED` on a stock deployment. State the boundary as a fact, give the breakeven, and give the action. Never phrase it as an apology. |
| breakeven | `(endpoint_hourly_rate x 730 x AZ_count) / (effective_nat_rate - endpoint_rate_per_GB)`. Illustrative only, at list rates with 3 AZs: `$21.90 / $0.035` = ~626 GB/month per service. Recompute every term from the pricing API at run time. |
| effort | Medium. Per-service, and DNS behaviour changes for the targeted service. |

### L3 -- Per-AZ NAT gateway placement

| Field | Value |
|---|---|
| class | configuration |
| mechanism | A NAT gateway in each AZ avoids cross-AZ data transfer for egress originating in that AZ. |
| rate | `$0.045` per NAT-hour (`M2YSHUBETB3JX4M4`, us-east-1) |
| limitation | One NAT per AZ adds a full hourly charge each, so the fixed cost scales with AZ count. Consider `RegionalNatGateway-*` where automatic multi-AZ expansion is preferable. |
| proof_required | NAT gateway count per VPC versus the set of in-use AZs for its private subnets. |
| if_unprovable | n/a. Fully provable from `describe` calls. |
| evidence calls | `ec2:DescribeNatGateways`, `ec2:DescribeSubnets` |
| expected verdict | Frequently `ALREADY DONE`: most estates already run one NAT per AZ. Report it as implemented rather than omitting it, so the customer is not re-pitched it later. |
| effort | Low to Medium. Route-table changes per subnet. |

---

## AmazonEC2 | Compute Instance | RunInstances | Hrs

EC2 instance hours. Carries capacity and commitment levers; configuration levers
for this product are researched live and not yet cached here.

### L1 -- capacity: rightsize an over-provisioned instance

| Field | Value |
|---|---|
| class | capacity |
| mechanism | Move the instance to a smaller or newer type whose projected utilization still meets the workload. |
| rate after | `recommendationOptions[].instanceType` priced via `pricing:GetProducts`, or take `savingsOpportunity` directly. |
| grounding source | `compute-optimizer:GetEC2InstanceRecommendations` (tier 0). Supplies the verdict, the evidence and the limitations in one call. |
| limitation | `performanceRisk`, `migrationEffort` and `platformDifferences`, all returned per recommendation option. |
| proof_required | `finding == Overprovisioned`, with `utilizationMetrics` as the evidence and `lookBackPeriodInDays` as the window. |
| if_unprovable | "Enable AWS Compute Optimizer (the basic tier is free) to identify which instances are over-provisioned and by how much. Rightsizing applies to any EC2 fleet; only the targets are unknown until it is enabled." |
| evidence calls | `compute-optimizer:GetEC2InstanceRecommendations`. Fallback when not opted in: `cloudwatch:GetMetricData` on `CPUUtilization`, `NetworkIn`, `NetworkOut`, with stated thresholds. |
| saving | `gross` = `savingsOpportunity.estimatedMonthlySavings`; `realizable` = `savingsOpportunityAfterDiscounts.estimatedMonthlySavings`, which already nets SP and RI discounts. Do not apply coverage a second time. |
| effort | From `migrationEffort`. Usually requires a stop/start or replacement. |
| notes | `Memory` appears in `utilizationMetrics` only with the CloudWatch agent installed. Report its absence rather than ruling the lever out on CPU alone. Compute Optimizer not being opted in is itself a finding; the basic tier is free. |

### L2 -- commitment: cover stable on-demand usage

| Field | Value |
|---|---|
| class | commitment |
| mechanism | Commit to a 1 or 3 year hourly spend in exchange for a discounted rate on matching usage. |
| grounding source | CE commitment coverage from Step 3 Call 4 (tier 0) for the gap; documentation (tier 1) for the SP-type trade-offs. |
| limitation | Binding for the term. Flexibility varies by type: Compute SP spans EC2, Fargate and Lambda across accounts and regions; EC2 Instance SP gives a deeper discount but locks instance family and region. |
| proof_required | The uncovered on-demand share, from `SavingsPlanCoveredUsage / (SavingsPlanCoveredUsage + Usage)`. |
| if_unprovable | n/a. Coverage is always measurable from CE. |
| evidence calls | Step 3 Call 4 only. |
| expected verdict | **Always `SCOPED`.** The gap is verified; the commitment size is not knowable at this scope. |
| effort | Low to execute, high to reverse. The term length is the real cost. |
| notes | Run only for commitment-eligible services. NAT, data transfer, EIP, S3 and CloudWatch are not eligible, so skip rather than reporting an empty result as a gap. |

> **Never quote a purchase amount.** `ce:Get*PurchaseRecommendation` is not called
> by this mode. A Compute SP covers EC2, Fargate and Lambda across the whole payer
> family, so a recommended hourly commitment cannot be attributed to one cost
> line. Report the gap and the trade-off; sizing is an org-wide exercise.

**Recommendation text.**

> "EC2 instance hours are <X>% on-demand, $<N>/month uncovered. Evaluate
> commitment coverage: Compute Savings Plans cover EC2, Fargate and Lambda with
> the most flexibility; EC2 Instance Savings Plans give a deeper discount but lock
> instance family and region. Sizing a commitment requires org-wide usage
> analysis rather than this per-usage-type view."

---

## Entry template

```markdown
## <service_code> | <productFamily> | <operation> | <unit>

<one-line description, quoting groupDescription>
Pricing SKU for the current path: `<sku>` (<region>).

### L<n> -- <lever name>

| Field | Value |
|---|---|
| class | configuration \| commitment \| capacity |
| mechanism | |
| mechanism source | <url> (tier <n>) |
| rate after | |
| rate source | |
| limitation | |
| limitation source | <url> (tier <n>, published <date> if tier 3) |
| proof_required | |
| if_unprovable | |
| evidence calls | |
| saving | which of gross / bound / realizable apply, and from where |
| expected verdict | |
| effort | |
```

Fields follow the lever record in
[`step-5-research.md`](step-5-research.md). A lever with no citable mechanism or
no citable limitation does not belong in this file, for the same reason it does
not ship from live research.
