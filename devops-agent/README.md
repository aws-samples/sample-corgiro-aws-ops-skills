# Corgiro on AWS DevOps Agent

A second target for the Corgiro skill. The same analysis content runs inside an
AWS DevOps Agent Agent Space instead of on a workstation.

The local CLI target is unchanged. `setup-corgiro` and every mode continue to
work exactly as before.

## Why a second target

| | Local CLI | DevOps Agent |
|---|---|---|
| Runs | on a workstation, on demand | in an Agent Space, on demand or scheduled |
| Credentials | operator assumes the member role | the service assumes it per account |
| Setup | `/corgiro setup-corgiro` | the scripts here |
| Output | self-contained HTML report | DevOps Agent artifact |

Setup here is **scripts only, deliberately**. Requiring `setup-corgiro` would
mean running Corgiro locally in order to configure the target whose purpose is
not running locally.

## What gets created

```
Tooling Account
  operator app role                    humans, for the DevOps Agent web app
  Agent Space
  monitor association   -> its own member role
  source association    -> member account A
  source association    -> member account B        (one per account in scope)

Every account in scope
  CorgiroReadOnlyRole-DevOpsAgent      ReadOnlyAccess
                                       + AIDevOpsAgentAccessPolicy
                                       + <RoleName>-DataPlaneDeny
                                       + inline AllowCreateServiceLinkedRoles

Agent Space assets
  skill         corgiro          imported from this repository
  custom agent  corgiro-agent    system prompt + skills + tools
```

## Layout

```
devops-agent/
  cloudformation/agent-space.yaml     Agent Space, operator role, associations
  custom-agent/
    corgiro-agent-prompt.md           the custom agent's system prompt
    SETUP.md                          creating it by hand, and tool selection
  scripts/
    _common.sh                        shared helpers
    deploy-infra.sh                   member role (StackSet) + Agent Space
    deploy-assets.sh                  skill + custom agent
    validate.sh                       read-only verification
```

The member role is **not** duplicated here. `deploy-infra.sh` deploys Corgiro's
own `skills/corgiro/assets/corgiro-readonly-role.yaml` with the Agent Space
parameters set; `setup-corgiro` deploys the same file with them empty. One
definition, so `DataPlaneDeny` cannot drift between the two targets.

## Design decisions

### One role template, two trust paths

The role template carries up to two trust statements, each switched on by one
parameter:

| `ToolingAccountId` | `AgentSpacePrimaryAccountId` | Result |
|---|---|---|
| set | empty | local CLI only; identical to the pre-DevOps-Agent template |
| empty | set | DevOps Agent only |
| set | set | both targets on one role |
| empty | empty | rejected by the `AtLeastOneTrustPath` rule |

**Prefer one trust path per role instance.** Two StackSets with distinct
`RoleName` values keeps CloudTrail attribution per consumer: the role ARN alone
tells you whether a call came from the CLI operator, whose session name carries
the operator identity, or from the agent. A shared role makes them
indistinguishable and also attaches `AIDevOpsAgentAccessPolicy` to the CLI path,
which does not need it.

### `ArnLike` on `agentspace/*`, not a pinned ARN

Pinning the trust to one Agent Space cannot happen on a first deploy: the role
must exist before an association can reference it, and the space must exist
before its ARN does. It is inherently a second pass:

```bash
./scripts/deploy-infra.sh                        # creates everything, wildcard trust
PIN_AGENT_SPACE=yes CONFIRM=yes ./scripts/deploy-infra.sh   # then narrows it
```

`PIN_AGENT_SPACE` reads the ARN from the Agent Space stack output, so there is
no ARN to copy and no way to pin to the wrong space; it fails with that
instruction if no space exists yet. Pinning is not sticky - the inputs fully
determine the state, so a later run without the flag widens the trust back.
`AGENT_SPACE_ARN` stays as an env-only override for pinning to a space this
script did not create.

Prefer leaving it unpinned. `aws:SourceAccount` already blocks every other AWS account, so
pinning only guards against a second Agent Space inside your own primary
account. Restricting `aidevops:CreateAgentSpace` there is one control instead of
one per member account, and it survives the space being recreated, which a
pinned ARN does not. AWS itself provisions `ArnLike` with `agentspace/*` for the
Agent Space role its console creates.

### `DataPlaneDeny` is attached unmodified

The agent calls two denied actions during topology discovery, `apigateway:GET`
and `lambda:GetFunction`. No Corgiro mode uses either: the modes reach service
APIs directly rather than traversing the topology graph, which the DevOps Agent
documentation explicitly supports.

So the deny policy ports as-is, and the accepted cost is that topology is blind
to API Gateway and partially blind to Lambda. The Agent Space Understanding
memory derived from it is correspondingly incomplete.

`DataPlaneDeny` is also load-bearing here rather than defence in depth. The
service applies a permission guardrail whose ceiling includes all of
`ReadOnlyAccess`, so without the explicit Deny the agent could read S3 object
contents, DynamoDB items and KMS plaintext.

### The Agent Space must be Corgiro-dedicated

