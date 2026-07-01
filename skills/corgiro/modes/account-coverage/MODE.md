---
name: account-coverage
description: "Determine which accounts are in scope and probe each one to confirm Corgiro can reach it. Adapts to the configured access mode: verifies SSO profiles (identity-center-direct) or assumes CorgiroReadOnlyRole (cross-account-role). Produces a coverage report showing which accounts are reachable and which need remediation. Use when checking account coverage, verifying cross-account access, onboarding new accounts, or before running multi-account operations."
user-invocable: true
---

# Account Roster & Coverage

Determines which accounts are in scope, probes each to confirm Corgiro can reach it, and produces a coverage report. Behavior adapts to the `accessMode` recorded in `~/.corgiro/config.json`.

## Why this matters

Downstream modes (RDS EOL, health events) rely on the coverage map and `state/roster.json`. Accounts that became unreachable — or new accounts — get flagged so nothing runs blind.

## Prerequisites

- Valid SSO session: `aws sso login --sso-session corgiro`
- `~/.corgiro/config.json` exists (run `/corgiro setup-corgiro` if not)
- For `cross-account-role`: caller is in the tooling account

## Parameters

| Parameter        | Default         | Description                                 |
| ---------------- | --------------- | ------------------------------------------- |
| `max_parallel`   | `4`             | Concurrent probes                           |
| `account_filter` | _(from config)_ | Include/exclude lists                       |
| `refresh`        | `false`         | Force fresh pull regardless of snapshot age |
| `output_format`  | `both`          | `markdown`, `html`, or `both`               |

## Workflow

### Step 0: Prerequisite Check & Read Access Mode

- `aws sts get-caller-identity` succeeds
- Read `~/.corgiro/config.json` → `accessMode`
- For `cross-account-role`: confirm the caller account matches `crossAccount.toolingAccountId`

### Step 1: Build the Candidate Account List

- **identity-center-direct** → read the accounts already in `~/.corgiro/state/roster.json` (written by `setup-corgiro`). To pick up newly-assigned accounts, re-run `/corgiro setup-corgiro` — it re-discovers via `aws sso list-accounts`.
- **cross-account-role** → pull the full org roster:
  ```bash
  aws organizations list-accounts --output json > accounts.json
  ```
  Filter to `ACTIVE` accounts only. Apply `accountFilter`.

### Step 2: Probe Each Account

Resolve credentials per [`../../references/credential-resolution.md`](../../references/credential-resolution.md) and probe with `aws sts get-caller-identity`. Categorize using the shared reachability vocabulary:

- **identity-center-direct**: `reachable`, `auth_expired`, `not_in_scope`
- **cross-account-role**: `reachable`, `role_missing`, `trust_mismatch`, `suspended`, `management`

Run up to `max_parallel` probes; back off on throttling.

### Step 3: Diff Against Previous Snapshot

Compare with the prior `~/.corgiro/state/roster.json`:

- **New accounts**: in scope since the last snapshot
- **Removed accounts**: no longer in scope

### Step 4: Generate Report & Save Snapshots

Render per the shared [`../../references/report-format.md`](../../references/report-format.md) (self-contained HTML + Markdown, Corgiro branding). Write `Coverage-Report-<DATE>.{md,html}` (`output_format`, default `both`) with:

- Summary counts per category (KPI cards)
- **Table of accounts you have access to** (reachable): account ID, name, role, `via`
- Table of non-reachable accounts with remediation (per the credential-resolution failure table)
- New account alerts

Reachability → badges: reachable `badge--green`; `auth_expired` / `role_missing` / `trust_mismatch` `badge--red`; warnings `badge--amber`; `management` / `suspended` `badge--zinc`.

Update snapshots:

- `~/.corgiro/state/coverage.json` — reachability result (both modes)
- `~/.corgiro/state/roster.json`:
  - **cross-account-role**: authoritative — write the discovered org accounts (each entry `via: "assume-role"`)
  - **identity-center-direct**: owned by `setup-corgiro` — refresh reachability flags only; do not add/remove accounts (re-run setup to change scope)

## Output

```
./<run_id>/
├── scope.json
├── accounts.json
├── coverage.json
├── diff.json
├── Coverage-Report-<DATE>.md
└── Coverage-Report-<DATE>.html
```
