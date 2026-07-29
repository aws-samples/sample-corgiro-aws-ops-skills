# Step 5: Expiring Commitments

Identify Savings Plans and Reserved Instances that will expire within the next 90 days so the operator can plan renewals before coverage drops.

All calls run against the payer account in `us-east-1`. Resolve credentials per [`../../../references/credential-resolution.md`](../../../references/credential-resolution.md).

## Savings Plans expiry

```bash
aws savingsplans describe-savings-plans \
  --region us-east-1 \
  --states active \
  --output json > active-savings-plans.json
```

Note: `savingsplans` is a **global** service (like IAM); the region flag is required by the CLI but the API is globally scoped.

For each returned plan, extract:

- `savingsPlanId`
- `savingsPlanType` (Compute / EC2 Instance / SageMaker / Database)
- `commitment` (hourly, as a string — parse to float)
- `start` (ISO 8601)
- `end` (ISO 8601)
- `paymentOption`

Compute days remaining = `(end - now)`.

If `describe-savings-plans` returns `AccessDenied`, skip SP expiry analysis and note in the report. Do not fail the whole run.

## Reserved Instance expiry

**Do not re-query the RI list.** Step 3 (utilization) already fetched every active RI with its `EndDateTime` via `get-reservation-utilization`. Reuse the `ri_utilization` array from `utilization.json`.

For each RI, compute days remaining = `(end_date - now)`.

## Bucketing

Assign each commitment to a bucket based on days remaining:

| Bucket | Days remaining | Badge | Meaning |
|--------|----------------|-------|---------|
| Immediate | 0 - 30 | `badge--red` (Critical) | Renewal is urgent — coverage will drop within a month. |
| Plan | 31 - 60 | `badge--amber` (Medium) | Enough time to plan a renewal; start now. |
| Awareness | 61 - 90 | `badge--blue` (Low) | On the horizon; note it for the next review cycle. |
| Beyond 90 | 91+ | _(not reported here)_ | No action needed yet. |

Anything past its end date (`days_remaining < 0`) should not appear in this list — those are already-expired commitments and would have shown up in step 3 with 0% utilization (or not at all if AWS has retired the record). If any surface, treat them as Immediate and flag as "already expired".

## Recommended action per commitment

For each expiring commitment, pair the expiry with the utilization signal from step 3 to produce a specific recommendation:

| Utilization at expiry | Recommended action in the report |
|-----------------------|----------------------------------|
| ≥ 90% | Renew: usage justifies the commitment. |
| 80 - 89% | Renew but consider a smaller commitment sized to actual usage. |
| < 80% | Do not renew as-is. Investigate whether the workload has shrunk or moved before committing again. |
| No utilization data (e.g. SP describe failed) | Renew based on operator judgement; utilization signal unavailable. |

Never renew automatically — this mode is read-only and every action is a recommendation for the operator to execute manually.

## Output

Persist to `<run_dir>/expiring.json`:

```json
{
  "sp_expiring": [
    {
      "savings_plan_id": "...",
      "type": "...",
      "commitment_hourly": 0.00,
      "payment_option": "...",
      "start_date": "...",
      "end_date": "...",
      "days_remaining": 0,
      "bucket": "immediate",
      "utilization_pct": 0.00,
      "recommended_action": "..."
    }
  ],
  "ri_expiring": [
    {
      "subscription_id": "...",
      "service": "...",
      "end_date": "...",
      "days_remaining": 0,
      "bucket": "plan",
      "utilization_pct": 0.00,
      "recommended_action": "..."
    }
  ],
  "counts_by_bucket": {
    "immediate": 0,
    "plan": 0,
    "awareness": 0
  },
  "sp_describe_available": true
}
```

If `describe-savings-plans` was unavailable, set `sp_describe_available: false` and leave `sp_expiring` empty.

## What to report

The report's "Expiring Commitments Action Plan" section presents one row per expiring commitment, sorted by days remaining ascending. Columns: Type, ID, Service, Region, Commitment, Expiry Date, Days Remaining, Current Utilization, Recommended Action.

If no commitments expire in the 90-day window, emit a single line: "No commitments expiring in the next 90 days" (a positive finding, not an error).

The Executive Summary card at the top of the report should show the count in each bucket (Immediate / Plan / Awareness) so the operator sees the shape at a glance.
