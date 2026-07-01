# Validation Checklist

Gates to pass before a generated mode is ready to commit. Run all; fix and re-run until clean.

## 1. Format

- [ ] Frontmatter has `name`, `description`, `user-invocable: true`
- [ ] Sections in order: Prerequisites → Parameters → Workflow → Safety → Output → Error Handling
- [ ] Mode name matches directory name (`modes/<name>/MODE.md`)

## 2. AWS Command Validation

For every `aws` command in the mode:

- [ ] Command exists in AWS CLI reference
- [ ] Command is read-only (describe/list/get/batch-get)
- [ ] Output shape has the fields the mode needs
- [ ] Filters/parameters use correct syntax
- [ ] Payer-level caveats noted (Cost Explorer, Organizations)

## 3. Convention Gates

- [ ] Read-only only — no create/update/delete without explicit confirm gate
- [ ] Secrets never printed (access keys, tokens, external ID)
- [ ] Reports self-contained (inline CSS + logo data URI, no network)
- [ ] State from `~/.corgiro/` only
- [ ] Placeholder IDs only (`111111111111`)
- [ ] Access-mode-agnostic — dispatches on `via` per credential-resolution.md

## 4. Link Integrity

- [ ] Links from `MODE.md` use `../../references/<name>.md`
- [ ] Links from `references/step-*.md` use `../../../references/<name>.md`
- [ ] All linked files exist

## 5. Leak Scan

Grep for these — any hit is a hard fail:

```
k2_    dante_    cmc_    caseapi_    harbinger_    sift_    pfr
use_subagent    ~/shared/tam-work    ReadInternalWebsites
mwinit    isengard    midway    CAZ    bubblewand
```

Also reject:
- Real 12-digit AWS account IDs
- Internal hostnames (`.amazon.com`, `.a2z.com`, `.corp.amazon.com`)
- Internal tool names (UNO, AIM, K2, Dante, CMC)

## 6. Shared Reference Reuse

- [ ] Per-account credentials → references `credential-resolution.md`
- [ ] Report output → references `report-format.md`
- [ ] EOL/lifecycle → references `aws-version-lifecycle.md` (if applicable)
- [ ] None of these are restated/duplicated in the mode
