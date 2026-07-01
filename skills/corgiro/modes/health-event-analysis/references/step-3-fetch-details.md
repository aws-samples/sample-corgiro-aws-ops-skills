# Step 3: Fetch Details & Affected Accounts

Method depends on `access_mode`. All calls use `us-east-1`.

## Event key format

```bash
event_key=$(printf '%s' "$event_arn" | shasum -a 1 | awk '{print $1}' | cut -c1-16)
```

## Path B — Organizational (`cross-account-role`)

### Affected Accounts
For each event ARN:

```bash
aws health describe-affected-accounts-for-organization \
  --region us-east-1 \
  --event-arn "<event_arn>" \
  --output json > details/<event_key>_affected_accounts.json
```

Events with `eventScopeCode = PUBLIC` return empty account lists (expected). Run concurrently up to `maxParallel = 4`; back off on `ThrottlingException`.

### Event Details (Descriptions)
Batch up to 10 event ARNs per call. Each entry needs an event ARN + one affected account ID (the first affected account, or the management account for PUBLIC events):

```bash
aws health describe-event-details-for-organization \
  --region us-east-1 \
  --organization-event-detail-filters '[
    {"eventArn": "arn:...event1", "awsAccountId": "111111111111"},
    {"eventArn": "arn:...event2", "awsAccountId": "222222222222"}
  ]' \
  --output json > details/batch_001_details.json
```

### Affected Entities (optional, fetch_entities = true)

```bash
aws health describe-affected-entities-for-organization \
  --region us-east-1 \
  --organization-entity-filters '[{"eventArn": "arn:...event1", "awsAccountId": "111111111111"}]' \
  --output json > details/<event_key>_affected_entities.json
```

## Path A — Per-account (`identity-center-direct`)

The affected account is the account you queried in Step 2 — there is no affected-accounts lookup. Use the single-account operations with that account's profile.

### Event Details
Batch up to 10 ARNs from the same account:

```bash
aws health describe-event-details \
  --region us-east-1 \
  --profile corgiro-<accountId> \
  --event-arns "arn:...event1" "arn:...event2" \
  --output json > details/<accountId>_batch_001_details.json
```

### Affected Entities (optional, fetch_entities = true)

```bash
aws health describe-affected-entities \
  --region us-east-1 \
  --profile corgiro-<accountId> \
  --filter '{"eventArns": ["arn:...event1"]}' \
  --output json > details/<event_key>_<accountId>_affected_entities.json
```

## Both paths

Split responses by `eventArn` → `details/<event_key>_details.json`. Check `failedSet` for retries.
