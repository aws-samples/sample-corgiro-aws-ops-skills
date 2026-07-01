# Contributing to Corgiro

Corgiro is a single Agent Skill for **read-only** AWS multi-account cloud operations, consumed by agents that support the [Agent Skills specification](https://agentskills.io) (Claude Code, Kiro CLI, Cursor, …). This guide explains how the repository is organized, where new content belongs, and how to submit changes.

---

## Repository architecture

Unlike multi-skill collections, Corgiro ships as **one skill** (`skills/corgiro/`) that exposes several **modes** behind a single namespaced command:

```
/corgiro <mode-name>
```

`SKILL.md` is a thin **router** — it parses the first token as the mode name and dispatches to `modes/<mode>/MODE.md`. Everything else is one of three content types: **modes** (how a capability runs), **references** (what the agent knows), and **assets** (concrete files modes read or emit).

```
skills/corgiro/
├── SKILL.md                       # 🧭 Router: /corgiro <mode> dispatch, config schema, safety
├── modes/                         # 🎬 One workflow per mode (each = a /corgiro subcommand)
│   ├── setup-corgiro/
│   │   ├── MODE.md                #    chooses Option A or B
│   │   └── references/            #    option-a-identity-center.md, option-b-cross-account.md
│   ├── account-coverage/MODE.md
│   ├── health-event-analysis/
│   │   ├── MODE.md
│   │   └── references/            #    step-0…step-4 (progressive disclosure)
│   ├── rds-eol-analysis/MODE.md
│   ├── eks-eol-analysis/MODE.md
│   └── ec2-compute-review/MODE.md
├── references/                    # 📚 Shared knowledge/config/conventions (reused by modes)
│   ├── cross-account-defaults.md
│   ├── credential-resolution.md
│   ├── aws-version-lifecycle.md
│   └── report-format.md
└── assets/                        # 🧱 Files modes read or emit
    ├── corgiro-readonly-role.yaml #    CloudFormation (Option B)
    ├── report-theme.css           #    shared report styling
    ├── corgiro-logo.png           #    96×96 logo (source)
    └── corgiro-logo.datauri       #    logo encoded as a data URI (inlined into reports)
```

Putting content in the wrong bucket degrades the agent: a mode that inlines shared knowledge can't be reused, and knowledge buried inside one `MODE.md` is invisible to every other mode.

---

## The three content types

### `modes/<name>/MODE.md` — _how_ a capability runs

The workflow the agent follows for one mode: prerequisites, parameters, numbered steps, safety, and output. One mode = one `/corgiro <name>` subcommand.

- **Progressive disclosure** — a long workflow splits step detail into `modes/<name>/references/step-*.md`, loaded only when that step runs (see `health-event-analysis`). A short workflow keeps everything in `MODE.md` (see `rds-eol-analysis`, `account-coverage`).
- **Frontmatter** — `name`, `description`, `user-invocable: true`.
- **References knowledge, doesn't duplicate it** — a mode says "resolve credentials per `references/credential-resolution.md`," it does not restate the dispatch logic.

| ✅ Belongs in a MODE.md                           | ❌ Does not belong                    | Where it goes                                    |
| ------------------------------------------------- | ------------------------------------- | ------------------------------------------------ |
| Step-by-step procedure, prerequisites, parameters | Knowledge reused by 2+ modes          | `references/`                                    |
| STOP gates / confirm-before-mutate prompts        | A deployable file (CFN template, CSS) | `assets/`                                        |
| Per-mode output structure                         | Hard-coded EOL dates or pricing       | scrape per `references/aws-version-lifecycle.md` |

### `references/` — _what_ the agent knows (shared)

Cross-cutting knowledge, configuration, and conventions reused by more than one mode. Plain Markdown; frontmatter optional.

| Reference                   | Purpose                                                                                         |
| --------------------------- | ----------------------------------------------------------------------------------------------- |
| `cross-account-defaults.md` | Default config values + AssumeRole pattern                                                      |
| `credential-resolution.md`  | Per-account credential dispatch on each roster entry's `via` (keeps modes access-mode-agnostic) |
| `aws-version-lifecycle.md`  | How to scrape EOL/lifecycle dates from AWS docs (fail-stop, never model knowledge)              |
| `report-format.md`          | Shared report structure, branding, and badge vocabulary; pairs with `assets/report-theme.css`   |

If two or more modes need the same fact or procedure, it belongs here — not copy-pasted into each `MODE.md`.

### `assets/` — concrete files

Files a mode reads as input or emits as output: the Option B CloudFormation template, the report theme, and the logo. Keep report output **self-contained** — embed images as data URIs (see `corgiro-logo.datauri`), never link external URLs or fonts.

### Where does new content go?

| If the content is…                                           | It goes in…                      |
| ------------------------------------------------------------ | -------------------------------- |
| A new top-level capability invoked as `/corgiro <x>`         | `modes/<x>/MODE.md`              |
| Step detail for one complex mode, loaded on demand           | `modes/<x>/references/step-*.md` |
| Knowledge / config / conventions reused by 2+ modes          | `references/<name>.md`           |
| A file a mode reads or emits (template, CSS, image)          | `assets/`                        |
| Global routing, the config schema, or repo-wide safety rules | `SKILL.md`                       |

**The key test:** if you deleted every `MODE.md`, would the agent still _know_ the facts (how to scrape EOL dates, how to resolve credentials)? Yes — `references/` holds the knowledge. But it wouldn't know how to _run_ a mode. Conversely, anything two modes both need must live in `references/`.

---

## Conventions & principles

These are load-bearing for Corgiro and reviewers will check them:

- **Read-only by default.** Only `describe` / `list` / `get` calls. Any create/update/delete step must pause for explicit user approval (Option B's StackSet deploy is the one mutating step — it confirms first).
- **Never expose secrets.** Don't print access keys, session tokens, SSO tokens, or the external ID. Reference credential/cache files by path, not value.
- **Ground every fact in AWS docs — never guess.** EOL dates and pricing are scraped per `references/aws-version-lifecycle.md` (fail-stop if scraping fails); API shapes, filter formats, and limits are cited from docs. No model-knowledge dates.
- **Stay access-mode-agnostic.** Resolve per-account credentials through `references/credential-resolution.md` (dispatch on each roster entry's `via`). Don't assume SSO-only or AssumeRole-only — a mode must work under both `identity-center-direct` and `cross-account-role`.
- **Reports are self-contained.** Any mode that emits a report renders via `references/report-format.md`, which inlines `assets/report-theme.css` and the logo data URI. No external CSS, fonts, or network calls. Honor the `output_format` parameter (`markdown` / `html` / `both`).
- **State lives in `~/.corgiro/`.** `config.json` plus `state/roster.json` and `state/coverage.json`, written by `setup-corgiro` / `account-coverage`. Read these; don't invent new state locations.
- **No real account data in the repo.** Use placeholder account IDs (`111111111111`, …) in examples and docs.

---

## Adding a new mode

1. Create `modes/<name>/MODE.md` with frontmatter (`name`, `description`, `user-invocable: true`) and the workflow: **Prerequisites → Parameters → numbered Steps → Safety → Output**.
2. If the workflow is long, split step detail into `modes/<name>/references/step-*.md` and read each file before its step. Short modes can stay monolithic.
3. Reuse shared references — `credential-resolution.md` for per-account access, `report-format.md` for any report output. Don't duplicate them.
4. Register the mode in the two **hand-maintained** catalogues (this repo has no auto-generation or CI doc-sync, so keep them aligned manually):
   - `SKILL.md` → **Available modes** table — routing keys off this.
   - `README.md` → **Modes** table and **Repo Layout** tree.
5. Keep it read-only and access-mode-agnostic.
6. Test against a real or sandbox multi-account setup, and confirm any report opens offline (self-contained).

## Adding a shared reference

1. Create `references/<name>.md` (plain Markdown; frontmatter optional).
2. Link it from each mode that uses it with the correct relative depth: `../../references/<name>.md` from a `MODE.md`, `../../../references/<name>.md` from a mode-local step file.
3. If broadly applicable, add it to `SKILL.md` → **Shared References**.

## Adding an asset

Place input/output files in `assets/` and reference them by relative path. For anything that ends up in a report, embed it (data URI) so the report stays a single portable file.

---

## Reporting bugs / feature requests

Use the GitHub issue tracker for `aws-samples/sample-corgiro-aws-ops-skills`. Check existing open and recently closed issues first. Helpful details:

- Reproducible steps and the mode involved (`/corgiro <mode>`)
- The agent / CLI used (Claude Code, Kiro CLI, Cursor, …) and version
- Anything unusual about your environment (access mode, org layout)

**Never** paste real account IDs, credentials, or the external ID into an issue.

## Contributing via pull requests

1. Work against the latest `main`.
2. Keep the change focused — avoid drive-by reformatting so reviewers can see the actual change.
3. Discuss significant work in an issue first.
4. Validate before opening the PR: Markdown renders, relative links resolve, and (for report changes) a sample report opens offline with no network calls.
5. Commit with clear messages and open a Pull Request describing the change and how you tested it.
6. Watch for CI / review feedback and stay in the conversation.

## Code of Conduct

This project follows the [Amazon Open Source Code of Conduct](https://aws.github.io/code-of-conduct) — see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Security issue notifications

If you discover a potential security issue, **do not open a public issue.** Report it to AWS/Amazon Security via the [vulnerability reporting page](https://aws.amazon.com/security/vulnerability-reporting/).

## Licensing

Corgiro is licensed under **MIT-0** — see [LICENSE](LICENSE). It is a single in-house skill, so `SKILL.md`'s `license: MIT-0` frontmatter matches the root LICENSE; individual files don't carry their own license. By contributing, you agree your contribution is licensed under the same terms.
