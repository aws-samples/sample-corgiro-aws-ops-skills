# Corgiro on AWS DevOps Agent

A second target for the Corgiro skill. The same analysis content runs inside an
AWS DevOps Agent Agent Space instead of on a workstation.

The local CLI target is unchanged. `setup-corgiro` and every mode continue to
work exactly as before.

This document is for the person deploying and running it. The reasoning behind
the design choices lives in **[DESIGN.md](DESIGN.md)**.

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

The member role is **not** duplicated here. `deploy-infra.sh` deploys Corgiro's
own `skills/corgiro/assets/corgiro-readonly-role.yaml` with the Agent Space
parameters set; `setup-corgiro` deploys the same file with them empty. One
definition, so `DataPlaneDeny` cannot drift between the two targets.

## Prerequisites

Five things must be true before `deploy-infra.sh` will get anywhere. The first
four are checked by its pre-flight and reported individually; the fifth is a
manual step only `deploy-assets.sh` needs.

### 1. The region must support AWS DevOps Agent

The Agent Space is regional and the service is not in every region. Check
before you deploy:

```bash
aws cloudformation list-types --region <region> \
  --visibility PUBLIC --filters TypeNamePrefix=AWS::DevOpsAgent
```

An empty list means that region cannot host an Agent Space. Deploying there
fails in a particularly unhelpful way, because IAM is global: the StackSet
succeeds and puts the member role in every account in scope, then the Agent
Space stack dies with `Unrecognized resource types`. The pre-flight now stops
before the StackSet for exactly this reason.

### 2. One account holding three capabilities

| # | Capability | Why |
|---|---|---|
| 1 | CloudFormation StackSets delegated administrator, or the management account | deploy the member role across the OU. The script detects which applies |
| 2 | Organizations read | derive the member account list, and identify the management account |
| 3 | hosts the Agent Space | the Agent Space stack deploys into it |

Because of (3), the Agent Space primary account is **derived** from the
profile's caller identity rather than supplied.

Capability 2 is a **hard prerequisite** and affects the local CLI target too. An
IAM grant is necessary but not sufficient: most Organizations read APIs are
callable only from the management account, or from a member account the
management account has delegated to via an **Organizations resource-based
policy**. Corgiro cannot provision that, because only the payer can write it.
The script stops if it cannot read the organization, rather than deploying
associations it has no way to verify.

### 3. Organizations trusted access for StackSets

Service-managed StackSets require it. Control Tower enables it for you; a plain
organization does not.

```bash
aws organizations list-aws-service-access-for-organization \
  --query "EnabledServicePrincipals[].ServicePrincipal"
```

Look for `member.org.stacksets.cloudformation.amazonaws.com`. Without it,
`create-stack-set` fails.

### 4. IAM permissions for the profile

These are the actions the scripts actually call. The DevOps Agent prefix is
`aidevops:`, not `devops-agent:`.

| Service | Actions | Used by |
|---|---|---|
| `sts` | `GetCallerIdentity` | all three |
| `organizations` | `DescribeOrganization`, `ListAccountsForParent`, `ListOrganizationalUnitsForParent` | deploy-infra |
| `cloudformation` | `ListStackSets`, `DescribeStackSet`, `CreateStackSet`, `UpdateStackSet`, `CreateStackInstances`, `ListStackInstances`, `ListStackSetOperations`, `DescribeStacks`, `CreateStack`, `UpdateStack` | deploy-infra |
| `cloudformation` | `DescribeStacks` | deploy-assets, validate |
| `aidevops` | `ListAgentSpaces` | deploy-infra pre-flight, validate |
| `aidevops` | `ListAssets`, `CreateAsset`, `UpdateAsset` | deploy-assets |
| `aidevops` | `ListAssociations` | validate |
| `aidevops` | `CreateAgentSpace`, `CreateAssociation`, `AssociateService` | granted to CloudFormation, which creates these resources |
| `iam` | `GetRole`, `ListAttachedRolePolicies`, `ListRolePolicies` | validate |
| `cloudtrail` | `LookupEvents` | validate |

`CAPABILITY_NAMED_IAM` covers the role and policy creation inside the member
accounts, which the StackSet execution role performs rather than your profile.

### 5. Register GitHub (manual, one-time)

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

### A constraint, not a prerequisite: the Agent Space must be Corgiro-dedicated

The role is attached per account at the **association** level, for the whole
Agent Space, so every agent type uses it: investigations, triage, RCA,
mitigation, chat, release testing. With `logs:GetLogEvents` and
`logs:FilterLogEvents` denied, an incident-investigation agent in the same space
would silently produce log-blind investigations. Do not share the space.

