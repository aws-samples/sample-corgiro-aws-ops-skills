---
name: mode-builder
description: "Interactive workflow that helps users create custom Corgiro modes for their own AWS Organization. Walks through ideation, AWS API discovery, drafting, validation, and testing. Use when someone wants to add a new /corgiro mode, build a custom org-wide inspection workflow, or automate a multi-account AWS check."
user-invocable: true
---

# Mode Builder

Interactive workflow that helps you create custom Corgiro modes for your AWS Organization. Walks through ideation, AWS API discovery, drafting, validation, and testing — producing a ready-to-use `MODE.md` that plugs into this repo and runs as `/corgiro <your-mode>`.

Only builds modes using **public AWS CLI read-only APIs**. If a workflow requires mutating APIs or non-AWS data sources, it stops and explains why.

**Output**: A validated mode at `modes/<mode-name>/MODE.md`, registered in the catalogues and ready to invoke.

## Prerequisites

- This repo (`corgiro-aws-ops-skills`) is cloned locally and on the latest `main`.
- Familiarity with the resource or configuration you want to inspect.
- No `~/.corgiro/config.json` required — this mode builds other modes, it does not query AWS accounts.

Read these before proceeding:
- [`../../references/credential-resolution.md`](../../references/credential-resolution.md) — so the generated mode handles auth correctly.
- [`../../references/report-format.md`](../../references/report-format.md) — so the generated mode renders reports correctly.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `workflow_idea` | _(ask)_ | Brief description of what to inspect across accounts |
| `mode` | `create` | `create` = full build, `validate` = check an existing mode, `iterate` = improve an existing mode |

## Workflow

### Step 1: Mode Check

If `mode` was provided, use it. Otherwise ask:

- **Create a new mode** → proceed to Step 2
- **Validate an existing mode** → ask which mode, then jump to Step 6
- **Iterate on an existing mode** → ask which mode and what to change, then Step 4 → Step 6

For **iterate**: read the existing `MODE.md`, ask what to change, preserve unchanged parts, and show a diff summary after editing.

### Step 2: Ideation Interview

Have a short conversation to understand the inspection workflow:

1. "What AWS resources or configurations do you want to inspect across your accounts?" (e.g., unattached EBS volumes, public S3 buckets, outdated AMIs, Lambda runtimes)
2. "What triggers this check?" (e.g., weekly review, compliance audit, cost optimization, incident response)
3. "What's the deliverable?" (e.g., a risk-scored report, a simple inventory, a cost-waste summary)
4. "Any specific regions or account subsets, or the full org?"
5. "Should findings be risk-scored/prioritized, or just listed?"

Summarize: "So you want a mode that inspects X across Y accounts/regions, scores findings by Z, and produces W. Correct?"

**Do NOT proceed until the user confirms.** If the described workflow requires mutations, external APIs, or non-AWS data, explain why it can't be a Corgiro mode.

### Step 3: AWS API Discovery

Map each inspection step to public AWS CLI read-only APIs:

1. **Identify AWS APIs** for each step. Only allowed verb prefixes: `describe-*`, `list-*`, `get-*`, `batch-get-*`.

2. **Validate each API** against AWS CLI documentation:
   - Command exists
   - Command is read-only (no side effects)
   - Output shape has the needed fields
   - Filter syntax is correct

3. **Check for org-level variants** — some APIs have `*-for-organization` versions (Health, GuardDuty, Security Hub, Config). Note which apply.

4. **Identify shared references to reuse**:
   - Per-account credentials → `credential-resolution.md` ✓
   - Report output → `report-format.md` ✓
   - EOL/lifecycle dates → `aws-version-lifecycle.md` (if applicable)

5. **Check overlap** with the Available modes table in `../../SKILL.md`. If overlap exists, ask: extend the existing mode, or build a new one?

6. **Present the mapping**:
   ```
   | Step | AWS CLI Command | Read-only | Notes |
   |------|-----------------|-----------|-------|
   | Find idle volumes | aws ec2 describe-volumes --filters ... | ✅ | |
   | Estimate cost | aws ce get-cost-and-usage | ✅ | Payer-level caveat |
   ```

7. **Flag gaps** — if any step has no viable read-only AWS API, suggest alternatives or reduced scope.

**STOP** if the core workflow has no viable public read-only AWS APIs.

### Step 4: Draft the Mode

Read [references/mode-template.md](references/mode-template.md) for the skeleton.

Generate `modes/<mode-name>/MODE.md` with:

**Frontmatter:**
```yaml
---
name: <mode-name>
description: "<what it does, trigger phrases>"
user-invocable: true
---
```

**Body** (this section order is mandatory):
1. **Prerequisites** — config, SSO session, coverage snapshot
2. **Parameters** — table with defaults
3. **Workflow** — numbered steps, each referencing the actual `aws` commands
4. **Safety** — read-only, no secrets, confirm before mutating
5. **Output** — run directory structure
6. **Error Handling** — symptom/action table

