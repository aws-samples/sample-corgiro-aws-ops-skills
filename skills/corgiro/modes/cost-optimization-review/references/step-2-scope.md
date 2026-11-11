# Step 2: Resolve Scope and the CE Source Account

Two independent things: which accounts the drill-phase evidence may come from,
and which single account Cost Explorer is queried from.

Scope (`accounts`, `account_filter`) is read from the roster. The CE source is
**named by the operator and verified with one probe** — detection has been
retired. The named account's own visibility decides whether the analysis is
org-wide (via a Billing Conductor primary) or single-account (any member).
The procedure in [`access-pattern.md`](access-pattern.md) defines what the
named account may be and what the verification probe checks; this file is
where it runs.

## Terminology

- **CE source account** — the one account `ce:*` is queried from for this run.
  A Billing Conductor primary, or a single member account. The organization
  management account is **not** an acceptable value — see
  [`access-pattern.md`](access-pattern.md) Scope boundary.
- **`rate_basis`** — the rate the CE source returns. `proforma` when the named
  account is a Billing Conductor primary with a `BILLING_GROUP` view,
  `chargeable` otherwise. Derived from `billing:ListBillingViews` on the named
  account, never asked.
- **`accounts_visible`** — the distinct `LINKED_ACCOUNT` values the named CE
  source returns cost for. Measured in Step 3 and printed in the report header.

## Resolve `accounts` first: it decides the drill fan-out

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

`accounts_in_scope` is the **drill-phase evidence set**: the accounts Step 6
may fan out into when confirming lever applicability. It is independent of
which account CE is queried from. A run may read cost org-wide from a Billing
Conductor primary while the drill still fans out into just the accounts whose
spend made the top-N in the chosen service.

Credential dispatch stays in
[`../../../references/credential-resolution.md`](../../../references/credential-resolution.md).
Do not restate it.

## Resolve the CE source: ask the operator, then verify

Ask the operator which account to read Cost Explorer from. One question, one
answer, no detection:

```
Which account should I read Cost Explorer from?

  For org-wide cost analysis, name a Billing Conductor primary account
  that has CorgiroReadOnlyRole deployed. Its proforma billing-group view
  covers every member in the group.

  For a single account's cost, name that account.

  The organization management account is out of scope for this mode and
  will not be accepted — see access-pattern.md Scope boundary.

Account:
```

Accept the answer as:

- a 12-digit account ID present in the roster
- a roster name, matched case-insensitively against roster `name` values. One
  unambiguous match resolves silently; zero or several is a question listing
  the candidates. Never guess.

Reject an answer that resolves to a roster entry with `via: "management"` or
whose `name` indicates the management account — the mode does not query it.
Re-ask.

### Assume the role

`sts:AssumeRole` into `CorgiroReadOnlyRole` in the named account per
[`../../../references/credential-resolution.md`](../../../references/credential-resolution.md).

```
AssumeRole succeeds       proceed to the verification probe below
AssumeRole AccessDenied   the role is not deployed in the named account, or
                          the external-id / trust condition doesn't match.
                          Re-ask for a different account.
AssumeRole other error    report the error, re-ask.
```

### Verification probe

One `ce:GetCostAndUsage` call to confirm the named account can answer the
metric the mode needs **before** any real work starts:

```bash
aws ce get-cost-and-usage \
  --time-period Start=<last_month_start>,End=<this_month_start> \
  --granularity MONTHLY --metrics AmortizedCost \
  --region us-east-1 --output json
```

No groupings, no filters. The point is to test the pair (credential, metric)
for this account, nothing more.

```
success                              proceed to rate-basis derivation below
DataUnavailableException             hard stop with the DataUnavailable message
                                     from access-pattern.md. The named account
                                     may not be able to produce amortized
                                     cost; operator re-runs with a different
                                     account or --metric UnblendedCost override.
AccessDeniedException                hard stop with the AccessDenied message.
                                     CE is not enabled for the account, or an
                                     SCP is denying ce:* above the role.
                                     Operator fixes the account or names
                                     another.
other error (throttling, 5xx)        report and re-ask the operator; do not
                                     retry automatically — this is Step 2,
                                     the probe is cheap, and silently retrying
                                     hides a failing account from the operator.
```

The hard-stop messages are in [`access-pattern.md`](access-pattern.md) Hard
stop. Their exact wording is the authority — do not re-derive them here.

### Rate basis

One `billing:ListBillingViews` on the named account under
`CorgiroReadOnlyRole`:

```bash
aws billing list-billing-views --region us-east-1 --output json
```

Classify from the returned `billingViews[]`:

```
any view with billingViewType == "BILLING_GROUP" present
  -> rate_basis = "proforma"
  -> billing_view_arn = that view's arn
  -> pass --billing-view-arn <arn> on every ce:* call in this run

only billingViewType == "PRIMARY" present
  -> rate_basis = "chargeable"
  -> billing_view_arn = null

ListBillingViews returns AccessDenied
  -> rate_basis = "chargeable (unverified)"
  -> billing_view_arn = null
  -> this is a note in the report header, not a hard stop; the probe
     already confirmed ce:GetCostAndUsage works, so CE itself is readable.
     The caller just cannot enumerate billing views — common when the
     operator permission set omits billing:*.
```

> **`billingconductor:*` is not used.** Enumerating billing groups directly
> requires `billingconductor:ListBillingGroups`, which is denied under the
> operator permission set and not granted by `ReadOnlyAccess`.
> `ListBillingViews` works because the caller is asking "which views can I
> see?" rather than "which groups does this org have?" — a self-describing
> read, not a payer enumeration.

## Regions are not resolved here

`regions` is resolved in Step 3, because that is where the data appears: the
spend profile already groups by `REGION` from the same source, so no separate
discovery call is needed. Step 2 records the parameter value and nothing more.

## Persist

**Create the run directory now** (not earlier). Name:
`cost-optimization-review-<YYYYMMDD>-<HHMMSS>`. The CE source account has
just passed the verification probe, so the run is committed and the name is
settled; it does not change for the rest of the run. The account ID goes in
`scope.json` and in the report filenames, not in the directory name. Parent
directory is `runDirRoot` from
[`../../../references/cross-account-defaults.md`](../../../references/cross-account-defaults.md)
(or `--run-dir` if the operator set one). `chmod 700` the directory before
writing to it.

Write `scope.json`:

```json
{
  "run_id":            "cost-optimization-review-<ce_source_account>-<YYYYMMDD-HHMMSS>",
  "access_mode":       "cross-account-role",
  "auth_method":       "identity-center",

  "ce_source_account": "123456789012",
  "ce_source_role":    "CorgiroReadOnlyRole",
  "billing_view_arn":  null,
  "rate_basis":        "chargeable",

  "metric":            "AmortizedCost",
  "metric_override":   false,

  "lookback_months":   3,
  "accounts":          "all",
  "accounts_in_scope": [],
  "not_in_roster":     [],

  "services":          null,
  "services_resolved": null,
  "service_chosen":    null,

  "min_service_usd":   50,
  "coverage_share":    0.95,
  "noise_floor_pct":   0.001,

  "regions":           "auto",
  "regions_resolved":  null,

  "account_filter":    { "include": [], "exclude": [] },
  "skipped":           []
}
```

`service_chosen` stays `null` until the operator picks one at the end of the
overview phase. `services` (plural) is reserved for a future multi-service
run and is `null` in the current single-service flow.
