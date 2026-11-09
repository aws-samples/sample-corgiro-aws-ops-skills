# Traffic Attribution (Steps 2-4)

How `vpce-costopt` finds NAT Gateway traffic bound for in-region AWS public endpoints, using only billing data and read-only describe calls.

## What the bill tells us

Cost Explorer reports NAT Gateway and data transfer charges under the `EC2 - Other` service. The usage types this mode reads (region code prefix varies, e.g. `APS1-`, `EUW1-`; us-east-1 often has no prefix - always resolve the exact values, never assume them):

| Usage type suffix | Operation | Meaning |
|-------------------|-----------|---------|
| `NatGateway-Bytes` | `NatGateway` | GB processed by NAT Gateways (data processing charge) |
| `NatGateway-Hours` | `NatGateway` | NAT Gateway hours (unchanged by this optimization - not modeled) |
| `DataTransfer-Regional-Bytes` | `PublicIP-In` / `PublicIP-Out` | Transfer to/from public IPs **in the same region** - for a NAT Gateway this is traffic to in-region AWS service public endpoints |
| `DataTransfer-Regional-Bytes` | `InterZone-In` / `InterZone-Out` | Cross-AZ transfer (used only to derive the cross-AZ unit price) |
| `VpcEndpoint-Hours` / `VpcEndpoint-Bytes` | _varies_ | Existing interface endpoint charges (used to derive endpoint unit prices) |

The signal is `PublicIP-In` + `PublicIP-Out` regional transfer charged to a NAT Gateway: that is the traffic a VPC endpoint could carry instead. Internet-bound NAT traffic is billed as `DataTransfer-Out-Bytes` and cannot move to an endpoint.

## A. Billing pull (payer, Step 2)

All calls run in `us-east-1` from the payer-level session (`cross-account-role`: tooling/management session with local creds; `identity-center-direct`: `--profile <profilePrefix><payerAccountId>`). `<start>` = first day of `month`, `<end>` = first day of the following month.

1. Resolve exact usage type values (repeat for each search string: `NatGateway-Bytes`, `DataTransfer-Regional-Bytes`, `VpcEndpoint`):

   ```bash
   aws ce get-dimension-values \
     --time-period Start=<start>,End=<end> \
     --dimension USAGE_TYPE --search-string NatGateway-Bytes \
     --region us-east-1 --output json
   ```

   Keep values whose suffix matches exactly. Cost Explorer dimension filters on `get-cost-and-usage` match exact values only, so the resolved list is what goes into the filters below.

   Observed against real billing data - follow these rules:

   - **Never map a prefix to a region yourself.** Prefixes are not derivable from region names (`APS9-` is ap-southeast-7, `APS7-` is ap-southeast-5, `EU-` is eu-west-1), and the same region can be unprefixed for one service and prefixed for another (us-east-1 is `NatGateway-Bytes` but `USE1-VpcEndpoint-Bytes`). Always group by the `REGION` dimension and read the region from the result.
   - The `VpcEndpoint` search also returns `*-VpcEndpoint-GWLBE-Hours` / `-Bytes` (Gateway Load Balancer endpoints), `*-VpcEndpoint-Service-Hours` (endpoint *service* owner charges) and `*-VpcEndpoint-Tunnel-Hours`. Keep only values ending exactly in `-VpcEndpoint-Hours` and `-VpcEndpoint-Bytes` that contain neither `GWLBE` nor `Service`; the others are not interface endpoint prices.

2. NAT Gateway data processing per account/region:

   ```bash
   aws ce get-cost-and-usage \
     --time-period Start=<start>,End=<end> --granularity MONTHLY \
     --metrics UnblendedCost UsageQuantity \
     --filter '{"And":[
       {"Dimensions":{"Key":"USAGE_TYPE","Values":[<NatGateway-Bytes values>]}},
       {"Dimensions":{"Key":"RECORD_TYPE","Values":["Usage"]}}]}' \
     --group-by Type=DIMENSION,Key=LINKED_ACCOUNT Type=DIMENSION,Key=REGION \
     --region us-east-1 --output json
   ```

3. In-region public-IP transfer per account/region:

   ```bash
   aws ce get-cost-and-usage \
     --time-period Start=<start>,End=<end> --granularity MONTHLY \
     --metrics UnblendedCost UsageQuantity \
     --filter '{"And":[
       {"Dimensions":{"Key":"USAGE_TYPE","Values":[<DataTransfer-Regional-Bytes values>]}},
       {"Dimensions":{"Key":"OPERATION","Values":["PublicIP-In","PublicIP-Out"]}},
       {"Dimensions":{"Key":"RECORD_TYPE","Values":["Usage"]}}]}' \
     --group-by Type=DIMENSION,Key=LINKED_ACCOUNT Type=DIMENSION,Key=REGION \
     --region us-east-1 --output json
   ```

   Always include the `RECORD_TYPE = Usage` clause. Without it, credits and refunds come back as negative-cost rows with `REGION = NoRegion` and distort per-region unit prices. Use the exact `OPERATION` values `PublicIP-In` / `PublicIP-Out`; the same usage types also carry `LoadBalancing-PublicIP-*` and `LoadBalancing-NLB-PublicIP-*`, which are load balancer traffic, not NAT traffic.

   For the report's "How to read your bill" table, also run this call once more for the diagram region only (the region with the highest NAT data processing cost), filtered to that region's `NatGateway-Bytes`, `DataTransfer-Regional-Bytes` and `VpcEndpoint-*` usage types, with `--group-by Type=DIMENSION,Key=USAGE_TYPE Type=DIMENSION,Key=OPERATION`. That splits `PublicIP-Out` from `PublicIP-In` and `InterZone-Out` from `InterZone-In`, and returns the real operation names for the endpoint lines. Cost Explorer allows at most two group-by keys, which is why this is a separate call.

   Run the same call with `OPERATION` = `InterZone-In`,`InterZone-Out` to derive the cross-AZ unit price, and once filtered to the resolved `VpcEndpoint-*` usage types grouped by `REGION` + `USAGE_TYPE` to derive endpoint unit prices where the customer already runs endpoints (see `savings-model.md`).