**Rules enforced during drafting:**

| Rule | Requirement |
|------|-------------|
| Naming | kebab-case `<domain>-<action>` (e.g. `ebs-orphan-scan`) |
| Read-only | Only describe/list/get/batch-get calls |
| Access-mode-agnostic | Resolve creds via `../../references/credential-resolution.md` |
| Reports | Render per `../../references/report-format.md` |
| No real account IDs | Use `111111111111` in examples |
| State | Read from `~/.corgiro/` only |
| Grounded facts | EOL/pricing/limits from AWS docs, never model knowledge |
| Self-contained | Reports inline CSS + logo data URI, no network |
| Progressive disclosure | Split into `references/step-*.md` if workflow exceeds ~150 lines |

Save the generated file. If progressive disclosure is needed, also create `modes/<mode-name>/references/step-N-<name>.md` files.

### Step 5: Register in Catalogues

Update both hand-maintained catalogues (keep edits minimal, no drive-by reformatting):

1. `skills/corgiro/SKILL.md` → add a row to the **Available modes** table
2. `README.md` → add a row to the **Modes** table and update the **Repo Layout** tree

Show the user the exact edits before applying.

### Step 6: Validate

Read [references/validation-checklist.md](references/validation-checklist.md) and run every gate:

1. **Format** — frontmatter present, sections in order
2. **AWS commands** — every `aws` command is real and read-only (cite docs)
3. **Conventions** — read-only, no secrets, self-contained reports, state in `~/.corgiro/`, placeholder IDs, access-mode-agnostic
4. **Link integrity** — relative links resolve (`../../references/` from MODE.md)
5. **Shared reference reuse** — references credential-resolution.md and report-format.md (not duplicated)
6. **No internal tokens** — grep for: `k2_`, `dante_`, `cmc_`, `caseapi_`, `harbinger_`, `sift_`, `pfr`, `use_subagent`, `~/shared/tam-work`, `ReadInternalWebsites`, `mwinit`, `isengard`, `midway`, `CAZ`, real 12-digit account IDs, internal hostnames

Report results:
```
✅ Frontmatter — name, description, user-invocable present
✅ Structure — all sections in order
✅ AWS APIs — all commands validated read-only
✅ Conventions — clean
✅ Links — resolve correctly
✅ Leak scan — no internal tokens
```

Fix and re-validate until all gates pass.

### Step 7: Visualize

Present an ASCII flow diagram:

```
┌─────────────┐
│   INPUTS    │
├─────────────┤
│ • regions   │
│ • filters   │
└──────┬──────┘
       ▼
┌──────────────────────────────────────┐
│ Step N: <name>                       │
│ APIs: <service>:<Action>             │
└──────────────┬───────────────────────┘
       ▼
┌─────────────────┐
│     OUTPUT      │
├─────────────────┤
│ Report (HTML/MD)│
└─────────────────┘

── Summary ──────────────────────────
AWS APIs:        <list>
Shared refs:     credential-resolution.md, report-format.md
Files created:   modes/<name>/MODE.md
Catalogue edits: SKILL.md, README.md
──────────────────────────────────────
```

### Step 8: Test (optional dry-run)

Offer a single-account dry-run:

1. Pick one account from the user's roster (requires `~/.corgiro/config.json` for this step only)
2. Run the mode's core `aws` commands against that account
3. Confirm commands succeed and return expected data
4. If a report is produced, confirm it opens offline with no network calls

### Step 9: Git Handoff

Print (do not execute) the commands:

```bash
cd <repo_root>
git checkout -b feat/<mode-name>-mode
git add skills/corgiro/modes/<mode-name>/ skills/corgiro/SKILL.md README.md
git commit -m "feat(corgiro): add <mode-name> mode"
git push -u origin feat/<mode-name>-mode
```

Remind the user: work against latest `main`, keep the change focused, never paste real account IDs or credentials.

## Safety

- This mode only reads existing repo files and writes new files inside `skills/corgiro/modes/`.
- It never runs AWS API calls (except during the optional dry-run in Step 8, which uses the user's own credentials).
- It never executes git commands — it prints them for the user.
- Generated modes inherit all Corgiro safety rules (read-only, no secrets, prompt-injection defense).

## Output

```
skills/corgiro/modes/<mode-name>/
├── MODE.md
└── references/          (if progressive disclosure needed)
    └── step-*.md
```

Plus edits to `skills/corgiro/SKILL.md` and `README.md`.

## Error Handling

| Symptom | Action |
|---------|--------|
| Workflow requires mutations | Explain read-only constraint; suggest a confirm-gate pattern if the user insists on one mutating step |
| Workflow requires non-AWS data | Explain Corgiro scope; suggest the user build a separate tool for that part |
| AWS API doesn't exist | Remove step, suggest alternative read-only API, or reduce scope |
| Overlap with existing mode | Ask: extend existing or build new? |
| Validation fails (internal token, broken link) | Fix in-place and re-run validation |
