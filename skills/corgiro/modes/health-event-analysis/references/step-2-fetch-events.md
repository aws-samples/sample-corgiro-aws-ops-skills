# Step 2: Fetch Health Events

All Health API calls use `us-east-1`. The collection method depends on `access_mode` in `scope.json`.

## Path B — Organizational (`cross-account-role`)

Pull event summaries with `describe-events-for-organization`. The org filter takes a single `startTime` range object.

```bash
aws health describe-events-for-organization \
  --region us-east-1 \
  --filter '{
    "eventStatusCodes": ["open", "upcoming"],
    "startTime": {"from": "<start_time_iso>", "to": "<end_time_iso>"}
  }' \
  --max-results 100 \
  --output json > events/events_page_001.json
```

For `full` scope add `"closed"` to `eventStatusCodes`; add `"services": ["<service_filter>"]` when filtering. Summaries do not include affected accounts or descriptions (fetched in Step 3).

## Path A — Per-account (`identity-center-direct`)

For each account in `~/.corgiro/state/roster.json`, resolve credentials per [credential-resolution.md](../../../references/credential-resolution.md) (`via: sso` → `--profile corgiro-<accountId>`) and call the single-account `describe-events`. Note the per-account filter uses `startTimes` — a **list** of range objects (not the org `startTime`).

```bash
aws health describe-events \
  --region us-east-1 \
  --profile corgiro-<accountId> \
  --filter '{
    "eventStatusCodes": ["open", "upcoming"],
    "startTimes": [{"from": "<start_time_iso>", "to": "<end_time_iso>"}]
  }' \
  --max-results 100 \
  --output json > events/<accountId>_page_001.json
```

- **Tag every returned event with its source `accountId`** — this replaces the org affected-accounts lookup.
- `SubscriptionRequiredException` → account lacks Business/ENT support. Add to `skipped_accounts`, continue.
- Run up to `maxParallel` (4) accounts concurrently; back off on `ThrottlingException`.

## Pagination

Max `--max-results` is 100. If a response contains `nextToken`, call again with `--starting-token`. Save each page (`events_page_NNN.json` for org; `<accountId>_page_NNN.json` per account).

## Gate check

If total events > 300, use Step 5's large-fleet fallback (narrow scope and re-run; per-account mode can use `describe-event-aggregates` for quick per-account counts).

## Build event_index.json

Flatten all pages into a single array. Keep per event: `arn`, `service`, `eventTypeCode`, `eventTypeCategory`, `eventScopeCode`, `statusCode`, `region`, `startTime`, `endTime`, `lastUpdatedTime`, and — in per-account mode — `accountId`.

> PUBLIC-scope events appear in every account in per-account mode. Dedupe by `arn` for global counts, but keep the per-account associations for the account rollup.

Compute counts: `by_status`, `by_service`, `by_category`, `by_region`, `top_event_types`.
