# Step 3: Utilization Check (Waste Detection)

Before recommending new purchases, verify existing commitments are being used. Flag underused SPs and RIs as waste — buying more when current commitments are underused makes the problem worse.

All calls run against the payer account in `us-east-1`. Resolve credentials per [`../../../references/credential-resolution.md`](../../../references/credential-resolution.md).

Fire the two groups in parallel; they are independent.

## 3a. Savings Plans utilization

```bash
aws ce get-savings-plans-utilization \
  --region us-east-1 \
  --time-period Start=<30d_ago_iso>,End=<today_iso> \
  --granularity DAILY \
  --output json > sp-utilization.json
```

Extract from `Total`:

- `UtilizationPercentage` — headline number
- `TotalCommitment` — hourly commitment × 24 × days in window
- `UsedCommitment` — what was covered
- `UnusedCommitment` — dollar amount of waste in the window

**Flag if `UtilizationPercentage < 90%`.** SPs are commitment-based, so anything under 90% is money spent that would have been cheaper as on-demand.

## 3b. Reserved Instance utilization (per RI-eligible service)

API mechanics to be aware of:

- `get-reservation-utilization` **does not allow `--granularity` and `--group-by` together.** When `GroupBy` is set, omit `Granularity` entirely.
- Like `get-reservation-coverage`, this API **defaults to EC2** without a SERVICE filter. Every non-EC2 service needs an explicit filter.

Run one call per RI-eligible service (matching step 2's SERVICE filter values). Fire in parallel:

```bash
aws ce get-reservation-utilization \
  --region us-east-1 \
  --time-period Start=<30d_ago_iso>,End=<today_iso> \
  --group-by '[{"Type":"DIMENSION","Key":"SUBSCRIPTION_ID"}]' \
  --filter '{
    "Dimensions": {
      "Key": "SERVICE",
      "Values": ["<service_filter_value>"]
    }
  }' \
  --output json > ri-utilization-<service_slug>.json
```

SERVICE filter values are identical to step 2's table. For EC2, omit the filter.

Each `Group` in the response is one RI. Extract per RI:

- `Key` — the RI's subscription ID
- `Attributes` — includes `EndDateTime` (**reuse this in step 5** — do not re-query)
- `Utilization.UtilizationPercentage`
- `Utilization.PurchasedHours`
- `Utilization.TotalActualHours`
- `Utilization.UnusedHours`
- `Utilization.NetRISavings` — savings the RI produced in the window
- `Utilization.OnDemandCostOfRIHoursUsed` — what those hours would have cost on-demand

**Flag if `UtilizationPercentage < 80%`.** The 80% threshold is deliberately lower than the SP threshold because RIs have less flexibility (locked to a specific instance family and often region), so a small utilization dip is more forgivable.

Waste amount per underused RI = `UnusedHours × RIHourlyRate`. The hourly rate is not returned by the utilization API — approximate it from the RI's amortized cost in step 1's data, or use `RIHours × (OnDemandCostOfRIHoursUsed / TotalActualHours)` as a proxy.

## Output

Persist to `<run_dir>/utilization.json`. Structure:

```json
{
  "sp_utilization": {
    "utilization_pct": 0.00,
    "total_commitment": 0.00,
    "used_commitment": 0.00,
    "unused_commitment": 0.00,
    "flagged": false
  },
  "ri_utilization": [
    {
      "subscription_id": "...",
      "service": "...",
      "end_date": "...",
      "utilization_pct": 0.00,
      "purchased_hours": 0,
      "total_actual_hours": 0,
      "unused_hours": 0,
      "net_ri_savings": 0.00,
      "estimated_monthly_waste": 0.00,
      "flagged": false
    }
  ],
  "totals": {
    "sp_waste_30d": 0.00,
    "ri_waste_30d": 0.00,
    "total_waste_30d": 0.00
  }
}
```

The `ri_utilization` array feeds step 5's expiry analysis directly — do not re-query the RI list there.

## What to report

In the report's "Existing Commitments" section, present:

- Overall SP utilization (single KPI card).
- Overall RI utilization (single KPI card, weighted average across services).
- A table of underused commitments (SP if flagged; each flagged RI) with columns: Type, ID, Service, Utilization %, Est. Monthly Waste, End Date.

Flagged items get a badge — see `../../../references/report-format.md` for the vocabulary. Utilization < 80% is High (`badge--orange`), 80–89% is Medium (`badge--amber`), 90%+ is OK (`badge--green`).