## Deploying

```
step 0   MANUAL               register GitHub (above)
step 1   deploy-infra.sh      member role (StackSet) + Agent Space
step 2   validate.sh          confirm every association reads valid
step 3   deploy-assets.sh     skill + custom agent
```

Both deploy scripts are **dry run by default** and show a plan before asking to
apply. Run them with no environment at all and they prompt.

```bash
cd devops-agent

TOOLING_PROFILE=<profile> TARGET_OU_IDS=<ou-or-root-id> ./scripts/deploy-infra.sh
TOOLING_PROFILE=<profile> ./scripts/validate.sh
TOOLING_PROFILE=<profile> ./scripts/deploy-assets.sh
```

Add `CONFIRM=yes` to apply. Order matters in both directions: the role must
exist before the associations or they never reach status `valid`, and the skill
must exist before the custom agent that references its asset ID.

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
account is not enough - it must also belong to a target OU. The pre-flight fails
with the remedy if it does not. For a dedicated tooling OU, name both OUs and
narrow with `MEMBER_ACCOUNT_IDS`:

```bash
TARGET_OU_IDS=<tooling-ou>,<workload-ou>
MEMBER_ACCOUNT_IDS=<the workload accounts you want>
```

### Parameters

All three scripts take `TOOLING_PROFILE`, and all accept `PROFILE` as an alias.
None defaults the profile to a particular account; they refuse to run without
one.

| | `deploy-infra.sh` | `deploy-assets.sh` | `validate.sh` |
|---|---|---|---|
| `TOOLING_PROFILE` | required | required | required |
| `REGION` | blank = the profile's own region | blank = the profile's own region | blank = the profile's own region |
| `TARGET_OU_IDS` | required | - | - |
| `MEMBER_ACCOUNT_IDS` | prompted after the OU walk; narrows it | - | - |
| `STACK_NAME` | `corgiro-agent-space` | `corgiro-agent-space` | `corgiro-agent-space` |
| `STACKSET_NAME` | `corgiro-readonly-devops-agent` | - | - |
| `AGENT_SPACE_NAME` | `corgiro-agent-space` | - | - |
| `ROLE_NAME` | `CorgiroReadOnlyRole-DevOpsAgent` | - | `CorgiroReadOnlyRole-DevOpsAgent` |
| `AGENT_NAME` | - | `corgiro-agent` | - |
| `PIN_AGENT_SPACE` | `no`; `yes` on a second run narrows the role trust | - | - |
| `LOOKBACK_MINUTES` | - | - | `60` |
| `CONFIRM` | `yes` to apply | `yes` to apply | n/a, read-only |
| `NO_PROMPT` | `yes` forces the non-interactive path | same | n/a, no prompts |

Derived, never inputs: `CALL_AS`, `AGENT_SPACE_ARN`, `AGENT_SPACE_ID`, the
management account id, and the Agent Space primary account.

Three behaviours worth knowing:

**`REGION` has no default.** Blank takes the profile's own configured region. If
the profile has none either, the script stops rather than guessing, because a
wrong region silently builds a second parallel deployment the first cannot see.

**Booleans take `yes` or `no`**, any case, with `y`/`n` accepted. `1/0`,
`true/false` and `on/off` are rejected rather than guessed at, so a typo stops
the run instead of being read as "no".

**Names are env-only.** `STACKSET_NAME`, `STACK_NAME`, `AGENT_SPACE_NAME`,
`ROLE_NAME`, `AGENT_NAME` are not prompted. Their defaults are right unless you
are deliberately running a second parallel deployment, in which case set them
explicitly - including both `STACK_NAME` and `AGENT_SPACE_NAME`, which are
independent.

### Capabilities and deletion

| Template | Capabilities |
|---|---|
| `corgiro-readonly-role.yaml` | `CAPABILITY_NAMED_IAM` |
| `agent-space.yaml` | `CAPABILITY_NAMED_IAM` and `CAPABILITY_AUTO_EXPAND` |

`validate-template` reports only `CAPABILITY_AUTO_EXPAND` for the Agent Space
template, because it cannot see past the `AWS::LanguageExtensions` transform.
`CAPABILITY_NAMED_IAM` is still required at deploy time.

The script enables termination protection on the Agent Space stack. Deleting it
deletes the Agent Space, which destroys its investigations, memories, assets and
history. To remove it deliberately:

```bash
aws cloudformation update-termination-protection \
  --stack-name <stack> --no-enable-termination-protection
aws cloudformation delete-stack --stack-name <stack>
```

