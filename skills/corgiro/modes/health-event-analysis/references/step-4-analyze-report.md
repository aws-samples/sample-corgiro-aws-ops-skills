# Step 4: Analyze & Report

## Build account_rollup.json

Inverted index keyed by account ID. Map IDs to names from `accounts.json` (org mode) or `roster.json` (per-account mode).

```json
{
  "111111111111": {
    "account_name": "prod-network",
    "event_count": 3,
    "events": [
      {
        "arn": "...",
        "service": "VPN",
        "eventTypeCode": "...",
        "statusCode": "open",
        "startTime": "..."
      }
    ],
    "risk_summary": { "critical": 0, "high": 1, "medium": 2, "low": 0 }
  }
}
```

In per-account mode, each event is already tagged with its source `accountId` from Step 2, so the rollup is built directly from the event index.

## Pattern Analysis

- **Recurring issues**: services with 3+ events of same `eventTypeCode`
- **Multi-account impact**: events affecting 5+ accounts (per-account mode: dedupe by `arn` and count distinct source accounts)
- **Long-running issues**: `open` events with `startTime` older than 7 days
- **Upcoming maintenance**: `upcoming` events in next 14 days

## Risk Tiers

| Risk     | Criteria                                                                       |
| -------- | ------------------------------------------------------------------------------ |
| Critical | Open events on `critical_services`, or `issue` category affecting 10+ accounts |
| High     | Open events affecting 5+ accounts, or connectivity events (VPN, DX, TGW)       |
| Medium   | Upcoming changes within 7 days, or open events affecting 1-4 accounts          |
| Low      | Account notifications, certificate renewals, closed events                     |

## Report Structure (Markdown)

1. **Executive Summary** — counts, risk tiers, scope, coverage. In per-account mode, list accounts skipped for lack of a supported Support plan (`skipped_accounts`).
2. **Open Issues** — sorted by risk, with description, affected accounts, days open, actions
3. **Upcoming Scheduled Changes** — sorted by date
4. **Recently Closed** — summary table
5. **Per-Account Impact** — from `account_rollup.json`, sorted by risk
6. **Pattern Analysis** — recurring, multi-account, trends
7. **Action Items** — grouped by timeframe (immediate, this week, ongoing)

## HTML Report

Render per the shared [`../../../references/report-format.md`](../../../references/report-format.md): self-contained single file, inlined theme, Corgiro branding, KPI summary cards, tables, badges, `<details>` expanders, and footer. Map this mode's data to the shared vocabulary:

- Risk tiers → KPI accents + badges: Critical `badge--red`, High `badge--orange`, Medium `badge--amber`, Low `badge--blue`.
- Event status → badges: open `badge--red`, upcoming `badge--amber`, closed `badge--zinc`.
- Same sections / order as the Markdown above; long descriptions go in `<details>`.

After writing, open it: `open ./<run_id>/Health-Analysis-<DATE>.html`

## Large-Fleet Fallback (>300 events)

There is no organizational event-aggregate API, so reduce volume instead:

- Narrow the filter — shorter `time_range_days`, a specific `service_filter`, or `eventStatusCodes: ["open"]` only — and re-run Step 3.
- Compute counts client-side from the summaries already pulled (`by_service`, `by_category`).
- Per-account mode only: `aws health describe-event-aggregates --region us-east-1 --profile corgiro-<accountId> --aggregate-field eventTypeCategory` gives quick counts for a single account.
