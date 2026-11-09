# Savings Model (Step 5)

How `vpce-costopt` turns attributed NAT Gateway traffic into a current vs proposed monthly cost per VPC.

> Never use model knowledge for prices. Every unit price comes from the customer's own bill (Step 2) or from a public AWS pricing page fetched during the run. If a price cannot be resolved, STOP the estimate for that region and report the gap - do not substitute a remembered value.

## Architectures compared

- **Current:** private-subnet workload -> (cross-AZ hop, if its NAT Gateway is in another AZ) -> NAT Gateway -> in-region AWS service public endpoint.
- **Proposed:** private-subnet workload -> interface VPC endpoint ENI in the same AZ -> AWS service. No NAT processing, no public-IP regional transfer, no cross-AZ hop. For S3 and DynamoDB, a **gateway** endpoint does the same with no hourly or data processing charge.

## Unit prices (per region)

| Symbol | Meaning | Source, in order |
|--------|---------|------------------|
| `p_nat` | NAT Gateway data processing, $/GB | Bill: `NatGateway-Bytes` cost / usage for the region |
| `p_rdt` | In-region public-IP transfer, $/GB (charged on In and Out) | Bill: `PublicIP-In`+`PublicIP-Out` cost / usage for the region |
| `p_xaz` | Cross-AZ transfer, $/GB **per direction** | Bill: `InterZone-In`+`InterZone-Out` cost / usage; else the data transfer section of the EC2 on-demand pricing page |
| `p_ep_gb` | Interface endpoint data processing, $/GB (first tier) | Bill: `VpcEndpoint-Bytes` cost / usage; else the PrivateLink pricing page |
| `p_ep_hr` | Interface endpoint, $/hour per endpoint per AZ | Bill: `VpcEndpoint-Hours` cost / usage; else the PrivateLink pricing page |
| `H` | Hours per month | `730` |

Pricing pages (fetch with `web_fetch` in selective mode for the region name; record the fetch date):

- PrivateLink: https://aws.amazon.com/privatelink/pricing/
- NAT Gateway: https://aws.amazon.com/vpc/pricing/
- EC2 data transfer: https://aws.amazon.com/ec2/pricing/on-demand/

Bill-derived prices are the customer's effective unblended rates. A rate derived from less than 1 GB of usage is noisy - prefer the pricing page in that case. Record the source of every price in `aggregated.json` and the report Methodology.

## Per NAT Gateway

- `G_n` = attributed in-region public-IP GB for `month` (In + Out), per `traffic-attribution.md`.
- `f_n` = cross-AZ fraction = routed subnets in a different AZ from the NAT Gateway / all routed subnets. Assumes traffic is spread evenly across routed subnets. A NAT Gateway per AZ with zonal routing gives `f_n = 0`; one NAT Gateway serving three AZs gives `f_n = 2/3`.

```
current_n   = G_n x (p_rdt + p_nat + 2 x f_n x p_xaz)
variable_n  = G_n x p_ep_gb
```

The `2 x` on cross-AZ is because both sides of the hop are charged (`InterZone-Out` on the sender, `InterZone-In` on the receiver).

## Per VPC

- `A` = `endpoint_azs`; `auto` = number of distinct AZs among subnets routed to any NAT Gateway in the VPC.
- `E` = `endpoints_per_vpc`.

```
current      = sum(current_n)
fixed        = E x A x p_ep_hr x H
proposed     = sum(variable_n) + fixed
saving       = current - proposed
per_gb_save  = (current - sum(variable_n)) / sum(G_n)
break_even   = fixed / per_gb_save                         # GB per month
fundable     = floor((current - sum(variable_n)) / (A x p_ep_hr x H))   # endpoints the saving can pay for
```

`fundable` matters because the real design usually needs one interface endpoint per AWS service reached (ECR needs `ecr.api` + `ecr.dkr`, plus S3 for layers). If `fundable` is below the number of services the traffic likely reaches, the opportunity shrinks.

**Gateway endpoint gap.** When a VPC has NAT traffic and no S3 (or DynamoDB) gateway endpoint, report the per-GB saving `p_rdt + p_nat + 2 x f x p_xaz` with zero fixed cost. The mode cannot tell what share of `G` is S3 or DynamoDB - say so, and make "confirm the S3/DynamoDB share in flow logs" the first recommendation step.

## Reference derivation

The model generalizes this original TAM runbook formula, which assumed one NAT Gateway serving three AZs (`f = 2/3`), one interface endpoint in three AZs, `p_nat = 4.5 x p_rdt`, and `p_xaz = p_ep_gb = p_rdt`. With `X` = public-IP transfer cost (`p_rdt x G`):

```
current  = X + 4.5X + 2 x (2/3) X          = 6.833X
proposed = X + 3 x p_ep_hr x H
saving   = 5.833X - 3 x p_ep_hr x H
```

The runbook used 720 hours per month; this mode uses 730, matching AWS pricing pages. Use the derivation only to sanity-check output: if a region's resolved prices match those ratios, the per-VPC result should match `5.833X - 3 x p_ep_hr x H`.

## Assumptions to state in the report

- In-region public-IP transfer through a NAT Gateway is traffic to AWS service public endpoints that support VPC endpoints. Some in-region public IPs belong to other customers' resources (for example another account's Elastic IP) and cannot move to an endpoint.
- Traffic is evenly spread across routed subnets (drives `f_n`).
- NAT Gateway hourly charges are unchanged - the NAT Gateway still serves internet-bound traffic.
- Interface endpoint data processing uses the first pricing tier.
- Resource-level attribution covers the last 14 days, scaled to a month; proportional attribution is an upper bound.
