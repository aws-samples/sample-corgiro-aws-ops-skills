# Design notes: Corgiro on AWS DevOps Agent

This document is for anyone changing the code in `devops-agent/`. It records why
each choice was made, including the ones that look arbitrary until you hit the
failure they prevent.

For deploying and running, see **[README.md](README.md)**.

## The templates

### One role template, two trust paths

The role template carries up to two trust statements, each switched on by one
parameter:

| `ToolingAccountId` | `AgentSpacePrimaryAccountId` | Result |
|---|---|---|
| set | empty | local CLI only; identical to the pre-DevOps-Agent template |
| empty | set | DevOps Agent only |
| set | set | both targets on one role |
| empty | empty | rejected by the `AtLeastOneTrustPath` rule |

`deploy-infra.sh` only ever deploys the second row. The other combinations exist
for anyone deploying the template directly, and for `setup-corgiro`, which sets
the first.

**Prefer one trust path per role instance.** Two StackSets with distinct
`RoleName` values keeps CloudTrail attribution per consumer: the role ARN alone
tells you whether a call came from the CLI operator, whose session name carries
the operator identity, or from the agent. A shared role makes them
indistinguishable and also attaches `AIDevOpsAgentAccessPolicy` to the CLI path,
which does not need it.

Keeping one file rather than copying it into `devops-agent/` is deliberate:
`DataPlaneDeny` cannot drift between the two targets if there is only one
definition of it.

### `ArnLike` on `agentspace/*` rather than a pinned ARN

Prefer leaving the trust unpinned. `aws:SourceAccount` already blocks every
other AWS account, so pinning only guards against a second Agent Space inside
your own primary account. Restricting `aidevops:CreateAgentSpace` there is one
control instead of one per member account, and it survives the space being
recreated, which a pinned ARN does not. AWS itself provisions `ArnLike` with
`agentspace/*` for the Agent Space role its console creates.

Pinning is also inherently a second pass: the role must exist before an
association can reference it, and the space must exist before its ARN does.
That is why `PIN_AGENT_SPACE` is env-only rather than a prompt - a prompt would
offer an answer guaranteed to abort the very run that creates the space. The
post-apply output advertises it instead, where it is actually possible.

`PIN_AGENT_SPACE` derives the ARN from the stack output rather than accepting
one. There is then no ARN to copy and no way to pin to the wrong space.
`AGENT_SPACE_ARN` is not an input for the same reason: pinning the trust to a
space the stack does not own would mean the role does not trust the space that
actually assumes it, and the associations would break with nothing reporting
why.

### `DataPlaneDeny` is attached unmodified

The agent calls two denied actions during topology discovery, `apigateway:GET`
and `lambda:GetFunction`. No Corgiro mode uses either: the modes reach service
APIs directly rather than traversing the topology graph, which the DevOps Agent
documentation explicitly supports.

So the deny policy ports as-is, and the accepted cost is that topology is blind
to API Gateway and partially blind to Lambda.

`DataPlaneDeny` is load-bearing here rather than defence in depth. The service
applies a permission guardrail whose ceiling includes all of `ReadOnlyAccess`,
so without the explicit Deny the agent could read S3 object contents, DynamoDB
items and KMS plaintext.

**Its `Description` is effectively frozen.** For `AWS::IAM::ManagedPolicy`,
`Description` is replacement-only, and `ManagedPolicyName` is fixed at
`${RoleName}-DataPlaneDeny`. Rewording the description therefore makes
CloudFormation create a second policy with the same name, which fails with
`AlreadyExists` on every existing deployment. If the wording must change, drop
`ManagedPolicyName` so CloudFormation can generate unique names - and accept
that this itself replaces the policy once.

## Input design

The rule: **prompt what genuinely varies per run, take everything else from the
environment, and derive anything the script can work out for itself.**

That yields three prompts in `deploy-infra.sh` (profile, region, target OUs),
plus the post-walk account narrowing and the apply confirmation. Two in
`deploy-assets.sh`. None in `validate.sh`, which is run from a runbook.

### Names are env-only

`STACKSET_NAME`, `STACK_NAME`, `AGENT_SPACE_NAME`, `ROLE_NAME`, and `AGENT_NAME`
are expert overrides. Their defaults are correct unless you are deliberately
running a second parallel deployment, and someone doing that knows to set them.
Each prompt was also a chance to type a `ROLE_NAME` that collides with Corgiro's
local-CLI role.

`STACK_NAME` and `AGENT_SPACE_NAME` stay **independent**, because they name
different things: one is a CloudFormation stack, the other is the Agent Space's
own label. Coupling their defaults would let a stack rename silently rename the
space.

