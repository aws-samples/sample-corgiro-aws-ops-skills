# Step 4: Generate Report

Render per the shared [`../../../references/report-format.md`](../../../references/report-format.md) — self-contained HTML + Markdown, Corgiro branding, KPI cards, `data-table`, badges, `<details>` for long finding descriptions, and a closing Methodology section. Read that file and conform exactly to its skeleton, asset-injection step (Rule 9), escaping rule (Rule 8), and naming conventions. Do not design a new report or restate the theme.

Honor `output_format` (`markdown` | `html` | `both`). Map risk tiers, enabled/OK states, and `n/a` domains to badges using the shared [Risk / status → badge mapping](../../../references/report-format.md#risk--status--badge-mapping-shared-vocabulary) — do not redefine it. For the overall grade KPI card, the accent follows the org grade: A/B `is-ok`, C `is-medium`, D `is-high`, F `is-critical`.

## Sections (same order in HTML and Markdown)

1. **Executive Summary** — overall grade + score as the lead KPI card, with "N accounts capped" (from `cappedAccounts`) shown beside the grade, then one KPI card per domain score, plus total findings by risk tier. Top 3-5 org-wide risks.
2. **Domain Scorecard** — a `data-table` of the six domains: domain, org score (or `n/a`), weight, lowest-scoring account, and a one-line signal summary.
3. **Critical Findings** — root MFA/keys, public RDS, public S3 policy, CloudTrail missing or not logging, security groups open to the internet — grouped, with account, region, resource, and remediation.
4. **High / Medium / Low Findings** — tables by domain, down to `risk_floor`.
5. **Threat Detection** — GuardDuty enablement and findings, Security Hub standards and failed checks, per account/region.
6. **Data Protection** — encryption status (S3, EBS, RDS) and public exposure.
7. **Logging and Monitoring** — CloudTrail configuration and AWS Config status.
8. **Identity and Access (summary)** — root MFA/keys, console users without MFA, password policy, Access Analyzer presence, and an informational line "Centralized root access: enabled / not enabled / unknown" from `scope.json` `rootCredentialsManaged` (say why when `unknown`). End with a callout: *"This is a summary. For admin-equivalent users and roles, stale and automation access keys, and keyless-auth remediation, run `/corgiro iam-security-review`."*
9. **Network Security** — security groups open to the internet, plus the derived public RDS/S3 cross-reference.
10. **Per-Account Summary** — from `aggregated.json` `byAccount`: account, grade (with "capped by: <FLAG>" when `gradeCappedBy` is set), score, per-domain scores, finding counts — sorted by score ascending.
11. **Quick Wins** — the `quickWins` list (fixes achievable in under an hour).
12. **Remediation Roadmap** — Immediate (Critical) / Short-term (High) / Medium-term (Medium) / Backlog (Low).
13. **Methodology** (required) — tools/APIs used, scope (accounts, regions, date, and whether regions came from spend discovery or `fallbackRegions`), the scoring method (per-account deductions; account grades capped at C by any Critical and at B by any High, scores unchanged; org = mean of accounts, uncapped; scores ignore `risk_floor`), services found disabled, and what was not covered (regions without spend unless `include_unused_regions` was set; org trails whose status could not be read; neutralized public bucket policies in accounts where per-bucket S3 checks were skipped because account Block Public Access is fully enabled; accounts with `partial` bucket coverage; deep IAM analysis is delegated to `iam-security-review`; penetration testing, application security, and code review are out of scope).

## Finish

1. Inject the CSS and logo per report-format.md Rule 9 (placeholder injection), then verify the logo landed (`grep -c` check).
2. Secure the run directory: `chmod 700 ./<run_id>` and `chmod 600 ./<run_id>/*`.
3. `open ./<run_id>/Security-Posture-Review-<DATE>.html`.
