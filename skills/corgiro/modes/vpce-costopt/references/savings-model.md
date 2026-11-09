# Savings Model (Step 5)

How `vpce-costopt` turns attributed NAT Gateway traffic into a current vs proposed monthly cost per VPC.

> Never use model knowledge for prices. Every unit price comes from the customer's own bill (Step 2) or from the AWS Price List API queried during the run. If a price cannot be resolved, STOP the estimate for that region and report the gap - do not substitute a remembered value.

## Architectures compared

- **Current:** private-subnet workload -> (cross-AZ hop, if its NAT Gateway is in another AZ) -> NAT Gateway -> in-region AWS service public endpoint.
- **Proposed:** private-subnet workload -> interface VPC endpoint ENI in the same AZ -> AWS service. No NAT processing, no public-IP regional transfer, no cross-AZ hop. For S3 and DynamoDB, a **gateway** endpoint does the same with no hourly or data processing charge.

## Unit prices (per region)

| Symbol | Meaning | Source, in order |
|--------|---------|------------------|
| `p_nat` | NAT Gateway data processing, $/GB | Bill: `NatGateway-Bytes` cost / usage for the region; else Price List (`AmazonEC2`) |
| `p_rdt` | In-region public-IP transfer, $/GB (charged on In and Out) | Bill: `PublicIP-In`+`PublicIP-Out` cost / usage for the region; else Price List (`AWSDataTransfer`) |
| `p_xaz` | Cross-AZ transfer, $/GB **per direction** | Bill: `InterZone-In`+`InterZone-Out` cost / usage; else Price List (`AWSDataTransfer`, same regional usage type) |
| `p_ep_gb` | Interface endpoint data processing, $/GB (first tier) | Bill: `VpcEndpoint-Bytes` cost / usage; else Price List (`AmazonVPC`) |
| `p_ep_hr` | Interface endpoint, $/hour per endpoint per AZ | Bill: `VpcEndpoint-Hours` cost / usage; else Price List (`AmazonVPC`) |
| `H` | Hours per month | `730` |

**List prices come from the AWS Price List API, not the pricing web pages.** The PrivateLink, VPC and EC2 pricing pages render their per-region tables with JavaScript, so a static fetch returns only the us-east-1 worked examples. The Price List API is read-only and returns per-region rates directly. Its endpoint lives in `us-east-1`. Run it with any reachable member account's `CorgiroReadOnlyRole` credentials: `ReadOnlyAccess` includes `pricing:GetProducts`, but the `CorgiroOperator` role does not.

```bash
# Interface endpoint hourly + data processing (p_ep_hr, p_ep_gb)
aws pricing get-products --service-code AmazonVPC --region us-east-1 \
  --filters Type=TERM_MATCH,Field=regionCode,Value=<region> \
            Type=TERM_MATCH,Field=group,Value=VPCE:VpcEndpoint --output json
# NAT Gateway data processing (p_nat)
aws pricing get-products --service-code AmazonEC2 --region us-east-1 \
  --filters Type=TERM_MATCH,Field=usagetype,Value=<NatGateway-Bytes value for the region> --output json
# Regional / cross-AZ transfer (p_rdt, p_xaz) - lives under AWSDataTransfer, not AmazonEC2
aws pricing get-products --service-code AWSDataTransfer --region us-east-1 \
  --filters Type=TERM_MATCH,Field=usagetype,Value=<DataTransfer-Regional-Bytes value for the region> --output json
```

For endpoints, keep the product whose `usagetype` ends in `-VpcEndpoint-Hours` (hourly) and the `-VpcEndpoint-Bytes` price dimension with `beginRange = 0` (first tier). Skip `GWLBE`, `Service` and `Tunnel` usage types. `PriceList` entries are JSON strings: parse each one, then read `terms.OnDemand.*.priceDimensions.*.pricePerUnit.USD`. Take `usagetype` values from the region's Step 2 `get-dimension-values` results, never by guessing a prefix.

Bill-derived prices are the customer's effective unblended rates. A rate derived from less than 1 GB of usage is noisy - use the Price List rate in that case. Record the source of every price in `aggregated.json` and the report Methodology.

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

Under fixed assumptions the model reduces to a simple rule of thumb. Assume one NAT Gateway serving three AZs (`f = 2/3`), one interface endpoint in three AZs, `p_nat = 4.5 x p_rdt`, and `p_xaz = p_ep_gb = p_rdt`. With `X` = public-IP transfer cost (`p_rdt x G`):

```
current  = X + 4.5X + 2 x (2/3) X          = 6.833X
proposed = X + 3 x p_ep_hr x H
saving   = 5.833X - 3 x p_ep_hr x H
```

The model uses 730 hours per month, matching AWS pricing pages. Use the derivation only to sanity-check output: if a region's resolved prices match those ratios, the per-VPC result should match `5.833X - 3 x p_ep_hr x H`.

## Assumptions to state in the report

- In-region public-IP transfer through a NAT Gateway is traffic to AWS service public endpoints that support VPC endpoints. Some in-region public IPs belong to other customers' resources (for example another account's Elastic IP) and cannot move to an endpoint.
- Traffic is evenly spread across routed subnets (drives `f_n`).
- NAT Gateway hourly charges are unchanged - the NAT Gateway still serves internet-bound traffic.
- Interface endpoint data processing uses the first pricing tier.
- Resource-level attribution covers the last 14 days, scaled to a month; proportional attribution is an upper bound.
