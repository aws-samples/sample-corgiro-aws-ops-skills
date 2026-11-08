# cost-optimization-review -- Design Decisions

Rationale for the mode's shape. Kept alongside `MODE.md` because the reasons are
not recoverable from the instructions, and every decision below has a cheaper,
wrong alternative that a later reader would otherwise "simplify" back into.

Status: design agreed, not yet implemented.

---

## Purpose

Port the proven TAM cost-optimization workflow to a customer-facing, read-only
tool:

1. Analyze cost to find what drives spend (service / usage type).
2. Research the optimization levers for that specific usage type, each with its
   limitations, grounded in official AWS documentation rather than assumption.
3. Confirm which levers actually apply by pulling the customer's real resource
   metadata, configuration and CloudWatch metrics.

The internal version of this workflow reads resource-level CUR via an
AWS-internal Athena deployment. This mode cannot, and does not try to.

---

## D1. No CUR, no Athena

**Decision.** Cost data comes from Cost Explorer only. The mode never runs an
Athena query.

**Why.** `CorgiroReadOnlyRole` blocks it at both ends:

| Step | Status in the role | Reason |
|---|---|---|
| `athena:StartQueryExecution` | not granted | Write access level, absent from `ReadOnlyAccess` |
| `athena:GetQueryResults` | granted | useless on its own |
| `s3:GetObject` | **explicitly denied** | `CorgiroReadOnlyRole-DataPlaneDeny`, first entry |

The second block is not incidental. AWS documents denying `s3:GetObject` as *the*
mechanism for restricting Athena result access:

> "To stream query results successfully, the IAM principal with permission to call
> `GetQueryResults` also must have permissions to the Amazon S3 `GetObject` action
> for the Athena query results location. [...] To restrict user or role access,
> ensure that Amazon S3 permissions to the Athena query location are denied."
>
> https://docs.aws.amazon.com/athena/latest/APIReference/API_GetQueryResults.html

So Corgiro's deny list is already working as specified. Running CUR queries would
require widening the one hard control Corgiro has, org-wide, via a StackSet
redeploy, for a single mode.

**Rejected alternatives.**

- *Widen the member role.* Breaks "read-only is IAM-enforced", which is the
  property customer security reviewers approve. Also spends customer money
  unattended ($5/TB scanned).
- *Operator runs the query, Corgiro reads results by `QueryExecutionId`.* Fails
  for the same reason: reading results is the denied half.
- *Operator runs the query and hands over a CSV.* Viable, and kept as a possible
  v2 escape hatch, but it adds a manual step, an untrusted-input parser, and does
  not fit a mode intended to run unattended.
- *A separate narrow `CorgiroCurReaderRole` in the one CUR account.* Also viable
  and leaves `CorgiroReadOnlyRole` untouched. Deferred: not needed once D2 showed
  CE plus resource evidence covers the workflow.

**What is lost.** Per-resource dollar attribution beyond 14 days. Stated in the
report's Methodology, not hidden: this mode gives service and usage-type
granularity with resource-level *diagnosis*, not resource-level cost
*attribution*.

**What is gained.** Dropping CUR deletes the hardest artifact in the internal
workflow. The amortized-cost `CASE` statement exists only because CUR has no
amortized column; Cost Explorer computes `AmortizedCost` server-side. CUR format
detection (Legacy vs 2.0, flat vs dotted columns, `year`/`month` vs
`bill_billing_period_start_date`) disappears entirely.

---

## D2. CE spend + public docs + live resource evidence is sufficient

**Decision.** Three layers, and a recommendation requires **all three**.

| Layer | Source | Answers |
|---|---|---|
| 1 SPEND | `ce:GetCostAndUsage` | what costs money, and how much |
| 2 GROUND | AWS docs + `pricing:GetProducts` | what levers exist, their limits, the rates |
| 3 VERIFY | `describe`/`list` + `cloudwatch:GetMetricData` | whether each lever applies *here* |

**Why.** Layer 1 alone yields "NAT spend is high", which is useless. Layers 1+2
yield generic best practice already in every blog. Only layer 3 produces a
specific, defensible finding. Layer 3 is also what Corgiro is uniquely good at:
it is a multi-account resource inspector that happens to have CE access. CUR
knows what cost money; it has no idea whether a VPC endpoint exists.

