# Step 1: Prerequisite Check and Scope

## Pre-flight

Run the pre-flight security checks in [`../../../references/credential-resolution.md`](../../../references/credential-resolution.md) (file permissions on `~/.corgiro/`, operator session freshness, and the authoritative `sts get-caller-identity` probe). Confirm the coverage snapshot is fresh and `~/.corgiro/config.json` exists. Fail fast with a clear message and the one-line fix if any check fails.

Read `accessMode` and `authMethod` from config so downstream steps know how each account is reached. Credential dispatch itself stays in `credential-resolution.md` — do not restate it here.

## Determine the account set

Read `~/.corgiro/state/roster.json`, then resolve the review set based on `accounts`:

- **Org-wide (default)** — `accounts` omitted or `all`: review every roster entry with `reachable: true` (or, if the snapshot lacks the field, every entry — reachability is re-checked implicitly on the first call).
- **Specific accounts** — `accounts` is a list of IDs: review exactly those. For each requested ID, confirm it exists in the roster; if not, skip it and record `not_in_roster` in `scope.json`. Corgiro can only reach accounts set up via `setup-corgiro` / refreshed by `account-coverage`.

Apply `account_filter` (config include/exclude) on top of either set. The management account is reviewed with local credentials (reachability category `management` in [`credential-resolution.md`](../../../references/credential-resolution.md#reachability-categories-shared-vocabulary)); all other accounts dispatch on their `via` field.

## Determine regions

Scope is a list of `{account_id, region}` pairs, not one org-wide region union.

If `regions = auto`, use Cost Explorer to discover account/region pairs with any spend in the last 30 days. Cost Explorer is a payer/org-level API, not a per-account call:

- **`cross-account-role`:** query CE from the tooling/management session (delegated admin / payer access) — use local credentials, no per-account profile.
- **`identity-center-direct`:** use a profile that has payer-level CE access (shown below as `<profilePrefix><payerAccountId>`); if none is available, skip `auto` and fall back to the shared `fallbackRegions` set.

```bash
aws ce get-cost-and-usage \
  --time-period Start=<30-days-ago>,End=<today> \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=LINKED_ACCOUNT Type=DIMENSION,Key=REGION \
  --region us-east-1 --output json
  # cross-account-role: run with the tooling/management session (local creds)
  # identity-center-direct: add --profile <profilePrefix><payerAccountId>
```

Keep pairs with cost > 0; drop the `NoRegion`/`global` pseudo-region. An in-scope account with no spend in any region (new account, billing lag) is paired with the shared `fallbackRegions` set instead of being left with no regions — otherwise its regional domains would never be checked.

> **Payer-level caveat:** Under `identity-center-direct`, the operator may not have payer-level CE access. If CE returns `AccessDeniedException`, fall back to the shared `fallbackRegions` set (see [`../../../references/cross-account-defaults.md`](../../../references/cross-account-defaults.md)) for every in-scope account, and note the fallback in `scope.json`.

If `regions` is explicit, pair every in-scope account with exactly those regions.

### Unused regions

Spend-based discovery skips regions an account does not use — yet GuardDuty or CloudTrail being off in an unused region is itself a security gap. When `include_unused_regions = true`, additionally list each account's enabled regions:

```bash
aws ec2 describe-regions --output json        # returns only regions enabled for the account
```

and run only the GuardDuty, AWS Config, and CloudTrail-coverage checks in those extra regions (tag them `unused` in `scope.json`). When `false` (default), the Methodology section must state that regions without spend were not checked.

Global services (IAM account summary, credential report, password policy, S3 `list-buckets`) are collected once per account regardless of the region list; IAM global calls use `us-east-1`. CloudTrail `describe-trails` is region-scoped and runs in every region in scope (see Step 2).

## Resolve the IAM Access Analyzer delegated admin

An `ORGANIZATION` analyzer exists only in the management or delegated-admin account, but it covers every member account. Look it up once, before fan-out, from the management account:

```bash
aws organizations list-delegated-administrators \
  --service-principal access-analyzer.amazonaws.com --output json
```

Use the returned account (or the management account if none is delegated). Under `identity-center-direct` without management access, skip the lookup and note that org-level analyzers could not be detected. Record `accessAnalyzerAdmin` in `scope.json`; Step 2 lists its `ORGANIZATION` analyzers per region.

## Detect centralized root access

From the management account, check whether member-account root credentials are centrally managed:

```bash
aws iam list-organizations-features --output json    # EnabledFeatures contains "RootCredentialsManagement"
```

Record `rootCredentialsManaged: true|false|unknown` in `scope.json`. The value is **informational only** — it is shown in the report's Identity and Access section and never affects a flag or score. `ROOT_NO_MFA` is decided from each account's credential report (Step 3), which already avoids false positives under centralized root access. The call works only from the management account (or an IAM delegated administrator): under `cross-account-role` the base session is the tooling account, so expect `unknown`; under `identity-center-direct` it resolves only if the operator has a management-account assignment. Record `unknown` on any denial and continue.

## Persist

Write `scope.json` with: `run_id`, `access_mode`, the resolved `{account_id, region}` pairs (and whether regions came from `auto`, were explicit, or fell back to `fallbackRegions`; plus any `unused` regions), `accessAnalyzerAdmin`, `rootCredentialsManaged`, `account_filter` applied, all parameter values, and any `skipped`/`not_in_roster` IDs.
