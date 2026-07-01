# Step 1: Collect User Input

Prompt for parameters with defaults. Record in `scope.json` (include `access_mode` read from `~/.corgiro/config.json`):

```json
{
  "run_id": "health-event-analysis-20260504-091500",
  "access_mode": "cross-account-role",
  "management_account_id": "123456789012",
  "caller_account_id": "123456789012",
  "scope": "quick",
  "service_filter": null,
  "time_range_days": 7,
  "critical_services": ["EC2", "RDS", "EKS", "LAMBDA", "S3", "DYNAMODB"],
  "fetch_entities": false,
  "output_format": "both",
  "start_time_iso": "2026-04-27T00:00:00Z",
  "end_time_iso": "2026-05-04T00:00:00Z",
  "analysis_date": "2026-05-04",
  "active_region": "us-east-1"
}
```

## Scope Defaults

| scope | eventStatusCodes             | time_range_days |
| ----- | ---------------------------- | --------------- |
| quick | `open`, `upcoming`           | 7               |
| full  | `open`, `upcoming`, `closed` | 30              |

## Build the account list

- **cross-account-role** → pull the org roster for ID-to-name mapping:
  ```bash
  aws organizations list-accounts --output json > accounts.json
  ```
- **identity-center-direct** → use `~/.corgiro/state/roster.json` (written by `setup-corgiro` / refreshed by `account-coverage`). These are the accounts that will be queried one-by-one in Step 3. Names come from the roster entries.