The role is attached per account at the **association** level, for the whole
Agent Space, so every agent type uses it: investigations, triage, RCA,
mitigation, chat, release testing. With `logs:GetLogEvents` and
`logs:FilterLogEvents` denied, an incident-investigation agent in the same space
would silently produce log-blind investigations. Do not share the space.

## Prerequisites

### Register GitHub (manual, one-time)

`deploy-assets.sh` imports the skill from a repository URL, which fails with
"No GitHub access is configured for the repository's host" unless a GitHub
service is registered for the account.

Not automated, because the GitHub half cannot be: the App install is browser
OAuth and token creation is manual either way. The registration is
account-level and shared by every Agent Space in the account.

```
DevOps Agent console -> Capabilities -> Pipeline -> Add -> GitHub
  connection type: App registration, as User, Read-only
```

Register against your own GitHub account. Any connection enables importing from
public repositories, so it does not need to cover the repository's owner.

Check whether one already exists:

```bash
aws devops-agent list-services --profile <profile> --region <region>
```

If you ever want this as code, the resource is `AWS::DevOpsAgent::Service` with
`ServiceType: github`. Its `ServiceDetails.GitHub` is a `oneOf`:

| Shape | Required | Result |
|---|---|---|
| `AppVerification` | `TokenValue`, `AppVariant` | `AuthMode: app`. The App must already be installed; the PAT verifies once and is **not stored**. Keeps webhooks. |
| `DirectAccess` | `TokenValue` | `AuthMode: pat`. No App install needed. No webhooks, and the token **is** stored. |

`AppVariant` is `READ_ONLY`, `READ_WRITE` or `CUSTOM_APP`, and must match the
App you installed. The whole `GitHub` property is create-only, so changing the
connection replaces the registration. `ServiceDetails` is write-only, so the
token cannot be read back.

### The Tooling Account

One account holds all three capabilities the deployment needs:

| # | Capability | Why |
|---|---|---|
| 1 | CloudFormation StackSets delegated administrator, or the management account | deploy the member role across the OU. The script detects which applies |
| 2 | Organizations read | derive the member account list |
| 3 | hosts the Agent Space | the Agent Space stack deploys into it |

Because of (3), the Agent Space primary account is **derived** from the
profile's caller identity rather than supplied.

Capability 2 is a **hard prerequisite** and affects the local CLI target too.
Granting `organizations:ListAccounts` in an IAM policy is necessary but not
sufficient: most Organizations read APIs are callable only from the management
account, or from a member account the management account has delegated to via an
**Organizations resource-based policy**. Corgiro cannot provision that, because
only the payer can write it.

The script stops if it cannot read the organization. The OU walk is the only way
to know what is in scope, and it is what `MEMBER_ACCOUNT_IDS` is checked
against, so deploying without it would mean creating associations the script
cannot verify will ever reach status `valid`.

## Deploying

```
step 0   MANUAL               register GitHub (above)
step 1   deploy-infra.sh      member role (StackSet) + Agent Space
step 2   validate.sh          confirm every association reads valid
step 3   deploy-assets.sh     skill + custom agent
```

Both scripts are **dry run by default** and show a plan before asking to apply.
Run with no environment at all and they prompt, with defaults in brackets;
`NO_PROMPT=1` forces the non-interactive path for CI.

```bash
cd devops-agent

TOOLING_PROFILE=<profile> TARGET_OU_IDS=<ou-or-root-id> ./scripts/deploy-infra.sh
TOOLING_PROFILE=<profile> ./scripts/validate.sh
TOOLING_PROFILE=<profile> ./scripts/deploy-assets.sh
```

Order matters in both directions. The role must exist before the associations,
or they never reach status `valid`. The skill must exist before the custom
agent, which references its asset ID; `deploy-assets.sh` handles that
internally.

Wait a few minutes before the first invocation. A newly imported skill is not
loadable immediately, and `skill_read` fails with `Skill not found` until the
service has indexed it.

### Scoping

| Input | Controls |
|---|---|
| `TARGET_OU_IDS` | which accounts get the **role** (StackSet deployment target) |
| `MEMBER_ACCOUNT_IDS` | optional; narrows **both** halves. Prompted after the walk, so you choose from what it found |

`TARGET_OU_IDS` accepts OU ids, the org root, or a comma-separated mix, and
recurses into child OUs because a service-managed StackSet does too.

`MEMBER_ACCOUNT_IDS` **narrows** that result rather than replacing it: the walk
always runs, and anything you list that is not in a target OU is dropped with a
reason. The same list is passed to the StackSet with
`AccountFilterType=INTERSECTION`, so the role and the associations land on
exactly the same accounts.

Two accounts are always excluded from the association list: the Tooling Account,
which gets the monitor association instead, and the management account, which
service-managed StackSets never deploy to.

The Tooling Account must itself be inside `TARGET_OU_IDS`, because it needs the
member role for its own monitor association, and under `INTERSECTION` listing an
account is not enough — it must also belong to a target OU. The pre-flight fails
with the remedy if it does not. For a dedicated tooling OU, name both OUs and
narrow with `MEMBER_ACCOUNT_IDS`:

```bash
TARGET_OU_IDS=<tooling-ou>,<workload-ou>
MEMBER_ACCOUNT_IDS=<the workload accounts you want>
```

### Consistent parameters

All three scripts take `TOOLING_PROFILE`, and all accept `PROFILE` as an alias.
None defaults the profile to a particular account; they refuse to run without
one.

| | `deploy-infra.sh` | `deploy-assets.sh` | `validate.sh` |
|---|---|---|---|
| `TOOLING_PROFILE` | required | required | required |
| `REGION` | `us-east-1` | `us-east-1` | `us-east-1` |
| `AGENT_SPACE_ID` | - | derived from the stack | derived from the space list |
| `MEMBER_ACCOUNT_IDS` | prompted after the OU walk; narrows it | - | - |
| `PIN_AGENT_SPACE` | `N`; `yes` on a second run narrows the role trust | - | - |
| `CALL_AS` | detected, not asked; set it only to override | - | - |
| `CONFIRM=yes` | to apply | to apply | n/a, read-only |

### Capabilities and deletion

| Template | Capabilities |
|---|---|
| `corgiro-readonly-role.yaml` | `CAPABILITY_NAMED_IAM` |
| `agent-space.yaml` | `CAPABILITY_NAMED_IAM` and `CAPABILITY_AUTO_EXPAND` |

`validate-template` reports only `CAPABILITY_AUTO_EXPAND` for the Agent Space
template, because it cannot see past the `AWS::LanguageExtensions` transform.
`CAPABILITY_NAMED_IAM` is still required at deploy time.

Enable termination protection on the Agent Space stack. Deleting it deletes the
Agent Space, which destroys its investigations, memories, assets and history.
It is a `create-stack` parameter, not a template property:

```bash
aws cloudformation update-termination-protection \
  --stack-name <stack> --enable-termination-protection
```

Removing an account from `MEMBER_ACCOUNT_IDS` only removes that association,
which is safe and reversible.

## Known trade-offs

| Accepted | Consequence |
|---|---|
| Topology blind to API Gateway and Lambda | the Understanding memory is incomplete. Fine while skills drive behaviour |
| Topology discovery cannot be disabled | unsolicited API load per associated account, not governed by Corgiro's `maxParallel` ceiling or backoff. A threat T8 regression unique to this target |
| No per-operator CloudTrail attribution | the service assumes the role itself, so CloudTrail shows the agent role. Corgiro's `corgiro-<operator>-<run_id>` session naming (threat T9) is not reproducible, which is why one trust path per role is preferred |
| No self-contained HTML report | artifacts only: text, charts, tables, topology diagrams. No branding, no `report-theme.css`, no badge colours |
| New accounts need a re-run | StackSet auto-deployment gives them the role, but the association list is only re-derived when `deploy-infra.sh` runs |

## Two IAM and CloudFormation constraints worth knowing

Both cost a failed deployment to discover, and neither is caught by
`validate-template`.

**IAM rejects newlines in a policy or role `Description`.** The field is
validated against `[\p{L}\p{M}\p{Z}\p{S}\p{N}\p{P}]*`, which excludes control
characters, and a YAML folded block containing a blank line folds to a literal
newline. Keep every IAM `Description` a single paragraph under 1000 characters.

**CloudFormation caps the template `Description` at 1024 characters**, enforced
during transform processing rather than by `validate-template`. An over-long
description validates cleanly and then fails at create time.

## Security Hub findings this produces

In an account with AWS Foundational Security Best Practices enabled, expect two
MEDIUM findings per stack. Both are CloudFormation stack hygiene, unrelated to
the role or the agent.

| Control | Checks | StackSet instance stacks | Agent Space stack |
|---|---|---|---|
| CloudFormation.4 | stack has an IAM service role | not fixable | fixable with a deployment role |
| CloudFormation.3 | termination protection enabled | not fixable | fixable, see above |

StackSets expose neither for instance stacks, which is why AWS's own Control
Tower baseline stacks fail both controls. Suppress or accept them.

### `CALL_AS` is detected, not asked

There are two valid values and the account decides which, so the script works it
out. `SELF` is correct only from the management account; `DELEGATED_ADMIN` only
from a registered delegated administrator. The wrong value is not cosmetic -
`describe-stack-set` reports `StackSetNotFoundException` for a StackSet that
plainly exists, so the script would take the create path and then collide on the
role name.

Identity decides `SELF`, and a probe decides `DELEGATED_ADMIN`. That asymmetry is
deliberate: `list-stack-sets --call-as SELF` **succeeds from any account**,
returning an empty list, so probing it proves nothing. From a non-management
account `SELF` addresses that account's own self-managed StackSets, a different
and usually empty namespace - it would appear to work and target nothing.
`--call-as DELEGATED_ADMIN` does discriminate, because it fails unless the
account is registered.

Setting `CALL_AS` explicitly skips detection, and is then verified rather than
trusted: `CALL_AS=SELF` from a non-management account is rejected.