4. Resource-level attribution (preferred, optional). Cost Explorer resource-level data must be enabled on the payer for `EC2 - Other`, and covers only the **last 14 days**:

   ```bash
   aws ce get-cost-and-usage-with-resources \
     --time-period Start=<14-days-ago>,End=<today> --granularity DAILY \
     --metrics UnblendedCost UsageQuantity \
     --filter '{"And":[
       {"Dimensions":{"Key":"SERVICE","Values":["EC2 - Other"]}},
       {"Dimensions":{"Key":"USAGE_TYPE","Values":[<DataTransfer-Regional-Bytes values>]}},
       {"Dimensions":{"Key":"OPERATION","Values":["PublicIP-In","PublicIP-Out"]}}]}' \
     --group-by Type=DIMENSION,Key=RESOURCE_ID Type=DIMENSION,Key=LINKED_ACCOUNT \
     --region us-east-1 --output json
   ```

   Paginate with `--next-page-token`. NAT Gateway rows have `RESOURCE_ID = arn:aws:ec2:<region>:<account>:natgateway/nat-<id>`. Keep rows whose `RESOURCE_ID` contains `natgateway/nat-` (case-insensitive) - these are public-IP transfer charges billed to a specific NAT Gateway; take the region from the ARN. Expect the same call to also return EC2 instance IDs (`i-...`): that is instances with public IPs talking to in-region endpoints directly, not NAT traffic. Exclude them from attribution, but report their total GB in the Recommendations (it is the reason the proportional fallback needs its cap). Scale to a monthly figure: `value x (days in month / days in window)`. Record `attribution: resource-level` for every account/region with at least one matching row.

   The 14-day window ends today, so it rarely lines up with `month`. State both date ranges in the Methodology.

   If the call fails with `DataUnavailableException` or a `ValidationException` about resource-level data, record `attribution: proportional` for all pairs and continue.

Write all responses to `billing.json`. CE amounts are strings - parse them as decimals and round only at final output.

## B. Inventory and metrics (per account + region, Steps 3-4)

Apply the resolved per-account credentials (`--profile <profilePrefix><accountId>` for `via: sso`, or the exported AssumeRole credentials for `via: assume-role`). Paginate every call with `--next-token`.

```bash
aws ec2 describe-nat-gateways \
  --filter Name=state,Values=available --region <region> --output json
aws ec2 describe-subnets --region <region> --output json
aws ec2 describe-route-tables --region <region> --output json
aws ec2 describe-vpc-endpoints --region <region> --output json
```

- Keep NAT Gateways with `ConnectivityType = public`. Private NAT Gateways do not reach AWS public endpoints; list them as out of scope.
- **Routed subnets per NAT Gateway:** for each route table, find routes with `DestinationCidrBlock = 0.0.0.0/0` and a `NatGatewayId`. Its subnets are the `Associations[].SubnetId` entries; if the table has `Associations[].Main = true`, it also applies to every subnet in that VPC with no explicit association. Map each subnet to its `AvailabilityZone` from `describe-subnets`.
- **Endpoints per VPC:** from `describe-vpc-endpoints`, record `VpcEndpointType`, `ServiceName`, and `State`. A VPC has an S3 gateway endpoint only if a `Gateway`-type endpoint for `com.amazonaws.<region>.s3` is `available` (an S3 *interface* endpoint does not count); same for `com.amazonaws.<region>.dynamodb`.

NAT Gateway byte metrics for `month` (one query per metric per NAT Gateway, up to 500 queries per call):

```bash
aws cloudwatch get-metric-data \
  --metric-data-queries file://<run_dir>/nat-metric-queries.json \
  --start-time <start>T00:00:00Z --end-time <end>T00:00:00Z \
  --region <region> --output json
```

Each query: namespace `AWS/NATGateway`, dimension `NatGatewayId`, metrics `BytesOutToDestination` and `BytesInFromDestination`, `Stat: Sum`, `Period: 86400`. Write the query file inside the run directory, not a shared temp path. Sum the daily values per NAT Gateway.

## Proportional attribution (fallback)

When resource-level data is unavailable for an account/region:

1. `P` = in-region public-IP GB for the account/region (step A3). `N` = NAT-processed GB for the account/region (step A2).
2. Cap: `G_total = min(P, N)`. Public-IP regional transfer can also come from instances with public IPs or load balancers; the cap stops that traffic from being attributed beyond what NAT Gateways actually processed. The result is an **upper bound**.
3. Split `G_total` across the account/region's public NAT Gateways by each one's share of `BytesOutToDestination + BytesInFromDestination`. If CloudWatch returned nothing, split evenly and record `attribution: even-split`.

Record the attribution method per account/region; the report shows it on every row.
