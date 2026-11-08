# Step 2: Resolve Scope and the CE Source Account

Two independent things: which accounts the evidence comes from, and which single
source Cost Explorer is queried from.

Scope (`accounts`, `account_filter`) is read from the roster. The CE source is
decided by an empirical cascade, not by asking: previous iterations of this
mode asked the operator to name an account, then auto-detected one when they
could not, and both failures were avoidable. The cascade is defined in
[`access-pattern.md`](access-pattern.md); this file is where it runs.

## Terminology

- **CE source** — the credential/account pair Cost Explorer is queried from.
  May be a payer, a Billing Conductor primary with a billing-group view, or
  each member account in turn.
- **`rate_basis`** — the rate the CE source returns. Chargeable at tiers 1 and
  3, proforma at tier 2. Derived, never asked.
- **`accounts_visible`** — accounts Cost Explorer actually returned cost for,
  from the chosen CE source. Measured per tier in Step 3, then printed in the
  report header. "Visible" is honest about tier 3 partials (see
  [`access-pattern.md`](access-pattern.md) partial tier 3).

## Resolve `accounts` first: it decides everything else

Read `~/.corgiro/state/roster.json`, then resolve the analysis set:

- **Org-wide (default)** — `accounts` omitted or `all`: every roster entry with
  `reachable: true`, or every entry if the snapshot lacks the field
  (reachability is re-checked implicitly on the first call).
- **Specific accounts** — `accounts` is a list of account IDs or roster names.
  Resolve each entry against the roster:
  - a 12-digit ID present in the roster resolves directly
  - a name is matched case-insensitively against roster `name` values. One
    unambiguous match resolves silently; zero or several is a question, listing
    the candidates. Never guess which account was meant.
  - an ID or name not in the roster is skipped and recorded as `not_in_roster`.
    Corgiro can only reach accounts set up by `setup-corgiro` and refreshed by
    `account-coverage`.

Apply `account_filter` from config on top of either set.

Credential dispatch stays in
[`../../../references/credential-resolution.md`](../../../references/credential-resolution.md).
Do not restate it.

## Resolve the CE source by cascade

The procedure in [`access-pattern.md`](access-pattern.md) defines the tiers and
their succeed/fail semantics. Execute it in order, recording the attempt and
its result. The verification query at each tier is the same probe:

```bash
aws ce get-cost-and-usage \
  --time-period Start=<last_month_start>,End=<this_month_start> \
  --granularity MONTHLY --metrics AmortizedCost \
  [--billing-view-arn <arn>] \
  --region us-east-1 --output json
```

**Tier 1 — payer.** Resolve `management_account_id` from `coverage.json` (set by
`account-coverage`; a roster entry with `via: "management"` identifies it).
Attempt `sts:AssumeRole` into `CorgiroReadOnlyRole` there. On `AccessDenied`,
the role is absent (the normal case for a default setup, because
service-managed StackSets cannot target the management account). Record
`tier1_status: role_absent` and move on.

If AssumeRole succeeds, run the probe. On `DataUnavailableException`, record
`tier1_status: data_unavailable` and move on. On success, record
`tier1_status: pass`, set `rate_basis: chargeable`, `billing_view_arn: null`,
and `ce_source_account: <management_account_id>`.

**Tier 2 — Billing Conductor primary.** For each reachable roster account in a
stable order (roster insertion order is fine), AssumeRole into
`CorgiroReadOnlyRole` and call:

```bash
aws billing list-billing-views --region us-east-1 --output json
```

The first account whose response contains a view with
`billingViewType == "BILLING_GROUP"` is a BC primary. Capture the view's `arn`.
Record `tier2_status: pass`, `rate_basis: proforma`,
`billing_view_arn: <arn>`, and `ce_source_account: <that_account_id>`. Run
the probe with `--billing-view-arn <arn>` to confirm the view is query-able;
on failure, record it and continue down the list.

