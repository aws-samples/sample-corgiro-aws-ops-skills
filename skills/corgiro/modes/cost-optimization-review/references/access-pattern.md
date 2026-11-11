# Access Pattern

The executable matrix for this mode. Every step cites this reference rather than
restating credentials, metrics, or source accounts inline — so there is one place
to change the rules and no quiet drift between prose.

## Scope boundary

**Corgiro does not query the organization management account.** `CorgiroReadOnlyRole`
is deployed by `setup-corgiro`'s service-managed StackSet, which cannot target the
management account under AWS's permission model. The mode makes no attempt to work
around this — the management account is out of scope, by design.

For **org-wide cost** the operator names a **Billing Conductor primary account**
that has `CorgiroReadOnlyRole` deployed (its proforma billing-group view covers
every member in the group). For **single-account cost** the operator names any
member with `CorgiroReadOnlyRole` deployed. If the customer has no Billing
Conductor primary and wants org-wide cost, that is **out of scope for this mode** —
Cost Explorer in the payer directly is the right tool.

## Credential matrix

Which credential each API call uses, and from which account. All member-account
credentials come from `credential-resolution.md` (`CorgiroReadOnlyRole` via
AssumeRole under `cross-account-role`, or the per-account SSO profile under
`identity-center-direct` — this mode does not care which, provided the roster
entry resolves).

| API | Credential | Source account | Notes |
|---|---|---|---|
| `pricing:GetProducts`, `DescribeServices`, `GetAttributeValues` | `CorgiroReadOnlyRole` | Tooling account (preferred), or any roster member | Account-agnostic. Pin to tooling so decode calls do not scatter across customer workload accounts in CloudTrail. See [`../../../references/aws-pricing-grounding.md`](../../../references/aws-pricing-grounding.md). |
| `billing:ListBillingViews` | `CorgiroReadOnlyRole` | The account under examination | Used to derive `rate_basis` for the operator-named CE source. Returns only views the caller can see. |
| `ce:*` | `CorgiroReadOnlyRole` | The account the operator named as the CE source (asked per run) | One source per run, named explicitly. The named account is a Billing Conductor primary (proforma, group-wide) or a single member (chargeable, self-only). The mode does not query the organization management account — see Scope boundary above. Scope is whatever cost that one account can see. |
| `describe` / `list` on resource services | `CorgiroReadOnlyRole` | The account that owns the resource | Fan-out per [`../../../references/credential-resolution.md`](../../../references/credential-resolution.md). |
| `cloudwatch:GetMetricData`, `ListMetrics` | `CorgiroReadOnlyRole` | The account that owns the resource | Same. |
| `compute-optimizer:Get*Recommendations` | `CorgiroReadOnlyRole` | The account that owns the resource | Call per-account during fan-out, not org-wide from a payer. |

**Never use the base operator profile for an API call in this mode.** The
operator profile is a `CorgiroOperator` permission set used only to assume
`CorgiroReadOnlyRole`. It does not carry `pricing:*`, `ce:*`, `billing:*`, or
most `describe`/`list` actions, and its `AccessDenied` error reads as a
capability gap when the real problem is the credential choice — exactly the
class of error this reference exists to prevent.

**Never reach the management account through the operator's own Identity
Center assignment** (or any other out-of-band credential). Corgiro does not
query the management account from this mode — see Scope boundary above. Any
credential that bypasses `CorgiroReadOnlyRole` also bypasses the member-account
read-only guard rail (`readOnlyEnforced: true`) and attributes reads in
CloudTrail to an SSO user session rather than a `corgiro-<operator>-<run_id>`
role session.

## Cost Explorer source (operator-named, with verification probe)

Cost analysis runs from **one account per run, named by the operator**. The
operator always knows which account they can read billing from; asking
replaces the fragile detection logic that previous iterations of this mode
tried.