**Usage type is the join key.** A CUR line item's optimization value is mostly
`line_item_usage_type` plus `line_item_resource_id`. CE gives the usage type
*exactly* -- same billing dimension, same strings. Only the resource ID is lost,
and the candidate resource set is re-derivable from `describe` calls.

---

## D3. The lever is the unit of work, not the finding

**Decision.** One cost line yields N levers. Each lever gets its own verdict:

```
APPLICABLE      evidence + estimated saving
NOT APPLICABLE  the reason, cited to the evidence
INDETERMINATE   exactly what data is missing and how to obtain it
```

All three are reported.

**Why.** A single cost line usually has several levers of which only some apply.
Collapsing them into one finding loses the per-lever reasoning that is the actual
TAM contribution. Reporting `NOT APPLICABLE` prevents the customer being
re-pitched the same generic advice in six months. Reporting `INDETERMINATE` names
the data gap instead of guessing past it.

**Corollary.** When a lever's proof requires a denied action, the verdict is
`INDETERMINATE` with the reason stated -- never a silent drop. Otherwise the
report looks complete while having skipped the levers Corgiro cannot see.

---

## D4. No domain taxonomy

**Decision.** The mode has no domain/category structure. Scope is by money:
`top_n` and `min_finding_usd`.

**Why.** The workflow is domain-invariant: steps 3 to 6 are identical whether the
cost line is NAT, unattached EBS, S3 storage class or CloudWatch logs. The only
thing that varies is which `describe` calls prove a given lever, and that lives on
the lever record as `proof_required`. A domain taxonomy added a thing to maintain
and could silently exclude a line that mattered.

Report grouping comes free from the decode step's `productFamily`, `servicename`
and `group` -- authoritative, self-updating, no hand-maintained mapping.

**Two exclusions remain**, as deferrals rather than domains:

- purchase type Reserved / Savings Plans, or any commitment lever
  -> `/corgiro ri-sp-coverage-analysis`
- EC2 instance rightsizing, generation currency, Graviton
  -> `/corgiro ec2-compute-review`

Same pattern `security-posture-review` uses to defer deep IAM analysis to
`iam-security-review`.

---

## D5. Decode every usage type against the pricing API. Never assume.

**Decision.** Step 4 is a gate. A usage-type code with no resolved pricing record
does not proceed to lever research.

**Why.** Model memory on these codes is unreliable, and a misdecode silently
invalidates every downstream step: you research correct-looking levers for the
wrong product. Demonstrated during design, on the first attempt:

```
USE1-NatGateway-Bytes          DOES NOT EXIST  (the assumed code)
NatGateway-Bytes               exists, unprefixed = us-east-1
USE1-RegionalNatGateway-Bytes  exists, WITH the prefix
```

us-east-1 drops the region prefix on one NAT variant and keeps it on another, so
there is no rule to memorise. Meanwhile `-Bytes` is three different products with
different levers:

```
NatGateway-Hours / -Bytes           standard NAT: hourly + data processing
RegionalNatGateway-Hours / -Bytes   regional NAT, automatic multi-AZ expansion
NatGateway-Prvd-Bytes / -Prvd-Gbps  provisioned throughput, billed in Gbps
```

VPC endpoints behave differently again: they *keep* the `USE1-` prefix, and have
eight variants per region (`Bytes`, `Hours`, `GWLBE-*`, `Resource-Hours`,
`Service-Hours`, `Tunnel-Hours`, `ODB-Resource-Hours`).

Region codes are not guessable either: `EU` (legacy eu-west-1), `APS1`-`APS9`,
`APE1`/`APE2`, `EUC2`, `MES1`, `ILC1`, `MXC1`, `LAX1`/`PHX1` (Local Zones),
`UGE1`/`UGW1` (GovCloud).

**The API answers it directly.** `pricing:GetProducts` filtered on `usagetype`
returns `groupDescription` (what the usage type is), `priceDimensions.description`
(what it costs, in prose), `productFamily`, `operation`, `unit`, and
`regionCode`/`location` -- so the region prefix never needs decoding by hand.