Removing an account from `MEMBER_ACCOUNT_IDS` only removes that association,
which is safe and reversible.

To tear down the role as well, delete the stack instances before the StackSet:

```bash
aws cloudformation delete-stack-instances --stack-set-name <stackset> \
  --call-as DELEGATED_ADMIN --deployment-targets OrganizationalUnitIds=<ou> \
  --regions <region> --no-retain-stacks
# wait for the instance count to reach 0, then
aws cloudformation delete-stack-set --stack-set-name <stackset> \
  --call-as DELEGATED_ADMIN
```

## Operating notes

Things that cost a failed deployment to discover.

**A StackSet runs one operation at a time.** Starting a second while the first
is in flight returns `OperationInProgressException`. The script waits between
its own operations; if you run it concurrently with a console operation on the
same StackSet, one of them will fail.

**`update-stack-set` does not add accounts.** It only touches instances that
already exist. Widening the scope - dropping a `MEMBER_ACCOUNT_IDS` filter, or
adding an OU - therefore needs `create-stack-instances` as well, which the
script now does automatically and reports in the plan as `in scope but with no
instance yet`.

**Changing an IAM `Description` replaces the policy.** For
`AWS::IAM::ManagedPolicy`, `Description` is replacement-only, and
`DataPlaneDeny` has a fixed `ManagedPolicyName`. So rewording that description
makes CloudFormation try to create a second policy with the same name, which
fails with `AlreadyExists` for every existing deployment. Treat the field as
frozen.

**The Agent Space stack always updates.** `agent-space.yaml` uses
`AWS::LanguageExtensions`, so it looks changed on every resubmission. A real
update with no diff is expected, not a signal.

**IAM is global, Agent Spaces are regional.** This is why a wrong region
half-deploys rather than failing cleanly, and why the role can outlive a
rolled-back Agent Space stack.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Unrecognized resource types: [AWS::DevOpsAgent::AgentSpace, ...]` | the region does not support AWS DevOps Agent. See prerequisite 1 |
| `Could not connect to the endpoint URL: https://cp.aidevops.<region>...` | same, caught earlier by the pre-flight |
| `OperationInProgressException` | another StackSet operation is still running. Wait and re-run |
| `A policy called <role>-DataPlaneDeny already exists` | the policy `Description` changed, forcing replacement of a named resource |
| An association stuck at `pending-confirmation` | the account has no role. Usually scope widened without new stack instances; re-run `deploy-infra.sh` |
| `StackSetNotFoundException` for a StackSet you can see in the console | wrong region, or wrong `--call-as`. Both scripts find targets by name within one region |
| The script appears to hang after printing `{"OperationId": ...}` | an older copy without `AWS_PAGER=""`; output went to `less`. Press `q` |
| `Skill not found` on first invocation | a newly imported skill is not loadable for a few minutes |
| `No GitHub access is configured for the repository's host` | prerequisite 5 |

## Known trade-offs

| Accepted | Consequence |
|---|---|
| Topology blind to API Gateway and Lambda | the Understanding memory is incomplete. Fine while skills drive behaviour |
| Topology discovery cannot be disabled | unsolicited API load per associated account, not governed by Corgiro's `maxParallel` ceiling or backoff. A threat T8 regression unique to this target |
| No per-operator CloudTrail attribution | the service assumes the role itself, so CloudTrail shows the agent role. Corgiro's `corgiro-<operator>-<run_id>` session naming (threat T9) is not reproducible, which is why one trust path per role is preferred |
| No self-contained HTML report | artifacts only: text, charts, tables, topology diagrams. No branding, no `report-theme.css`, no badge colours |
| New accounts need a re-run | an account that **joins** a target OU gets the role from StackSet auto-deployment, but its association is only created when `deploy-infra.sh` runs. An account already in the OU but excluded by a filter gets neither until you re-run |

## Security Hub findings this produces

In an account with AWS Foundational Security Best Practices enabled, expect two
MEDIUM findings per stack. Both are CloudFormation stack hygiene, unrelated to
the role or the agent.

| Control | Checks | StackSet instance stacks | Agent Space stack |
|---|---|---|---|
| CloudFormation.4 | stack has an IAM service role | not fixable | fixable with a deployment role |
| CloudFormation.3 | termination protection enabled | not fixable | fixable, enabled by the script |

StackSets expose neither for instance stacks, which is why AWS's own Control
Tower baseline stacks fail both controls. Suppress or accept them.

## Layout

```
devops-agent/
  README.md                           this file: deploying and running
  DESIGN.md                           why it is built this way
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
