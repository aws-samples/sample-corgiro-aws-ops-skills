---
name: bedrock-model-lifecycle
description: "Identify Amazon Bedrock foundation models that are deprecated (LEGACY) or approaching legacy/extended-support within 2 months across all reachable accounts. Shows which accounts and inference profiles are still using at-risk models. Use when checking Bedrock model deprecation, model lifecycle, legacy model usage, or planning model migrations."
user-invocable: true
---

# Bedrock Model Lifecycle Analysis

Identify Amazon Bedrock foundation models that are deprecated or approaching deprecation across every reachable account in your organization. Produces a prioritized report showing which models are at risk, when key lifecycle dates hit, which accounts are still invoking them, and which inference profiles reference them.

## Prerequisites

- `~/.corgiro/config.json` exists (run `/corgiro setup-corgiro` if not) and a valid SSO session.
- A fresh coverage snapshot (run `/corgiro account-coverage` if stale).
- Read [`../../references/credential-resolution.md`](../../references/credential-resolution.md)
  and [`../../references/cross-account-defaults.md`](../../references/cross-account-defaults.md).

## Parameters

Gather from the user before starting:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `regions` | _(ask)_ | Bedrock regions to scan. Suggest: `us-east-1, us-west-2, eu-west-1, ap-northeast-1`. User must provide explicitly — no `auto` discovery. |
| `lookback_days` | `30` | CloudWatch metrics lookback window (7, 14, 30, 60, 90) |
| `horizon_days` | `60` | How far ahead to flag approaching lifecycle transitions (default: 2 months) |
| `account_filter` | _(from config)_ | Include/exclude lists |
| `max_parallel` | `4` | Concurrent accounts (clamped to 10 max) |
| `output_format` | `both` | `markdown`, `html`, or `both` |

## Workflow

### Step 1: Prerequisite Check

1. Confirm `~/.corgiro/config.json` exists; read `accessMode`.
2. Validate SSO session is fresh (per credential-resolution.md pre-flight checks).
3. Confirm coverage snapshot exists at `~/.corgiro/state/roster.json`.

### Step 2: Fetch Model Lifecycle Data

Query the Bedrock control plane for the canonical model lifecycle catalogue. This only needs to run once (not per-account) — the model list is the same globally.

```bash
aws bedrock list-foundation-models --region us-east-1 --output json
```

From the response, extract for each model:
- `modelId`
- `modelName`
- `providerName`
- `modelLifecycle.status` (ACTIVE / LEGACY)
- `modelLifecycle.legacyTime` — when the model enters legacy state
- `modelLifecycle.publicExtendedAccessTime` — when extended-support pricing begins
- `modelLifecycle.endOfLifeTime` — when the model is fully unavailable

Save to `model-catalogue.json`.