**Cross-check.** CE returns `UsageQuantity` with its own unit. If CE says `GB` and
the price record says `Gbps`, the wrong SKU was resolved (`-Bytes` vs
`-Prvd-Gbps`) and the decode fails even though a record came back.

**Catalogue key.** `(service_code, productFamily, operation, unit)`, not a regex
over the raw string. One entry then covers all ~180 NAT codes across every region
while keeping the three variants correctly separated. A raw-string regex would
have matched `-Prvd-Bytes` into the standard NAT lever set -- precisely the bug
this gate exists to prevent.

---

## D6. Walk every price dimension. Never take the first.

**Decision.** Savings math walks all `priceDimensions`, sorted by `beginRange`,
and applies the customer's actual `UsageQuantity` against the tiers.

**Why.** Some SKUs are flat, some are tiered, and **the API does not return
dimensions in range order**. Observed on `USE1-VpcEndpoint-Bytes`, in this
response order:

```
0          -> 1,048,576 GB   $0.010/GB
5,242,880  -> Inf            $0.004/GB     <- returned second
1,048,576  -> 5,242,880 GB   $0.006/GB     <- returned third
```

Taking `pricePerUnit` from the first dimension happens to be right here and
silently wrong at volume. Sorting is mandatory, not defensive.

---

## D7. Default metric is AmortizedCost, and gross saving is not realizable saving

**Decision.** `metric` defaults to `AmortizedCost`. Step 3 also groups by
`PURCHASE_TYPE`. Every lever reports both a gross and a realizable saving.

**Why AmortizedCost.** `UnblendedCost` classifies No Upfront RI recurring charges
as "On Demand Instances", which can make 80% coverage look like 20%. Same default
and same rationale as `ri-sp-coverage-analysis`.

**Why the second number.** AmortizedCost is the right figure for *sizing* a
problem and the wrong figure for *estimating a saving*. If a lever eliminates
usage that a commitment already covers, the commitment is still paid: the freed
commitment either gets absorbed by other usage or becomes unused commitment.

```
idle EC2 instance, 100% Compute SP covered
  AmortizedCost says    $420/mo
  lever says            terminate it
  bill reduction        $0 until the commitment is absorbed or the SP expires
```

Where it bites: idle or orphaned EC2 / Fargate / Lambda / RDS / ElastiCache /
OpenSearch / Redshift. Where it does not: NAT, data transfer, inter-AZ, EIP, EBS,
S3, CloudWatch -- none are commitment-eligible, so gross equals realizable.

**Related deferral.** A cost line that is itself *unused commitment* is not a
config lever. Hand it to `ri-sp-coverage-analysis`.

---

## D8. Derive the effective rate from CE. The Price List rate is for decoding.

**Decision.** Savings arithmetic uses the customer's effective unit rate, derived
from CE:

```
effective_unit_rate = AmortizedCost / UsageQuantity
```

`pricing:GetProducts` is used to decode the SKU, name the alternative, and
sanity-check against list -- not as the arithmetic input.

**Why.** Customers billed through a distributor or solution provider pay custom
rates, and so do customers with an EDP or PPA. A saving computed from public list
price is wrong for all of them, usually overstated, and overstatement is what gets
a report dismissed.

```
NatGateway-Bytes   $12,400 / 410,000 GB  = $0.0302/GB effective
pricing:GetProducts                        $0.0450/GB list
-> ~33% off list. Use $0.0302, and say so in the report.
```

Report both, and state which was used.

---

## D9. Ask which account holds organization cost. Do not detect it.

**Decision.** The CE source account is an operator answer, cached in config. Only
reachability is probed.

**Why detection is actively harmful.** Customers billed through a distributor have
no access to the payer -- it belongs to the distributor and carries the
distributor's discount. The distributor gives them a Billing Conductor primary
account instead. For those customers `organizations:DescribeOrganization` returns
the *distributor's* `MasterAccountId`: an account they can never reach on any
access mode. Corgiro would confidently name the wrong account. That is not a
degraded answer, it is a misleading one.