```
Step 2 asks       which account should Corgiro read Cost Explorer from
                  for this run?
                  acceptable answers:
                    - a 12-digit account ID
                    - a roster name (case-insensitive, must resolve uniquely)
                    - a Billing Conductor primary, for org-wide proforma rates
                    - any single member account, for just that account's cost

                  the management account is NOT an acceptable answer (out of
                  scope - see Scope boundary above).

AssumeRole        CorgiroReadOnlyRole in the named account

verification      one small probe before the real work starts:
  probe             ce:GetCostAndUsage, last complete month, AmortizedCost
                    no groupings, no filters

                  succeed     proceed. rate_basis derivation runs next.
                  DataUnavailable on AmortizedCost  -> ask operator for a
                                                       different account,
                                                       or offer the
                                                       --metric UnblendedCost
                                                       override with its caveat
                  AccessDenied                       -> name is wrong; the
                                                       named account has no
                                                       ce:GetCostAndUsage
                                                       permission (unlikely if
                                                       CorgiroReadOnlyRole
                                                       actually resolved; this
                                                       means something else is
                                                       denying CE). Re-ask.
                  AssumeRole fails                   -> name is not in the
                                                       roster, or the role
                                                       does not exist in that
                                                       account. Re-ask.

rate basis        one billing:ListBillingViews on the named account.
  derivation        any view with billingViewType == BILLING_GROUP present
                    -> rate_basis = proforma, record the view ARN,
                       pass it as --billing-view-arn on every ce:* call
                    only billingViewType == PRIMARY present
                    -> rate_basis = chargeable, no --billing-view-arn
                    ListBillingViews denied
                    -> rate_basis = "chargeable (unverified)"; note it in
                       the report header. Do not stop.
```

**Scope matches the named account's visibility.** If the operator names a
Billing Conductor primary, the overview and drill see every member account in
that billing group. If they name a single member account, the analysis is just
that account's cost. The mode does not infer or extend scope beyond what that
one account's CE answers.

**No fan-out, no tiers, no partial coverage.** Only one account is queried.
`accounts_visible` in the report header is whatever `LINKED_ACCOUNT` groupings
that one account's CE returned; `accounts_in_scope` equals it by construction.

## Metric rule

**`AmortizedCost` is the only automatic metric.** The mode does not silently
fall back to `UnblendedCost` on `DataUnavailableException`. The reasoning in
`step-3-spend.md` for preferring amortized is sound wherever CE can return it,
and silently degrading to unblended would:

- misattribute No Upfront RI recurring charges to On Demand, which is the
  problem the amortized metric exists to solve;
- make Step 3 Call B4's commitment-coverage figure unreliable whenever
  coverage is non-zero;
- hide the degradation from the report reader.

The operator may pass `--metric UnblendedCost` as an **explicit override**.
When set, the override skips the hard stop that would otherwise fire on a
`DataUnavailableException` for `AmortizedCost`, and the report header records
that the override was used with the caveat above stated in the Methodology
section. `--metric NetAmortizedCost` and `--metric NetUnblendedCost` are
accepted on the same path as their default-metric counterparts.

## Hard stop

The verification probe above decides whether the named account can answer. On
`DataUnavailableException` for `AmortizedCost` the mode stops with a message
of this exact shape (with values resolved for the run at hand):

```
The CE source account you named, <account_id>, cannot answer AmortizedCost:

  verification probe: ce:GetCostAndUsage
    time period:  <last_month_start> to <this_month_start>
    metric:       AmortizedCost
    result:       DataUnavailableException

  what this means
    CorgiroReadOnlyRole, permissions and Cost Explorer itself are
    working (the API returned a specific error, not AccessDenied),
    but the AmortizedCost metric is not visible from this account.

  your options now
    - name a different account (re-run or let this run re-prompt)
        * for org-wide cost: name a Billing Conductor primary that has
          CorgiroReadOnlyRole deployed. Its proforma billing-group view
          covers every member in the group.
        * for a single account's cost: name that account.
        * the organization management account is out of scope for this
          mode and will not be accepted.
    - pass --metric UnblendedCost, which skips amortized entirely at the
      cost of misattributing No Upfront RI recurring charges to On
      Demand and making commitment-coverage figures unreliable when
      coverage is non-zero. The report records the override.
```