**Source:** [AWS CLI bedrock list-foundation-models](https://docs.aws.amazon.com/cli/latest/reference/bedrock/list-foundation-models.html)

### Step 3: Identify At-Risk Models

From `model-catalogue.json`, flag models matching any of these criteria:

| Risk | Criteria | Badge |
|------|----------|-------|
| 🔴 Critical | `status = LEGACY` AND `endOfLifeTime` is within `horizon_days` or already past | `badge--red` |
| 🟠 High | `status = LEGACY` AND `publicExtendedAccessTime` is within `horizon_days` or already past (extended-support pricing active/imminent) | `badge--orange` |
| 🟡 Medium | `status = ACTIVE` but `legacyTime` is within `horizon_days` (approaching legacy) | `badge--amber` |
| 🟢 Info | `status = LEGACY` but `endOfLifeTime` is far out (>60 days) — deprecated but not urgent | `badge--green` |

If no models match any risk tier, report "all clear" and stop.

Save the at-risk model list to `at-risk-models.json`.

### Step 4: Scan Usage Per Account

For each reachable account + each user-specified region (up to `max_parallel` concurrently):

1. Resolve credentials per [`../../references/credential-resolution.md`](../../references/credential-resolution.md) — dispatch on the account's `via`.

2. **Query CloudWatch for invocations of at-risk models:**

   For each at-risk `modelId`:
   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/Bedrock \
     --metric-name Invocations \
     --dimensions Name=ModelId,Value=<modelId> \
     --start-time <now - lookback_days> \
     --end-time <now> \
     --period 86400 \
     --statistics Sum \
     --region <region> \
     --output json
   ```

   Also query the dedicated legacy metric:
   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/Bedrock \
     --metric-name LegacyModelInvocations \
     --dimensions Name=ModelId,Value=<modelId> \
     --start-time <now - lookback_days> \
     --end-time <now> \
     --period 86400 \
     --statistics Sum \
     --region <region> \
     --output json
   ```

3. **List inference profiles referencing at-risk models:**

   ```bash
   aws bedrock list-inference-profiles --region <region> --output json
   ```

   For each returned profile, check if its `models[].modelArn` matches an at-risk model. Flag matching profiles.

4. **Check model invocation logging status** (informational):

   ```bash
   aws bedrock get-model-invocation-logging-configuration --region <region> --output json
   ```

   Record whether logging is enabled — note in the report that per-caller attribution is available from logs if enabled.

5. Save results to `per-account/<account_id>/<region>/bedrock-usage.json`.

Skip accounts that fail credential resolution; record them and continue.

**Sources:**
- [CloudWatch get-metric-statistics](https://docs.aws.amazon.com/cli/latest/reference/cloudwatch/get-metric-statistics.html)
- [Bedrock runtime CloudWatch metrics](https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring-runtime-metrics.html) — confirms `ModelId` dimension and `Invocations` / `LegacyModelInvocations` metrics
- [Bedrock list-inference-profiles](https://docs.aws.amazon.com/cli/latest/reference/bedrock/list-inference-profiles.html)
- [Bedrock get-model-invocation-logging-configuration](https://docs.aws.amazon.com/cli/latest/reference/bedrock/get-model-invocation-logging-configuration.html)

### Step 5: Aggregate and Analyze

Combine per-account results into `aggregated.json`:

For each at-risk model, produce:
- Total invocations across all accounts/regions in the lookback window
- List of accounts with non-zero usage (account ID, account name, region, invocation count, daily trend)
- List of inference profiles referencing this model (account, region, profile name, profile ARN)
- Days until next lifecycle transition

Sort by: risk tier (critical first), then invocation volume (highest first).

### Step 6: Generate Report

Render per the shared [`../../references/report-format.md`](../../references/report-format.md) — self-contained HTML + Markdown, Corgiro branding, KPI cards, tables, badges, footer.

**Report sections:**

1. **Executive Summary** — KPI cards: total at-risk models, total accounts affected, total invocations on deprecated models, models approaching legacy within 60 days
2. **Model Lifecycle Timeline** — table of all at-risk models with key dates:
   | Model | Provider | Status | Legacy Date | Extended Support Date | End of Life | Risk |
3. **Active Usage of At-Risk Models** — per model, which accounts are still calling it:
   | Account | Region | Invocations (last N days) | Daily Trend | Inference Profiles |
4. **Inference Profiles at Risk** — profiles referencing deprecated models:
   | Account | Region | Profile Name | Profile Type | Referenced Model | Model Risk |
5. **Accounts Without Logging** — accounts where model invocation logging is disabled (limits caller-level attribution):
   | Account | Region | Logging Status | Note |
6. **Migration Recommendations** — for each deprecated model, suggest the recommended successor (based on provider's active models of the same modality)
7. **Methodology** — APIs used, scope (accounts, regions, lookback), what was not covered (per-caller attribution requires log analysis)

Write `Bedrock-Model-Lifecycle-<DATE>.md` and/or `.html` per `output_format`.

## Safety

- Read-only: only describe/list/get calls (`list-foundation-models`, `get-metric-statistics`, `list-inference-profiles`, `get-model-invocation-logging-configuration`).
- Never print access keys, session tokens, or the external ID.
- No mutating actions in this mode.

## Output

```
./bedrock-model-lifecycle-<run_id>/
├── scope.json
├── model-catalogue.json
├── at-risk-models.json
├── per-account/<account_id>/<region>/bedrock-usage.json
├── aggregated.json
├── Bedrock-Model-Lifecycle-<DATE>.md
└── Bedrock-Model-Lifecycle-<DATE>.html
```

## Error Handling

| Symptom | Action |
|---------|--------|
| Credential resolution fails for one account | Skip, note in report, continue (see credential-resolution.md) |
| `ThrottlingException` on CloudWatch | Reduce `max_parallel`, exponential backoff (base 1s, cap 30s) |
| `AccessDeniedException` on `list-foundation-models` | Bedrock not enabled in account/region — skip region for that account |
| `AccessDeniedException` on `list-inference-profiles` | Insufficient permissions — skip, note in report |
| No at-risk models found | Report "all clear" — all models are ACTIVE with no imminent lifecycle transitions. Stop after Step 3. |
| CloudWatch returns empty metrics for a model | Account has no usage of that model in the lookback window — record zero, do not flag as error |
| Bedrock not available in a specified region | Skip that region, note in report |