If no roster account returns a `BILLING_GROUP` view, record `tier2_status:
no_billing_group` and move on. This is the normal case for organizations not
on Billing Conductor.

> **`billingconductor:*` is not used.** Enumerating billing groups directly
> requires `billingconductor:ListBillingGroups`, which is denied under the
> operator permission set and not granted by `ReadOnlyAccess`. `ListBillingViews`
> works because the caller is asking "which views can I see?" rather than "which
> groups does this org have?" — a self-describing read, not a payer enumeration.

**Tier 3 — per-account.** Fan out the probe across every reachable roster
account under `CorgiroReadOnlyRole`. Record per-account results:

```
tier3_status: pass          every account returned cost data
tier3_status: partial       some accounts returned DataUnavailableException
tier3_status: fail          every account returned DataUnavailableException
```

On `pass`, set `rate_basis: chargeable`, `billing_view_arn: null`,
`ce_source_account: "per-account"`. On `partial`, the same, plus
`tier3_partial: { succeeded: [...], failed: [{ accountId, exception }, ...] }`;
the operator is asked to accept the partial at the Step 3 gate (see
[`access-pattern.md`](access-pattern.md) partial tier 3).

On `fail`, the cascade is exhausted — proceed to the hard stop.

## Operator override

After the cascade resolves, present the result in a single line and allow one
override:

```
CE source: tier 3 per-account (6 of 6 accounts reachable, rate_basis: chargeable)
Press enter to proceed, or name a different reachable roster account:
```

The override only changes which account is probed; it does not change the
tier logic (naming the payer still attempts AssumeRole + AmortizedCost; naming
a member still queries per-account).

**Do not ask for a billing-view ARN.** Tier 2 produces it from the API; tiers
1 and 3 do not use one. Previous iterations asked the operator for it under
`AccessDenied` on `ListBillingViews`, which was a dead-end on direct-payer
orgs — an operator billed directly has no view ARN to supply. That question is
gone.

## Hard stop

When the cascade exhausts, print the hard-stop message from
[`access-pattern.md`](access-pattern.md). Its exact wording is the authority —
do not re-derive it here. It names two remediations (deploy the role manually
to the management account, or enable `Linked account discounts` in payer
preferences) and one override (`--metric UnblendedCost`).

Record `ce_cascade_result: hard_stop` in `scope.json` and exit.

## Regions are not resolved here

`regions` is resolved in Step 3, because that is where the data appears: the
spend profile already groups by `REGION` from the same source, so no separate
discovery call is needed. Step 2 records the parameter value and nothing more.

## Persist

Write `scope.json`. `regions_resolved` is left `null` and filled in by Step 3;
tier-specific fields are set only for the tiers that were attempted:

```json
{
  "run_id":            "cost-optimization-review-<service>-20261108-184500",
  "access_mode":       "cross-account-role",
  "auth_method":       "identity-center",

  "ce_source_tier":    3,
  "ce_source_account": "per-account",
  "ce_source_route":   "CorgiroReadOnlyRole, fanned out across reachable roster accounts",
  "billing_view_arn":  null,
  "rate_basis":        "chargeable",

  "tier1_status":      "role_absent",
  "tier2_status":      "no_billing_group",
  "tier3_status":      "pass",
  "tier3_partial":     null,

  "metric":            "AmortizedCost",
  "metric_override":   false,

  "lookback_months":   3,
  "accounts":          "all",
  "accounts_in_scope": [],
  "not_in_roster":     [],

  "services":          null,
  "services_resolved": null,
  "service_chosen":    null,

  "top_n":             10,
  "min_service_usd":   50,
  "min_finding_usd":   25,

  "regions":           "auto",
  "regions_resolved":  null,

  "account_filter":    { "include": [], "exclude": [] },
  "skipped":           []
}
```

`service_chosen` stays `null` until the operator picks one at the end of the
overview phase. `services` (plural, from `--service` if set) is resolved in
Step 3 against the customer's actual spend.
