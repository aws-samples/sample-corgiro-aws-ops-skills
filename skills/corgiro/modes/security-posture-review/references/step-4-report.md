# Step 4: Generate Report

Render per the shared [`../../../references/report-format.md`](../../../references/report-format.md) - self-contained HTML + Markdown, Corgiro branding, KPI cards, `data-table`, badges, `<details>` for long finding descriptions, and a closing Methodology section. Read that file and conform exactly to its skeleton, asset-injection step (Rule 9), escaping rule (Rule 8), and naming conventions. Do not design a new report or restate the theme.

Honor `output_format` (`markdown` | `html` | `both`). Map severities to badges: Critical `badge--red`, High `badge--orange`, Medium `badge--amber`, Low `badge--blue`; OK/enabled `badge--green`; neutral/n-a `badge--zinc`. For the overall grade KPI card use the accent that matches the lowest-scoring domain tier (`is-critical` for F/D, `is-high`, `is-medium`, `is-ok` for A/B).

## Sections (same order in HTML and Markdown)

1. **Executive Summary** - overall grade + score as the lead KPI card, then one KPI card per domain score, plus total findings by severity. Top 3-5 org-wide risks.
2. **Domain Scorecard** - a `data-table` of the six domains: domain, weighted score (or `n/a`), weight, and a one-line signal summary.
3. **Critical Findings** - root MFA/keys, public RDS, public S3 policy, CloudTrail not logging, security groups open to the internet - grouped, with account, region, resource, and remediation.
4. **High / Medium / Low Findings** - tables by domain, down to `severity_floor`.
5. **Threat Detection** - GuardDuty enablement and findings, Security Hub standards and failed checks, per account/region.
6. **Data Protection** - encryption status (S3, EBS, RDS) and public exposure.
7. **Logging and Monitoring** - CloudTrail configuration and AWS Config status.
8. **Identity Summary** - root MFA/keys, console users without MFA, password policy, Access Analyzer presence. End with a callout: *"This is a summary. For admin-equivalent users and roles, stale and automation access keys, and keyless-auth remediation, run `/corgiro iam-security-review`."*
9. **Network Exposure** - security groups open to the internet, plus the derived public RDS/S3 cross-reference.
10. **Per-Account Summary** - from `aggregated.json` `byAccount`, sorted by top severity.
11. **Quick Wins** - the `quickWins` list (fixes achievable in under an hour).
12. **Remediation Roadmap** - Immediate (Critical) / Short-term (High) / Medium-term (Medium) / Backlog (Low).
13. **Methodology** (required) - tools/APIs used, scope (accounts, regions, date), services found disabled, and what was not covered (note that deep IAM analysis is delegated to `iam-security-review`, and that penetration testing, application security, and code review are out of scope).

## Finish

1. Inject the CSS and logo per report-format.md Rule 9 (placeholder injection), then verify the logo landed (`grep -c` check).
2. Secure the run directory: `chmod 700 ./<run_id>` and `chmod 600 ./<run_id>/*`.
3. `open ./<run_id>/Security-Posture-Review-<DATE>.html`.
