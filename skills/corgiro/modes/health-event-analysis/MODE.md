---
name: health-event-analysis
description: "Analyze AWS Health Dashboard events across your AWS accounts. Uses the organizational Health API when accessMode is cross-account-role, or queries each account directly via per-account profiles when accessMode is identity-center-direct. Produces a structured report with pattern analysis and risk assessment. Use when the user mentions health events, service disruptions, scheduled maintenance, health dashboard, or AWS outage analysis."
user-invocable: true
---

# Health Event Analysis

Analyze AWS Health Dashboard events across your accounts — open issues, scheduled changes, and recent closures — then produce a structured summary with pattern analysis and risk assessment.

This mode adapts to the `accessMode` in `~/.corgiro/config.json`:

| accessMode               | How events are collected                                                                                                                     |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `cross-account-role`     | **Organizational Health API** (`*-for-organization`) from the management / delegated-admin account — one set of calls covers the whole org   |
| `identity-center-direct` | **Per-account Health API** (`describe-events`, etc.) — fan out across the roster using `corgiro-<accountId>` profiles, one account at a time |

> The AWS Health API requires a **Business, Enterprise On-Ramp, or Enterprise Support** plan. In org mode the management account must have it; in per-account mode each account must have it, or that account is skipped (`SubscriptionRequiredException`) and listed in the report.

All Health API calls use `us-east-1` (endpoint `health.us-east-1.amazonaws.com`).

## Prerequisites

Common:

- `~/.corgiro/config.json` exists (run `/corgiro setup-corgiro` if not) and a valid SSO session
- Read [`references/cross-account-defaults.md`](../../references/cross-account-defaults.md) and [`references/credential-resolution.md`](../../references/credential-resolution.md)

For `cross-account-role`:

- Caller is the management account or a Health delegated admin
- Trusted access enabled for `health.amazonaws.com`; management account on a supported Support plan

For `identity-center-direct`:

- A fresh roster / coverage snapshot (run `/corgiro account-coverage` if stale)
- Accounts without a supported Support plan are skipped and noted

## Parameters

Gather from the user before starting:

| Parameter           | Default                          | Description                                                         |
| ------------------- | -------------------------------- | ------------------------------------------------------------------- |
| `scope`             | `quick`                          | `quick` (open + upcoming, 7 days) or `full` (all statuses, 30 days) |
| `service_filter`    | _none_                           | AWS service code (e.g., `EC2`, `VPN`, `RDS`) or blank for all       |
| `time_range_days`   | `7`                              | Look-back window (7, 14, 30, 90)                                    |
| `critical_services` | `EC2,RDS,EKS,LAMBDA,S3,DYNAMODB` | Services treated as critical for risk scoring                       |
| `fetch_entities`    | `false`                          | Whether to fetch affected resources (slower)                        |
| `output_format`     | `both`                           | `markdown`, `html`, or `both`                                       |

## Workflow

Execute steps sequentially. Read the corresponding reference file before each step.

### Step 1: Prerequisite Check

Read [references/step-0-prerequisites.md](references/step-0-prerequisites.md).

Read `accessMode` from config, then validate the credentials/permissions for that mode. Fail fast with clear error messages.

### Step 2: Collect Input & Discover Accounts

Read [references/step-1-input.md](references/step-1-input.md).

Prompt for parameters, persist to `scope.json` (including `access_mode`). Build the account list: org list for `cross-account-role`, roster for `identity-center-direct`.

### Step 3: Fetch Health Events

Read [references/step-2-fetch-events.md](references/step-2-fetch-events.md).

Org mode: `describe-events-for-organization`. Per-account mode: fan out `describe-events` per account (tag each event with its source account; skip unsupported accounts). Handle pagination. Build the event index.

### Step 4: Fetch Details & Affected Accounts

Read [references/step-3-fetch-details.md](references/step-3-fetch-details.md).

Org mode: affected accounts + org event details. Per-account mode: the affected account is the queried account — fetch single-account event details and (optionally) affected entities.

### Step 5: Analyze & Report

Read [references/step-4-analyze-report.md](references/step-4-analyze-report.md) and the shared [`../../references/report-format.md`](../../references/report-format.md).

Aggregate findings, apply risk scoring, detect patterns, then render the report per the shared format (self-contained HTML + Markdown, Corgiro branding). Note any accounts skipped for lack of a supported Support plan.

## Output

```
./<run_id>/
├── scope.json
├── accounts.json
├── events/event_index.json
├── details/<event_key>_*.json
├── account_rollup.json
├── analysis.json
├── Health-Analysis-<DATE>.md
└── Health-Analysis-<DATE>.html
```

## Error Handling

| Symptom                                       | Action                                                                                                                                                               |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SubscriptionRequiredException`               | Account not on a supported Support plan. Org mode: management account ineligible — stop. Per-account mode: skip that account, record in `skipped_accounts`, continue |
| `AccessDeniedException` on `*ForOrganization` | Not management/delegated admin, or trusted access not enabled — only applies to `cross-account-role`                                                                 |
| Credential resolution fails for one account   | Per-account mode: skip, note in report, continue (see credential-resolution.md)                                                                                      |
| `ThrottlingException`                         | Reduce `maxParallel`, apply exponential backoff                                                                                                                      |
| >300 events                                   | Use the narrowing fallback in Step 5 — there is no org event-aggregate API                                                                                           |
