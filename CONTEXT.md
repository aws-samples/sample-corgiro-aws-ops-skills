# Corgiro

AWS multi-account cloud-operations skill. Modes fan out read-only AWS API calls across an organization's accounts and render shareable reports. This glossary pins the vocabulary shared by all modes.

## Language

**Roster**:
The persistent record of every account Corgiro operates on, one Roster Entry per account. Written by setup, reachability-refreshed by coverage runs; every downstream mode reads it. Its entry schema is owned by a single authoritative reference (`credential-resolution.md`) — no other document may restate it.
_Avoid_: account list, scope file, inventory

**Roster Entry**:
The per-account record inside the Roster carrying how to reach the account (`via`), what identity to use, and whether read-only and the data-plane denylist are IAM-enforced.
_Avoid_: account record, account config

**Access Mode**:
The operator-chosen model for reaching accounts: `identity-center-direct` (existing SSO assignments, read-only is behavioral) or `cross-account-role` (assumed org-wide role, read-only is IAM-enforced).
_Avoid_: auth mode, login type

**Role Provenance**:
Who owns the member-account role Corgiro assumes: `corgiro-managed` (Corgiro deployed it) or `customer-managed` (the organization already operated it and Corgiro adopts it). An axis orthogonal to Access Mode and to how the operator signs in; meaningful only under `cross-account-role`. Corgiro never modifies a role it does not own.
_Avoid_: role ownership, role mode, BYO role

**Session Policy**:
The `ReadOnlyAccess` managed policy and the data-plane denylist that Corgiro passes on every `AssumeRole`, scoping the session down without altering the role. Deliberately redundant with the role's own policies so the boundary survives role drift.
_Avoid_: inline policy (ambiguous with an IAM inline policy), scoped credentials

**Coverage Snapshot**:
The result of the most recent reachability probe across the Roster; the freshness gate downstream modes check before running.
_Avoid_: coverage report (that's the rendered artifact), probe result

**Operator Config**:
The per-laptop configuration (`~/.corgiro/config.json`) carrying the operator's Access Mode, SSO session, and mode-specific settings. Repo-distributed defaults fill anything the operator doesn't override.
_Avoid_: settings file, corgiro config (ambiguous with defaults)

**Profile Prefix**:
The operator-configurable prefix for per-account CLI profile names (`<profilePrefix><accountId>`), defaulting to `corgiro-`. Fixed names are never assumed; documents show the default as a concrete example only.
_Avoid_: profile name pattern, hardcoded profile

**Run Directory**:
The per-execution output directory, named by the run id alone (`./<mode>-<timestamp>/`). The run id already carries the mode name; nothing prepends to it.
_Avoid_: output folder, report directory

**Risk Tier**:
The shared urgency scale used by every report: Critical, High, Medium, Low, plus OK/Done and Informational. Low means "on the radar, not urgent" — it is not an all-clear; OK/Done is. A color carries the same meaning in every report.
_Avoid_: severity (reserved for AWS Health events), health score

**Mode**:
One user-invocable Corgiro workflow, defined by a `MODE.md` and dispatched by the router in `SKILL.md`.
_Avoid_: command, tool, sub-skill