**Why Corgiro cannot discover the BC path either.**
`billing:ListBillingViews` is the right primitive -- its `billingViewType` is
`PRIMARY | BILLING_GROUP | CUSTOM | BILLING_TRANSFER |
BILLING_TRANSFER_SHOWBACK`, and it returns only what the caller can see. But:

1. `corgiro-operator-role.yaml` grants no `billing:*` and no `billingconductor:*`.
   `ce:List*` does not cover it: the action is in the `billing` namespace.
2. Even with the permission, the operator role is in the *tooling* account, which
   is not the BC primary, so the call would return nothing relevant.

The BC primary is an ordinary member account in the root OU, so
`CorgiroReadOnlyRole` is already deployed there. Once the operator names it,
Corgiro reaches it with no new IAM and nothing to deploy.

**Resolution order.**

```
1  ask once, cache in config:  payer | BC primary | this account only
2  verify the named account is in the roster and reachable
3  from THAT account, billing:ListBillingViews -> pick the BILLING_GROUP ARN
4  pass it as BillingViewArn on ce:GetCostAndUsage
```

Follows the precedent `setup-corgiro` Option C set for `accountFilter`: "AWS holds
no record of it, so Path C cannot detect it. Ask once."

**Disclosure.** Report header prints the CE source account, the billing view, the
rate basis (chargeable vs proforma) and accounts-covered vs accounts-in-roster. A
proforma number is not an invoice number, and a per-account fallback covering 9 of
14 accounts is not an org-wide analysis.

---

## D10. Payer dependency is declared, not assumed

**Decision.** Prerequisites state the dependency and the four ways to satisfy it.
Step 1 hard-stops if none holds.

**Why.** Corgiro has no payer access by default:

| Access mode | Payer reachable? |
|---|---|
| `identity-center-direct` | only if the operator holds a permission set on the payer |
| `cross-account-role` | **no** -- service-managed StackSets skip the management account, and the base profile is the *tooling* account |
| Option C (join existing) | **no**, explicitly. Setup prints a LIMITED CAPABILITY block |

The tooling account's delegated administration covers Health, Config, Security
Hub, GuardDuty, Access Analyzer and Resource Explorer. Not Cost Explorer, and
there is no general delegated administrator for Cost Explorer. Member accounts can
see their own data only if the payer enabled it, which is an all-or-none org
setting.

Four satisfaction paths:

1. Option A with a payer permission set.
2. Deploy `corgiro-readonly-role.yaml` as a standalone stack in the management
   account, same `ToolingAccountId` and `ExternalId`. Already documented in
   `option-b-cross-account.md`, with its caveat: it grants payer read to every
   operator identity.
3. A Billing Conductor billing-group primary account (proforma rates).
4. Per-account member CE, last resort, N x the requests.

**Hard stop, not degrade.** For `ec2-compute-review`, CE powers only an optional
savings estimate, so it degrades. Here CE *is* the mode.

---

## D11. No MCP

**Decision.** Research uses `web_search` + `web_fetch` only.

**Why.** Corgiro ships pure Markdown with no `mcpServers` block and installs into
whatever agent the customer runs. A mode that calls an MCP tool unconditionally
breaks for anyone without it. `aws-version-lifecycle.md` already grounds EOL dates
with `web_fetch` alone, so there is no new pattern here and no branch to maintain.

**Consequence.** Without ranked search, discovery is the slowest and least
reliable part of a run, so the lever catalogue should cache resolved doc URLs per
lever. A recognised usage type then costs zero searches: re-fetch the stored URLs
to confirm they still say what they said, re-pull the rate, done.

**Consequence.** Web access becomes a stated prerequisite. With no web tool,
report the decoded cost lines and state that lever research is unavailable --
steps 3 and 4 still work, both being pure AWS CLI.

---

## D12. Source tiers, with role limits

**Decision.** Sources are ranked, and each has a limit on what it may be the sole
source for.

