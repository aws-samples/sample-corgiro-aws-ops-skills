# Step 1: Prerequisite Check and Scope

## Pre-flight

Run the pre-flight security checks in [`../../../references/credential-resolution.md`](../../../references/credential-resolution.md) (file permissions on `~/.corgiro/`, operator session freshness, and the authoritative `sts get-caller-identity` probe). Confirm the coverage snapshot is fresh and `~/.corgiro/config.json` exists. Fail fast with a clear message and the one-line fix if any check fails.

Read `accessMode` from config so downstream steps know how each account is reached. Credential dispatch itself stays in `credential-resolution.md` - do not restate it here.

## Determine the account set

Read `~/.corgiro/state/roster.json`, then resolve the review set based on `accounts`:

- **Org-wide (default)** - `accounts` omitted or `all`: review every roster entry with `reachable: true` (or, if the snapshot lacks the field, every entry - reachability is re-checked implicitly on the first call).
- **Specific accounts** - `accounts` is a list of IDs: review exactly those. For each requested ID, confirm it exists in the roster; if not, skip it and record `not_in_roster` in `scope.json`. Corgiro can only reach accounts set up via `setup-corgiro` / refreshed by `account-coverage`.

Apply `account_filter` (config include/exclude) on top of either set. The management account (`via: management`) is reviewed with local credentials; all other accounts dispatch on their `via` field.

## Determine regions

- `regions = auto`: discover active regions where the account has recent spend/usage. From the payer/management account:
  ```bash
  aws ce get-cost-and-usage \
    --time-period Start=<30-days-ago>,End=<today> \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=REGION \
    --output json
  ```
  Keep regions with cost > 0; drop the `NoRegion`/`global` pseudo-region. Under `identity-center-direct` the operator often cannot query org-wide Cost Explorer - on `AccessDenied`, fall back to a sensible default set (e.g. `us-east-1`, plus any regions the operator passes) and note the fallback in `scope.json`.
- `regions` explicit: use exactly those.

Global services (IAM account summary, credential report, password policy, S3 `list-buckets`) are collected once per account regardless of the region list; IAM global calls use `us-east-1`.

## Persist

Write `scope.json` with: `run_id`, `access_mode`, the resolved account list, the region list (and whether it came from `auto` or was explicit, plus any CE fallback), `account_filter` applied, `severity_floor`, `max_parallel`, `output_format`, and any `skipped`/`not_in_roster` IDs.