The collision they can produce together is caught by a pre-flight instead. Space
names are **not unique** - the API accepts a second space with an existing name -
so a parallel deployment that overrode only `STACK_NAME` would quietly end up
with two spaces called the same thing. The check fails when a space already
carries the requested name and is not the one the target stack owns:

```
[FAIL] Agent Space  'corgiro-agent-space' already exists as <id>,
       which stack 'corgiro-agent-space-gf' does not own.
```

### `REGION` has no default

Deploying to the wrong region is the most expensive mistake available here. Both
scripts find their targets by name **within one region**, so a different region
does not collide with the existing deployment - it silently builds a second,
parallel one that the first is invisible from.

A shown default invites exactly that by being accepted unread, so the prompt
offers none. Blank takes the profile's own configured region, and if the profile
has none the script stops rather than guessing. Hardcoding a region was the
alternative, but this is a public sample and the port deliberately removed
environment-specific regions.

### Booleans take `yes` or `no`

One convention for `CONFIRM`, `NO_PROMPT` and `PIN_AGENT_SPACE`: `yes` or `no`,
any case, with `y`/`n` accepted as the short form the `[y/N]` prompts take.
Nothing else. `1/0`, `true/false` and `on/off` are rejected.

Three conventions used to coexist. `NO_PROMPT` matched exactly `1`, `CONFIRM`
exactly `yes`, and `PIN_AGENT_SPACE` anything starting with `y`. So
`NO_PROMPT=true` was silently ignored, and `CONFIRM=true` would have run a
silent **dry run** that reported success and changed nothing, leaving you
believing you had deployed.

Validation runs **before** the tty test. `[ -t 0 ] && ! is_yes NO_PROMPT` would
short-circuit whenever stdin is not a terminal, which is exactly the CI case
where a mistyped value most needs catching.

Prompt answers are deliberately different: a prompt shows its options, so
anything other than `y` there simply means no, rather than stopping the run.
Only environment values are validated strictly, because they carry no visible
hint of what is acceptable.

### `CALL_AS` is detected, not asked

There are two valid values and the account decides which. `SELF` is correct only
from the management account; `DELEGATED_ADMIN` only from a registered delegated
administrator. The wrong value is not cosmetic - `describe-stack-set` reports
`StackSetNotFoundException` for a StackSet that plainly exists, so the script
would take the create path and then collide on the role name.

Identity decides `SELF`, and a probe decides `DELEGATED_ADMIN`. That asymmetry
is load-bearing: `list-stack-sets --call-as SELF` **succeeds from any account**,
returning an empty list, so probing it proves nothing. From a non-management
account `SELF` addresses that account's own self-managed StackSets, a different
and usually empty namespace - it would appear to work and target nothing.
`--call-as DELEGATED_ADMIN` does discriminate, because it fails unless the
account is registered.

It is not an input at all, because an override could only ever agree with the
detection: an explicit `SELF` would be accepted only when the caller is the
management account, which is exactly when detection picks `SELF`.

### The Agent Space is identified by its stack, not by an id

`deploy-assets.sh` reads `AgentSpaceId` from the output of the stack named by
`STACK_NAME`. It used to accept `AGENT_SPACE_ID` directly as well, which allowed
assets to be deployed into a space CloudFormation does not manage - the stack
outputs would then describe a different space from the one holding the skill and
the agent, with nothing reporting the mismatch.

`validate.sh` previously took `spaces[0]` from `list-agent-spaces`, which picks
an arbitrary space once the account holds more than one - precisely the
greenfield-test case, where it would have reported on the deployment you were
not testing. It now reads the same stack output, and exits non-zero when it
cannot, so "I could not check" is not mistakeable for "it is fine".

`SKILL_NAME` is hardcoded rather than parameterised. It is the **lookup key**
that finds an existing skill, and it is owned by the `name:` field in
`SKILL.md` - a different value cannot rename anything, only fail to match and
create a duplicate.

## The recurring bug class: a failed query is not an empty result

Five separate bugs in this directory had the same shape. A command that could
not answer the question was treated as having answered "nothing", and the script
then acted on that as fact.

| Swallowed call | Read as | Actually meant | Consequence |
|---|---|---|---|
| `list-organizational-units-for-parent 2>/dev/null` | this OU has no children | no permission to enumerate | nested accounts silently missing |
| `list-assets 2>/dev/null` | no such asset | cannot reach the Agent Space | duplicate-creation attempt |
| `list-agent-spaces 2>/dev/null` | no space has that name | the region has no such service | org-wide role deploy with no Agent Space |
| `describe-organization \|\| echo ''` | no management account | no Organizations read | management account not excluded |
| `os.environ['LOOKBACK_MINUTES']` unset | - | variable never exported | `validate.sh` always exited 1 |