| Source | Tier | Sole source for... |
|---|---|---|
| `pricing:GetProducts` | 0 | every NUMBER. Always. |
| docs.aws.amazon.com | 1 | mechanism, limitation, quotas, behaviour |
| AWS What's New | 2 | availability, launch dates, region spread |
| AWS Blogs | 3 | approach, sequencing, worked examples. **Not** a rate, **not** a limitation on its own |
| re:Post | 4 | nothing load-bearing. Label as community |

**Two rules, ported from the internal prompt's grounding section.**

1. **Search results are leads, never citable sources.** Fetch the page and take
   the fact from the fetched page. Use `mode="full"` on doc fetches: selective
   extraction drops table rows, and quotas live in tables. Same rule
   `aws-version-lifecycle.md` already mandates.
2. **Record publication dates and distrust stale limitations.** Blogs are
   point-in-time and unmaintained. A 2022 post saying "X does not support Y" is
   routinely wrong by now, and a lever whose limitation rests on it reads
   authoritative while being false.

```
Every lever carries limitation_source + limitation_source_date.
If the only source for a limitation is a blog older than ~18 months, the lever
ships with "limitation needs re-verification" AND that limitation may NOT be
used to mark the lever NOT APPLICABLE.
```

The second clause matters: a stale blog can suppress a lever that now works,
which is a silent loss of savings and invisible in the output.

**Fail-stop.** Both the lever and its limitation must cite a URL plus a fetch
timestamp, or the lever does not appear. Do not soften an uncitable lever to
"consider ...".

---

## D13. Hybrid access pattern

**Decision.** `MODE.md` opens with a "How this mode differs" note, as
`ri-sp-coverage-analysis` does.

**Why.** No existing mode does both single-account and fan-out in one run:

| API | Called from |
|---|---|
| `ce:*`, `billing:ListBillingViews` | ONE account (the CE source) |
| `pricing:*` | anywhere -- global and account-agnostic. Base profile |
| `organizations:*` | base profile (works from the tooling account, which is a delegated admin) |
| `ec2`/`elb`/`rds`/`s3` `describe-*`, `cloudwatch:GetMetricData` | the account that OWNS the resource -- fan out, dispatch on roster `via` |

In one sentence: cost comes from one account, evidence comes from every account,
and pricing comes from anywhere. `ri-sp-coverage-analysis` is single-account only;
every other mode is fan-out only.

---

## D14. Confirmation gate sits after the spend profile, not at scope

**Decision.** Step 2 derives scope silently. Step 3 ends in one confirmation.

**Why.** Cost lines are unknown until CE runs, so a question at Step 2 has no
information behind it. After Step 3 the operator can see real dollars, drop a line
that is a known accepted workload, add one the defaults missed, and see the
coverage column that changes priorities. It also bounds a long run: steps 5 and 6
are web fetches plus a describe fan-out per lever across every account.

Lighter version of `ask`'s plan gate, and the same "state the defaults and ask
once" style as `ri-sp-coverage-analysis`.

---

## Terminology

Avoid "vantage" / "vantage point" (coined during design, discarded).

- **CE source account** -- the account Cost Explorer is queried from.
- **CE scope** -- what that account can see: org | billing group | self.

If these need pinning permanently, they belong in `CONTEXT.md` alongside Roster,
Access Mode and Coverage Snapshot, with an Avoid list like the others.

---

## Open items

- [ ] Verify `billing:ListBillingViews` is present in AWS managed `ReadOnlyAccess`
      (newer namespace; may lag). If absent, the operator supplies the view ARN
      and nothing else changes.
- [ ] Any new `config.json` keys must be documented in
      `cross-account-defaults.md`. Writing keys `setup-corgiro` never creates is
      an existing defect in `ask` (it reads `defaultRegions`, which is in no
      documented schema) and must not be repeated.
- [ ] `setup-corgiro` should start asking about payer coverage: two modes now
      depend on it. Separate change.
- [ ] `ec2-compute-review` hardcodes `gp2 $0.10/GB`, `gp3 $0.08/GB`,
      `io1 $0.125/GB + $0.065/IOPS` and a flat 20% Graviton figure, us-east-1
      only. Same class of error as the `USE1-NatGateway-Bytes` assumption. It can
      adopt `aws-pricing-grounding.md` and drop the constants.
