# Step 1: Spend Decomposition by Purchase Type

Foundation of the analysis. Shows where money is going, how much is on-demand, and separates addressable ("optimizable via commitments") on-demand from inherently on-demand and from non-reservable usage-based charges.

All calls in this step run against the **payer account** (resolved in the MODE.md prerequisite step) in `us-east-1`. Resolve credentials per [`../../../references/credential-resolution.md`](../../../references/credential-resolution.md).

## Why `AmortizedCost` is the default metric

`UnblendedCost` classifies No Upfront RI charges as "On Demand Instances" because the recurring hourly fee is billed after usage. For customers with No Upfront RIs, this **grossly inflates** the on-demand percentage — a customer at 80% RI coverage can look like 20% coverage. `AmortizedCost` correctly attributes RI spend to the Reserved bucket.

Use `NetAmortizedCost` if the operator explicitly wants negotiated-discount-adjusted numbers. Only use `UnblendedCost` on explicit request and only when the operator understands the caveat.

## Call: getCostAndUsage grouped by SERVICE + PURCHASE_TYPE

```bash
aws ce get-cost-and-usage \
  --region us-east-1 \
  --time-period Start=<lookback_start_iso>,End=<current_month_start_iso> \
  --granularity MONTHLY \
  --metrics AmortizedCost UsageQuantity \
  --group-by '[
    {"Type":"DIMENSION","Key":"SERVICE"},
    {"Type":"DIMENSION","Key":"PURCHASE_TYPE"}
  ]' \
  --filter '{
    "Not": {
      "Dimensions": {
        "Key": "RECORD_TYPE",
        "Values": ["Credit", "Refund", "Tax"]
      }
    }
  }' \
  --output json > cost-by-service-purchase-type.json
```

`<lookback_start_iso>` is the 1st of `<lookback_months>` ago; `<current_month_start_iso>` is the 1st of the current month. Both in `YYYY-MM-DD` format.

For each service, aggregate across the months to produce:

- Total spend
- On-demand spend
- Monthly-average on-demand
- Per purchase-type share (On Demand, Reserved, Savings Plans, Spot, Dedicated)

## Service classification

Split services into two buckets **before** presenting an addressable opportunity number.

### Optimizable on-demand (RI/SP-eligible)

Include in the addressable opportunity calculation:

- EC2
- RDS (Amazon Relational Database Service)
- Aurora (part of RDS billing)
- ElastiCache
- OpenSearch
- Redshift
- SageMaker
- Lambda
- Fargate (ECS + EKS)
- DynamoDB
- MemoryDB

### Inherently on-demand (NEVER addressable via commitments)

Exclude from the addressable opportunity, but present separately so the operator sees where the remaining on-demand lives. Label clearly: "These services are always on-demand — not addressable via commitments."

- AWS Support
- CloudWatch
- S3
- Elastic Load Balancing
- CloudFront
- Route 53
- AWS Marketplace
- Data Transfer (all cross-region and internet egress)
- Tax
- Secrets Manager
- KMS
- Config
- CloudTrail
- GuardDuty
- Inspector
- WAF
- Shield

## Instance-hour drill-down (critical)

For each RI-eligible service in the optimizable bucket with **more than $5K/month** in on-demand spend, run a second CE call that groups by USAGE_TYPE. Without this, the addressable opportunity is overstated — CE's `PURCHASE_TYPE=On Demand Instances` lumps instance hours in with storage, I/O, backups, data transfer, Extended Support surcharges, and Serverless v2 ACU, none of which are RI/SP-addressable.

Fire all drill-down calls in parallel (bounded by concurrency ceiling of 6 documented in MODE.md).

```bash
aws ce get-cost-and-usage \
  --region us-east-1 \
  --time-period Start=<last_month_start_iso>,End=<current_month_start_iso> \
  --granularity MONTHLY \
  --metrics AmortizedCost \
  --group-by '[{"Type":"DIMENSION","Key":"USAGE_TYPE"}]' \
  --filter '{
    "And": [
      {"Dimensions": {"Key": "SERVICE", "Values": ["<service_name>"]}},
      {"Dimensions": {"Key": "PURCHASE_TYPE", "Values": ["On Demand Instances"]}}
    ]
  }' \
  --output json > drilldown-<service_slug>.json
```

Classify each USAGE_TYPE result using service-specific regex patterns:

| Service | SERVICE filter value | Coverable USAGE_TYPE regex | What it matches |
|---------|----------------------|----------------------------|-----------------|
| RDS | `Amazon Relational Database Service` | `/InstanceUsage:\|Multi-AZUsage:\|InstanceUsageIOOpt/` | Instance hours |
| ElastiCache | `Amazon ElastiCache` | `/NodeUsage:cache\./` | Cache node hours |
| OpenSearch | `Amazon OpenSearch Service` | `/ESInstance:/` | Instance hours |
| MemoryDB | `Amazon MemoryDB` | `/NodeUsage:db\./` | Node hours |
| Redshift | `Amazon Redshift` | `/Node:dc\|Node:ds\|Node:ra/` | Node hours |

> Historical note: AWS docs sometimes still list `Amazon Elasticsearch Service` — that filter returns empty results. Always use `Amazon OpenSearch Service`.

Anything not matching the coverable regex is **non-reservable (usage-based)**. Handle `HeavyUsage:*` lines as No Upfront RI hourly fees — these are offsets against coverable instance hours, not additional on-demand spend, and should be netted out.

Only the coverable bucket flows into the addressable opportunity number that step 5's recommendations target.

## Presenting the drill-down

For each drilled-down service, present both buckets. Example:

> RDS on-demand: $127K total → $33K instance hours (optimizable via RI/SP) + $94K storage / IO / backup (usage-based, not addressable).

For non-reservable spend, include actionable optimization guidance in the report:

| Non-reservable category | Guidance |
|------------------------|----------|
| Storage (gp2/gp3/PIOPS) | Consider gp3 migration, storage tiering, snapshot cleanup |
| Aurora Storage I/O | Consider Aurora I/O-Optimized, query tuning |
| Backup | Review retention policies |
| Extended Support surcharges | Upgrade to a supported engine version |
| Serverless v2 (ACU) | Tune ACU min/max — not RI-eligible |
| Data transfer | Review cross-AZ and cross-region flows |

## Output

Persist to `<run_dir>/spend-decomposition.json`. Structure:

```json
{
  "lookback_start": "YYYY-MM-DD",
  "lookback_end": "YYYY-MM-DD",
  "metric": "AmortizedCost",
  "services": [
    {
      "service": "Amazon Elastic Compute Cloud - Compute",
      "total_spend": 0.00,
      "on_demand_spend": 0.00,
      "monthly_avg_on_demand": 0.00,
      "by_purchase_type": {"On Demand": 0.00, "Reserved": 0.00, "Savings Plans": 0.00, "Spot": 0.00, "Dedicated": 0.00},
      "classification": "optimizable",
      "drilldown": null
    },
    {
      "service": "Amazon Relational Database Service",
      "total_spend": 0.00,
      "on_demand_spend": 0.00,
      "monthly_avg_on_demand": 0.00,
      "classification": "optimizable",
      "drilldown": {
        "coverable_on_demand": 0.00,
        "non_reservable_on_demand": 0.00,
        "usage_type_breakdown": []
      }
    }
  ],
  "totals": {
    "optimizable_on_demand": 0.00,
    "inherently_on_demand": 0.00,
    "monthly_avg_addressable": 0.00
  }
}
```

Sort services by on-demand spend descending. This ordering flows through to the report.
