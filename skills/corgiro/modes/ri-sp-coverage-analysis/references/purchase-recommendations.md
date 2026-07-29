# Step 4: Purchase Recommendations

Pull recommendations from two sources — Cost Explorer's native SP recommender and Cost Optimization Hub — and cross-reference them. Both are payer-scoped; run against the payer account in `us-east-1`. Resolve credentials per [`../../../references/credential-resolution.md`](../../../references/credential-resolution.md).

## 4a. Cost Explorer SP purchase recommendations

Call once per SP type in the operator's `sp_types` parameter (see the mapping below). Fire in parallel.

```bash
aws ce get-savings-plans-purchase-recommendation \
  --region us-east-1 \
  --savings-plans-type <SP_TYPE> \
  --term-in-years <term> \
  --payment-option <payment> \
  --lookback-period-in-days SIXTY_DAYS \
  --account-scope PAYER \
  --output json > sp-recommendation-<sp_type_slug>.json
```

`--account-scope PAYER` produces one recommendation for the whole payer family. `--account-scope LINKED` would produce per-account recommendations — this mode uses `PAYER` because consolidated billing already pools usage across the org.

SP type mapping (`sp_types` parameter → API value):

| `sp_types` value | `--savings-plans-type` | Covers |
|------------------|------------------------|--------|
| `compute` | `COMPUTE_SP` | EC2, Fargate, Lambda — most flexible |
| `ec2-instance` | `EC2_INSTANCE_SP` | EC2 only, locked to instance family + region — deeper discount |
| `sagemaker` | `SAGEMAKER_SP` | SageMaker training and inference |
| `database` | `DATABASE_SP` | Aurora, RDS, DynamoDB, ElastiCache, DocumentDB, Neptune, Keyspaces, Timestream, DMS, OpenSearch |

If `sp_types = all`, call for each type that has meaningful on-demand spend in step 1:

- Always call `COMPUTE_SP` (covers EC2, Fargate, Lambda).
- Call `DATABASE_SP` if any Database-SP-eligible service has on-demand spend. Eligible services are listed above. **Do NOT include** Redshift, MSK, MemoryDB, or Managed Apache Flink in the Database SP addressable spend calculation — they are not covered by Database SPs (Redshift has its own RI program).
- Call `SAGEMAKER_SP` if SageMaker has on-demand spend.
- Call `EC2_INSTANCE_SP` only if the operator has confirmed a very stable EC2 workload — Instance SPs deliver a deeper discount but lock to an instance family and region.

Each response contains `SavingsPlansPurchaseRecommendation.SavingsPlansPurchaseRecommendationDetails[]` — usually a single entry for `--account-scope PAYER`. Extract:

- `HourlyCommitmentToPurchase`
- `EstimatedMonthlySavingsAmount`
- `EstimatedSavingsPercentage`
- `EstimatedROI`
- `EstimatedOnDemandCost` — what would have been spent on-demand
- `EstimatedSavingsPlansCost` — the commitment portion

Derived field for the report: `Est. Monthly OD After Purchase = <monthly_avg_on_demand_from_step_1> − <EstimatedMonthlySavingsAmount>`. Use step 1's **coverable** on-demand bucket (after the USAGE_TYPE drill-down), not the raw on-demand number.

## 4b. Cost Optimization Hub cross-reference

COH aggregates recommendations across multiple optimization types (rightsizing, idle, Graviton, commitments, etc.). This step pulls only the commitment-related recommendations.

Skip 4b gracefully if COH is not enabled or returns `AccessDenied`.

```bash
aws cost-optimization-hub list-recommendation-summaries \
  --region us-east-1 \
  --group-by RecommendationType \
  --output json > coh-summary.json
```

Filter the response to types containing `SavingsPlan` or `ReservedInstance` (exact type names vary; the current set includes `ComputeSavingsPlans`, `SageMakerSavingsPlans`, `EC2ReservedInstances`, `RdsReservedInstances`, `ElastiCacheReservedInstances`, `OpenSearchReservedInstances`, `RedshiftReservedInstances`, `MemoryDbReservedInstances`).

For a deeper view of individual recommendations (up to 20 highest-savings):

```bash
aws cost-optimization-hub list-recommendations \
  --region us-east-1 \
  --filter '{"recommendationTypes":["ComputeSavingsPlans","SageMakerSavingsPlans","EC2ReservedInstances","RdsReservedInstances","ElastiCacheReservedInstances","OpenSearchReservedInstances","RedshiftReservedInstances","MemoryDbReservedInstances"]}' \
  --max-results 20 \
  --order-by '{"dimension":"EstimatedMonthlySavings","order":"Desc"}' \
  --output json > coh-recommendations.json
```

## Cross-reference logic

If both CE and COH provide a recommendation for the same commitment type, present both and note agreement or divergence.

- **They agree (within 10%)**: high confidence — recommend acting.
- **They diverge**: this is common and worth calling out. COH factors in **negotiated discounts** (Enterprise Discount Programs, private pricing) that the operator's payer may have; CE does not. If they diverge in COH's favor, add: "COH figure may reflect negotiated-discount-adjusted pricing." If they diverge in CE's favor, note it and let the operator decide.
- **Only one source has a recommendation**: present it and mention the other source did not.

## Output

Persist to `<run_dir>/recommendations.json`:

```json
{
  "ce_recommendations": [
    {
      "source": "CE",
      "sp_type": "COMPUTE_SP",
      "term": "ONE_YEAR",
      "payment": "NO_UPFRONT",
      "hourly_commitment": 0.00,
      "est_monthly_savings": 0.00,
      "est_savings_pct": 0.00,
      "est_roi": 0.00,
      "est_monthly_od_after_purchase": 0.00
    }
  ],
  "coh_summaries": [
    {"recommendation_type": "ComputeSavingsPlans", "recommendation_count": 0, "estimated_monthly_savings": 0.00}
  ],
  "coh_top_recommendations": [
    {"source": "COH", "recommendation_type": "...", "resource_id": "...", "estimated_monthly_savings": 0.00, "currency_code": "USD"}
  ],
  "cross_reference": [
    {"sp_type": "COMPUTE_SP", "ce_savings": 0.00, "coh_savings": 0.00, "delta_pct": 0.00, "note": "..."}
  ],
  "coh_available": true
}
```

If COH is unavailable, set `coh_available: false` and leave the COH arrays empty.

## What to report

The report's "Purchase Recommendations" section presents one row per recommendation. Columns: Source, Type, Hourly Commitment, Term, Payment, Est. Monthly Savings, Est. Savings %, Est. Monthly OD After Purchase, ROI.

If no recommendations returned for any SP type, do not treat as an error — the customer may already be well-covered or have insufficient spend history. Note in the report: "AWS does not recommend additional commitments at this time based on current usage patterns."

For `DATABASE_SP` specifically, the recommendation engine is newer and may return empty even when spend is present. Do not fabricate a manual estimate — note "Database SP recommendations not yet available for this payer" and move on.