Separate hard-stop for `AccessDenied` on the probe, since the diagnosis is
different — the named account's CE is reachable but the specific action is
blocked, which usually means the CE API itself is disabled in that account
rather than a role permission:

```
The CE source account you named, <account_id>, blocks ce:GetCostAndUsage:

  verification probe: ce:GetCostAndUsage
    result:       AccessDeniedException

  what this means
    CorgiroReadOnlyRole was assumed successfully (the probe started), but
    the account rejected the CE call itself. The most common cause is
    that Cost Explorer has never been enabled for this account (CE must
    be enabled once, from the Billing console). CorgiroReadOnlyRole
    carries ReadOnlyAccess and includes ce:*; the denial is coming from
    the service, not the role.

  your options now
    - someone with Billing console access enables Cost Explorer for
      this account, then re-run. CE backfills 12 months but current-month
      data takes about 24 hours.
    - name a different account that already has CE enabled.
```

## Payer-side prerequisite: "Linked account discounts"

For a MEMBER account (not a Billing Conductor primary) to return
`AmortizedCost` or `NetAmortizedCost`, the payer must have enabled
**Linked account discounts** under:

```
AWS Billing console
  -> Cost Management Preferences
  -> General tab
  -> Member account permissions
  -> Linked account discounts  [v]
```

This is a one-time, org-wide toggle set by someone with Billing console
access in the payer. Cost Explorer refreshes within 24 hours
(https://docs.aws.amazon.com/cost-management/latest/userguide/ce-enable.html).

Without this enabled, the verification probe in Step 2 fails for any
non-BC-primary member account named as the CE source, with:

```
ce:GetCostAndUsage ... --metrics AmortizedCost
  -> DataUnavailableException
```

This is the expected branch to the DataUnavailable hard stop below. It is
distinct from Cost Explorer itself being disabled in the account (which
returns `AccessDeniedException` and hits the separate hard stop).

A Billing Conductor primary is not affected by this preference — it sees
proforma amortized for its billing group regardless.

The `UnblendedCost` override (`--metric UnblendedCost`) is a workaround that
works without the preference, at the cost of misattributing No Upfront RI
recurring charges to On Demand. Prefer enabling the preference and using
amortized.

## Overview and drill phases

This mode has two phases with different access profiles. Both resolve their
credentials through the matrix above; what differs is which calls run.

```
overview phase       Steps 1-3 at service granularity (SERVICE grouping,
                     no decode, no describe). Needs only the named CE source
                     and pricing is not called. Independently useful; can be
                     the entire run via --overview-only.

drill phase          Operator picks ONE service from the overview. Steps 3
                     drill-down + 4 (decode) + 5 (research) + 6 (confirm)
                     + 7 (report) run against that service. Pricing fires
                     from the tooling account; describe/CloudWatch/CO fan
                     out across the accounts holding the chosen service's
                     spend.
```

One service per drill, full stop. A second service is a second run.
`--service <name>` skips the overview phase and runs the drill directly, for
operators who already know what they want to analyze.

## What this reference does not cover

- The base operator session mechanism (how the operator signs in to produce
  the session that assumes `CorgiroReadOnlyRole`). That is in
  [`../../../references/credential-resolution.md`](../../../references/credential-resolution.md)
  under `authMethod`, and is unchanged by this mode.
- IAM role deployment. That is in the `setup-corgiro` mode and its
  `option-b-cross-account.md` reference.
- Call budgets and rate limiting. Those are in
  [`../../../references/cross-account-defaults.md`](../../../references/cross-account-defaults.md).