The standing rule for this directory: **do not redirect stderr to `/dev/null` on
a call whose result drives a decision.** Capture it, check the status, and fail
with the AWS error text. Three of these produced a half-deployment rather than
an error, and one caused a passing report for a failing command.

Two related traps:

**Define helpers above their first use.** `say` is not merely undefined if called
early - `/usr/bin/say` exists on macOS as the text-to-speech command, so an
early call exits 0 with no output and `set -e` never fires. A whole `[FAIL]`
block went to the speech synthesiser instead of the terminal. On Linux the same
code dies with `say: command not found`.

**`printf '%s'` drops the trailing newline**, so `read` returns EOF on the final
line and the last item of a loop is silently skipped. Use `printf '%s\n'`. This
cost one child OU on every recursive walk.

## Operational constraints discovered by deploying

**A StackSet runs one operation at a time.** `update-stack-set` followed
immediately by `create-stack-instances` returns `OperationInProgressException`,
so the wait is a reusable function called between operations rather than once at
the end.

The script generates its own `--operation-id` rather than reading one back. That
lets it poll the operation it started, instead of whatever `--max-results 1`
reports as newest, which could be an auto-deployment or someone in the console.
AWS also treats the id as an idempotency token, so a retry with the same id does
not double-apply.

Checking N member accounts for a pre-existing role is impossible - the member
role trusts only `aidevops.amazonaws.com`, so nothing can assume into them to
look. So there is deliberately no role-name collision pre-flight. AWS already
reports per account, and the script's job is to surface that: on `FAILED` or
`STOPPED` it prints each account's status and reason, and on timeout it exits
non-zero rather than reporting success, which would have let template 2 create
associations for roles that may not exist.

**`update-stack-set` only touches instances that already exist.** It does not
create them for accounts newly in scope, so widening the scope needs an explicit
`create-stack-instances` for the difference. The script diffs in-scope accounts
against accounts holding an instance and creates the remainder, with the same
`INTERSECTION` targeting the create path uses - passing explicit accounts is
required for correctness, because bare OU targeting would re-widen a deployment
that `MEMBER_ACCOUNT_IDS` had deliberately narrowed.

**Sequential deployment was caused by `FailureToleranceCount=0`, not by
`MaxConcurrentCount`.** Under the default `ConcurrencyMode=STRICT_FAILURE_TOLERANCE`
the actual concurrency is `min(MaxConcurrentCount, FailureToleranceCount + 1)`,
so a tolerance of zero pins it to one account at a time whatever
`MaxConcurrentCount` says - the original `MaxConcurrentCount=1` was redundant.
A measured CREATE operation took 238 seconds, which sequential execution
multiplies by the account count.

`SOFT_FAILURE_TOLERANCE` decouples them: concurrency stays at
`MaxConcurrentCount` while `FailureToleranceCount=0` still stops the operation
on the first failure. The cost is that up to `MAX_CONCURRENT` accounts are
attempted before the stop rather than exactly one, which is acceptable for a
read-only role because each account independently succeeds or rolls back.

**AWS CLI v2 pipes output through a pager.** `create-stack-instances` printing
`{"OperationId": "..."}` blocked the script on `less`, which looks exactly like
a hang. All scripts `export AWS_PAGER=""`.

**Dry runs cannot catch any of these.** Elided commands never contend for the
StackSet lock, never collide on a resource name, and never reach an unsupported
region. Any test suite for this directory needs an apply mode against a scratch
OU, not just dry runs.

## Two IAM and CloudFormation constraints

Both cost a failed deployment to discover, and neither is caught by
`validate-template`.

**IAM rejects newlines in a policy or role `Description`.** The field is
validated against `[\p{L}\p{M}\p{Z}\p{S}\p{N}\p{P}]*`, which excludes control
characters, and a YAML folded block containing a blank line folds to a literal
newline. Keep every IAM `Description` a single paragraph under 1000 characters.

**CloudFormation caps the template `Description` at 1024 characters**, enforced
during transform processing rather than by `validate-template`. An over-long
description validates cleanly and then fails at create time.

## Known gaps

| Gap | Note |
|---|---|
| No automated tests | and the bug history above argues they need an apply mode, not just dry runs |
| Triggers not handled | `Condition` and `Action` are create-only, so there is no update path for a schedule. `create-trigger` always creates, and re-running would stack duplicates. Handling it properly means listing and deleting first. The shape is documented in a comment in `deploy-assets.sh` |
