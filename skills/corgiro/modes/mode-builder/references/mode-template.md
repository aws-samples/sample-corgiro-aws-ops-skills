# Mode Template

Skeleton for a new Corgiro mode. Replace every `<PLACEHOLDER>`, delete guidance comments, keep section order fixed.

## Frontmatter

```yaml
---
name: <mode-name>
description: "<What the mode inspects across accounts. Include trigger phrases. 1-3 sentences.>"
user-invocable: true
---
```

## Body

```markdown
# <Mode Title>

<One paragraph: what this mode does across the org and what the operator gets.>

## Prerequisites

- `~/.corgiro/config.json` exists (run `/corgiro setup-corgiro` if not) and a valid SSO session.
- A fresh coverage snapshot (run `/corgiro account-coverage` if stale).
- Read [`../../references/credential-resolution.md`](../../references/credential-resolution.md)
  and [`../../references/cross-account-defaults.md`](../../references/cross-account-defaults.md).

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `regions` | `auto` | Region list, or `auto` to discover from spend/usage |
| `account_filter` | _(from config)_ | Include/exclude lists |
| `max_parallel` | `4` | Concurrent accounts (clamped to 10 max) |
| `output_format` | `both` | `markdown`, `html`, or `both` |

## Workflow

### Step 1: Prerequisite check

Confirm coverage snapshot is fresh and SSO session is valid.

### Step 2: Determine scope

Build account list from `~/.corgiro/state/roster.json`. Apply `account_filter`.

### Step 3: Inventory <resources>

For each reachable account + region (up to `max_parallel` concurrently):

1. Resolve credentials per [`../../references/credential-resolution.md`](../../references/credential-resolution.md).
2. `aws <service> <describe-or-list> ...`
3. Save to `per-account/<account_id>/<region>/<resource>.json`.

### Step 4: Analyze / risk-score

| Risk | Criteria |
|------|----------|
| 🔴 Critical | <...> |
| 🟠 High | <...> |
| 🟡 Medium | <...> |
| 🟢 Low | <...> |

### Step 5: Generate report

Render per [`../../references/report-format.md`](../../references/report-format.md).

## Safety

- Read-only: only describe/list/get calls.
- Never print access keys, session tokens, or the external ID.

## Output

\```
./<mode-name>-<run_id>/
├── scope.json
├── per-account/<account_id>/<region>/<resource>.json
├── aggregated.json
├── <Topic>-<DATE>.md
└── <Topic>-<DATE>.html
\```

## Error Handling

| Symptom | Action |
|---------|--------|
| Credential resolution fails | Skip account, note in report, continue |
| `ThrottlingException` | Reduce `max_parallel`, exponential backoff |
| Cost Explorer `AccessDenied` | Pass explicit `regions` instead of `auto` |
```

## Conventions checklist

- kebab-case `<domain>-<action>` naming
- Read-only APIs only (describe/list/get/batch-get)
- Access-mode-agnostic (dispatch on `via` per credential-resolution.md)
- Reuse shared references, never restate them
- Placeholder IDs `111111111111` in examples
- State from `~/.corgiro/` only
- Self-contained reports (inline CSS + logo, no network)
- Progressive disclosure for workflows >150 lines
