#!/usr/bin/env bash
#
# Deploy the Corgiro DevOps Agent infrastructure layer, in order:
#
#   template 1  1-member-role.yaml      service-managed StackSet -> every account in the OU
#   template 2  2-agent-space.yaml      single stack             -> primary account only
#
# Why one script: the two templates share values that must not drift.
#   ROLE_NAME   -> template 1 RoleName   AND   template 2 MemberRoleName
#   the OU      -> template 1 deployment target AND template 2 MemberAccountIds
#
# CloudFormation cannot link them itself. Fn::ImportValue is same-account and
# same-region only, so the primary account cannot import from member-account
# instances; StackSet instance stack names carry a service-generated UUID, so
# the export name is not predictable; and MemberAccountIds is a property of the
# OU, not of any stack, so no output could ever supply it.
#
# MemberAccountIds is derived from the OU automatically (minus the primary
# account) unless you override it.
#
# The GitHub service registration is NOT handled here. It is a one-time,
# account-level, partly-manual prerequisite - the GitHub App install and token
# creation cannot be automated - so it stays a documented manual step. See the
# README Prerequisites section, which also records the AWS::DevOpsAgent::Service
# shape if you ever want to provision it as code across many accounts.
#
# DRY RUN BY DEFAULT. Set CONFIRM=yes to apply.
#
set -euo pipefail

# ---------------------------------------------------------------------- inputs
#
# Every value can come from the environment. Anything still unset is PROMPTED
# when stdin is a TTY, with the default in brackets - press Enter to accept.
# Set NO_PROMPT=1 to force the non-interactive path (CI), where unset required
# values are a hard error.
#
# TOOLING_PROFILE must resolve to the **Tooling Account**, which by design holds
# all three capabilities this script needs:
#
#   1. CloudFormation StackSets delegated administrator  (or the management
#      account itself, with CALL_AS=SELF)
#   2. Organizations read, delegated by the payer via an Organizations
#      resource-based policy - used to derive the member account list
#   3. host of the DevOps Agent Agent Space
#
# Because of (3), the Agent Space primary account is DERIVED from this profile's
# caller identity rather than supplied. There is no separate PRIMARY_PROFILE.
#
# The Tooling Account is simply the account Corgiro operates FROM, in either
# mode - it holds the CorgiroOperator identity for the local CLI, and/or hosts
# the Agent Space. Normally the same account, and normally only one mode is
# active, because a user picks local CLI or DevOps Agent rather than both.
#
# ONE MODE PER ROLE. This script refuses to put both trust paths on a single
# member role. If you want both, deploy twice with a different ROLE_NAME and
# STACKSET_NAME. Reasons, in order of weight:
#
#   1. CloudTrail attribution. Separate role names let you tell from the role ARN
#      alone which consumer made a call - the local CLI operator (whose session
#      name is corgiro-<operator>-<run_id>) or the agent. A shared role makes
#      that indistinguishable, losing Corgiro's threat T9 attribution.
#   2. Least privilege. AIDevOpsAgentAccessPolicy and the Resource Explorer
#      service-linked-role grant belong only on the agent's role. A shared role
#      hands them to the CLI path, which does not need them.
#   3. No bypass. With both paths on one role, anyone able to create an Agent
#      Space in the Tooling Account reaches every member account through the
#      agentspace/* trust without needing the external ID. One path per role
#      leaves nothing to bypass.
#
# Template 1 itself still supports all three combinations; this is a deployment
# policy, not a template limitation.

INTERACTIVE=0
[ -t 0 ] && [ "${NO_PROMPT:-0}" != "1" ] && INTERACTIVE=1

# ask VAR "prompt" [default] [secret]
ask() {
  local var="$1" prompt="$2" def="${3:-}" secret="${4:-}" cur val
  cur="${!var:-}"
  [ -n "$cur" ] && return 0                       # environment always wins
  if [ "$INTERACTIVE" -eq 0 ]; then
    [ -n "$def" ] && eval "$var=\$def"
    return 0
  fi
  # `|| true` matters: read returns non-zero at EOF, and under `set -e` that
  # kills the script with no message - e.g. when stdin closes mid-prompt.
  if [ -n "$secret" ]; then
    read -rsp "  ${prompt}: " val || true; echo
  elif [ -n "$def" ]; then
    read -rp "  ${prompt} [${def}]: " val || true; val="${val:-$def}"
  else
    read -rp "  ${prompt}: " val || true
  fi
  eval "$var=\$val"
}

need() {  # need VAR "hint"
  [ -n "${!1:-}" ] || { printf '%s\n' "$1 is required. $2" >&2; exit 1; }
}

[ "$INTERACTIVE" -eq 1 ] && printf '\nCorgiro DevOps Agent infrastructure - press Enter to accept defaults\n\n'

# PROFILE is accepted as an alias of TOOLING_PROFILE across all three scripts.
TOOLING_PROFILE="${TOOLING_PROFILE:-${PROFILE:-}}"
ask TOOLING_PROFILE                "AWS profile for the Tooling Account"
ask REGION                         "Region" "us-east-1"
ask TARGET_OU_IDS                  "Target OU or root IDs (comma-separated)"
ask ROLE_NAME                      "Member role name" "CorgiroReadOnlyRole-DevOpsAgent"
ask CALL_AS                        "StackSet call-as (DELEGATED_ADMIN or SELF)" "DELEGATED_ADMIN"
ask AGENT_SPACE_NAME               "Agent Space name" "corgiro-agent-space"

need TOOLING_PROFILE "Set TOOLING_PROFILE (or PROFILE) to a profile for the Tooling Account."
need REGION          "Set REGION."
need TARGET_OU_IDS   "Set TARGET_OU_IDS, e.g. ou-xxxx-xxxxxxxx or the org root r-xxxx."

PROFILE="$TOOLING_PROFILE"

STACKSET_NAME="${STACKSET_NAME:-corgiro-readonly-devops-agent}"
STACK_NAME="${STACK_NAME:-corgiro-agent-space}"
TOOLING_ACCOUNT_ID="${TOOLING_ACCOUNT_ID:-}"
EXTERNAL_ID="${EXTERNAL_ID:-}"
PERMISSION_SET_NAME_PREFIX="${PERMISSION_SET_NAME_PREFIX:-CorgiroOperator}"
OPERATOR_ROLE_NAME="${OPERATOR_ROLE_NAME:-}"
AGENT_SPACE_ARN="${AGENT_SPACE_ARN:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The member role is Corgiro's own template, shared with the local CLI
# target. Deployed here with the Agent Space parameters set; setup-corgiro
# deploys the same file with them empty, which renders the role Corgiro has
# always created.
T1="${SCRIPT_DIR}/../../skills/corgiro/assets/corgiro-readonly-role.yaml"
T2="${SCRIPT_DIR}/../cloudformation/agent-space.yaml"

CFN=(aws cloudformation --profile "$PROFILE" --region "$REGION")
ORG=(aws organizations --profile "$PROFILE" --region "$REGION")
# Dry run unless CONFIRM=yes. When interactive and CONFIRM is unset, the plan
# banner below asks instead, so you decide with the facts in front of you.
DRY=1; [ "${CONFIRM:-no}" = "yes" ] && DRY=0
CONFIRM_PROMPTED=0

say()  { printf '%s\n' "$*"; }

# CloudFormation returns a non-zero ValidationError saying "No updates are to be
# performed" when an update would change nothing. Under `set -e` that aborts the
# script, so a clean re-run would look like a failure. Swallow only that case and
# report it; let every other error propagate.
#
# NOTE: template 2 uses the AWS::LanguageExtensions transform, and a transformed
# template appears changed on every resubmission, so CloudFormation accepts the
# update rather than reporting a no-op. Verified twice against the live stack:
# both times it ran a real (harmless) UPDATE of the AgentSpace resource. So this
# handler is defensive for template 1's update-stack-set and for any
# non-transform stack, and will rarely fire for template 2. Re-running the script
# is therefore not free: it performs a real stack update each time.
NOOP=0
run_update() {
  local out rc
  NOOP=0
  set +e
  out="$("$@" 2>&1)"; rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    if grep -qi "No updates are to be performed" <<< "$out"; then
      say "  no changes to apply"
      NOOP=1
      return 0
    fi
    say "$out" >&2
    return $rc
  fi
  printf '%s\n' "$out"
}
step() { printf '\n--- %s ---\n' "$*"; }
# Echo the command in dry-run with long arguments elided and secrets redacted.
# A GitHub PAT is shorter than the elision threshold, so it must be matched by
# name as well, or a dry run leaks the token to stdout and shell history.
redact() {
  local a="$1"
  case "$a" in
    *GitHubPat,ParameterValue=*|*ExternalId,ParameterValue=*)
      printf '%s' "${a%%,ParameterValue=*},ParameterValue=<redacted>" ; return ;;
    ghp_*|github_pat_*|ghs_*|ghu_*)
      printf '%s' '<redacted-token>' ; return ;;
  esac
  if [ "${#a}" -gt 110 ]; then printf "'%s...<%s chars>'" "${a:0:90}" "${#a}"
  else printf '%s' "$a"; fi
}
run()  {
  if [ "$DRY" -eq 1 ]; then
    local out="" a
    for a in "$@"; do out+=" $(redact "$a")"; done
    say "  DRY-RUN would run:${out}"
  else
    "$@"
  fi
}

if [ -n "$TOOLING_ACCOUNT_ID" ] && [ -z "$EXTERNAL_ID" ]; then
  say "EXTERNAL_ID is required when TOOLING_ACCOUNT_ID is set (template 1 rule" >&2
  say "ExternalIdRequiredWithToolingAccount would reject the deploy)." >&2
  exit 1
fi

# ---- one mode per role -----------------------------------------------------
# This script always deploys template 2, so the role it creates always carries
# the DevOps Agent trust path. Adding the Corgiro operator path on top would put
# both on one role, which is refused - see the header for why.
if [ -n "${TOOLING_ACCOUNT_ID:-}" ]; then
  if [ "${ALLOW_BOTH_TRUST_PATHS:-0}" = "1" ]; then
    say "ALLOW_BOTH_TRUST_PATHS=1 - proceeding with both trust paths on one role."
    say "  CloudTrail will not distinguish the CLI operator from the agent."
  else
  cat >&2 <<EOF

Refusing to put both trust paths on one member role.

  TOOLING_ACCOUNT_ID is set, which adds the Corgiro operator (local CLI) trust,
  and this script always deploys the Agent Space, which adds the DevOps Agent
  trust. That single role would then be usable by both consumers.

  Deploy them separately instead, with distinct names:

    # DevOps Agent target (this script)
    TOOLING_PROFILE=${TOOLING_PROFILE} TARGET_OU_IDS=${TARGET_OU_IDS} \\
      ROLE_NAME=CorgiroReadOnlyRole-DevOpsAgent \\
      STACKSET_NAME=corgiro-readonly-devops-agent \\
      ./scripts/deploy-infra.sh

    # Local Corgiro CLI target - use Corgiro's own setup, which also writes
    # ~/.corgiro/config.json and the roster:
    #   /corgiro setup-corgiro
    # or deploy cloudformation/1-member-role.yaml alone with
    #   RoleName=CorgiroReadOnlyRole  AgentSpacePrimaryAccountId=(empty)

  Why: separate role names keep CloudTrail attribution per consumer, keep
  AIDevOpsAgentAccessPolicy off the CLI role, and leave no external-ID bypass.

  Override with ALLOW_BOTH_TRUST_PATHS=1 if you have a specific reason.

EOF
    exit 1
  fi
fi

# ------------------------------------------------ pre-flight on the Tooling Account
# All three capabilities belong to the one designated account, so verify them
# here and derive the Agent Space primary from the same identity.
step "pre-flight: Tooling Account via profile '${TOOLING_PROFILE}'"

AGENT_SPACE_PRIMARY_ACCOUNT_ID="$(aws sts get-caller-identity --profile "$TOOLING_PROFILE" \
  --query Account --output text 2>/dev/null || echo '')"
[ -n "$AGENT_SPACE_PRIMARY_ACCOUNT_ID" ] || {
  say "  cannot authenticate with profile '${TOOLING_PROFILE}'" >&2; exit 1; }
say "  Tooling Account = Agent Space primary = ${AGENT_SPACE_PRIMARY_ACCOUNT_ID}"

# 1. StackSet administration
if aws cloudformation list-stack-sets --profile "$TOOLING_PROFILE" --region "$REGION" \
     --call-as "$CALL_AS" >/dev/null 2>&1; then
  say "  [ok]   StackSet admin   (--call-as ${CALL_AS})"
else
  say "  [FAIL] StackSet admin   cannot list stack sets with --call-as ${CALL_AS}." >&2
  say "         Register the Tooling Account as a CloudFormation StackSets" >&2
  say "         delegated administrator, or run from the management account" >&2
  say "         with CALL_AS=SELF." >&2
  exit 1
fi

# 2. Organizations read - only needed when deriving the member list
if [ -n "${MEMBER_ACCOUNT_IDS:-}" ]; then
  say "  [skip] Organizations    MEMBER_ACCOUNT_IDS supplied, no org read needed"
elif aws organizations list-roots --profile "$TOOLING_PROFILE" --region "$REGION" >/dev/null 2>&1; then
  say "  [ok]   Organizations    read access present"
else
  say "  [FAIL] Organizations    cannot read the organization." >&2
  say "         The payer must delegate Organizations read to the Tooling Account" >&2
  say "         via an Organizations resource-based policy - see item 0 in" >&2
  say "         CORGIRO-CHANGES-NEEDED.md. Or pass" >&2
  say "         MEMBER_ACCOUNT_IDS=<comma-separated> to skip the derivation." >&2
  exit 1
fi


# ------------------------------------------------- derive the member account list
#
# Walks the OU tree RECURSIVELY. A service-managed StackSet targeting an OU
# deploys into its child OUs as well, so a flat list-accounts-for-parent would
# leave nested accounts holding the role with no association - silently narrower
# coverage that nothing surfaces.
collect_accounts() {
  local parent="$1" child out
  # Do NOT swallow the error here: a wrong OU id yields
  # ParentNotFoundException, and hiding it leaves the user staring at a bash
  # message about an empty array instead of the actual problem.
  if ! out="$("${ORG[@]}" list-accounts-for-parent --parent-id "$parent" \
               --query 'Accounts[?Status==`ACTIVE`].Id' --output text 2>&1)"; then
    say "  cannot list accounts under '${parent}':" >&2
    say "    ${out}" >&2
    return 1
  fi
  printf '%s\n' "$out" | tr '\t' '\n'
  while read -r child; do
    [ -n "$child" ] && collect_accounts "$child"
  done < <("${ORG[@]}" list-organizational-units-for-parent --parent-id "$parent" \
             --query 'OrganizationalUnits[].Id' --output text 2>/dev/null | tr '\t' '\n')
}

# When MEMBER_ACCOUNT_IDS is supplied it scopes BOTH halves of the deployment:
# the StackSet uses AccountFilterType=INTERSECTION to deploy the role only to
# those accounts within TARGET_OU_IDS, and template 2 associates exactly the
# same set. Without it, the role goes to every account in the OU tree and the
# association list is derived from that tree.
if [ -n "${MEMBER_ACCOUNT_IDS:-}" ]; then
  ACCOUNTS_SUPPLIED=1
  say "member accounts: supplied via MEMBER_ACCOUNT_IDS"
  say "  StackSet will use AccountFilterType=INTERSECTION to match"
else
  ACCOUNTS_SUPPLIED=0
  # Service-managed StackSets never deploy to the organization's management
  # account, so including it would create an association pointing at a role
  # that does not exist. Matters when TARGET_OU_IDS is the org root.
  MGMT_ACCOUNT="$("${ORG[@]}" describe-organization \
                    --query 'Organization.MasterAccountId' --output text 2>/dev/null || echo '')"

  RAW=()
  IFS=',' read -r -a OUS <<< "$TARGET_OU_IDS"
  for ou in "${OUS[@]}"; do
    case "$ou" in
      r-*|ou-*) ;;
      *) say "'${ou}' is not an OU or root id." >&2
         say "  Expected a root like 'r-abcd' or an OU like 'ou-abcd-1a2b3c4d'." >&2
         say "  List them with:" >&2
         say "    aws organizations list-roots --profile ${TOOLING_PROFILE}" >&2
         say "    aws organizations list-organizational-units-for-parent \\" >&2
         say "      --parent-id <root-id> --profile ${TOOLING_PROFILE}" >&2
         exit 1 ;;
    esac
    # Capture first, then loop. Attaching `||` to the while loop conflates two
    # different things: a `while read` returns the status of its last body
    # command, so an EMPTY OU looked like an enumeration FAILURE.
    if ! _found="$(collect_accounts "$ou")"; then
      say "stopping: could not enumerate '${ou}'." >&2
      exit 1
    fi
    while read -r a; do
      if [ -n "$a" ]; then RAW+=("$a"); fi
    done <<< "$_found"
  done

  # Empty-array expansion is an unbound-variable error under `set -u` on
  # bash 3.2, so check the count before the loop rather than inside it.
  if [ "${#RAW[@]}" -eq 0 ]; then
    say "No active accounts found under: ${TARGET_OU_IDS}" >&2
    say "  Check the id is correct and that the OU actually contains accounts," >&2
    say "  or pass MEMBER_ACCOUNT_IDS=<comma-separated> explicitly." >&2
    exit 1
  fi

  ACCTS=(); SKIPPED=(); SEEN=" "
  for a in "${RAW[@]}"; do
    # De-duplicate: an account can be reached once per target OU. A string
    # seen-set avoids expanding a possibly-empty array, which is an
    # unbound-variable error under `set -u` on bash 3.2 (macOS default).
    case "$SEEN" in *" $a "*) continue ;; esac
    SEEN="${SEEN}${a} "
    if [ "$a" = "$AGENT_SPACE_PRIMARY_ACCOUNT_ID" ]; then
      SKIPPED+=("$a (primary - gets the monitor association)"); continue
    fi
    if [ -n "$MGMT_ACCOUNT" ] && [ "$a" = "$MGMT_ACCOUNT" ]; then
      SKIPPED+=("$a (management - service-managed StackSets skip it)"); continue
    fi
    ACCTS+=("$a")
  done

  MEMBER_ACCOUNT_IDS="$(IFS=,; echo "${ACCTS[*]}")"
  say "member accounts: walked ${TARGET_OU_IDS} recursively, found ${#RAW[@]}, using ${#ACCTS[@]}"
  if [ "${#SKIPPED[@]}" -gt 0 ]; then
    for x in "${SKIPPED[@]}"; do say "  skipped ${x}"; done
  fi
fi

[ -n "$MEMBER_ACCOUNT_IDS" ] || { say "no member accounts resolved; template 2 needs at least one" >&2; exit 1; }

# Service-managed StackSets accept explicit account IDs alongside OUs.
# INTERSECTION deploys only to the listed accounts WITHIN the given OUs, which
# keeps the role and the associations on exactly the same account set.
if [ "${ACCOUNTS_SUPPLIED:-0}" -eq 1 ]; then
  # The Tooling Account is not in MemberAccountIds - it gets the monitor
  # association instead - but it still needs the role, so add it here.
  DEPLOY_ACCOUNTS="${MEMBER_ACCOUNT_IDS},${AGENT_SPACE_PRIMARY_ACCOUNT_ID}"
  DEPLOY_TARGETS="OrganizationalUnitIds=${TARGET_OU_IDS},Accounts=${DEPLOY_ACCOUNTS},AccountFilterType=INTERSECTION"
else
  DEPLOY_TARGETS="OrganizationalUnitIds=${TARGET_OU_IDS}"
fi

say "=============================================================="
say " Region             : ${REGION}        Tooling profile: ${TOOLING_PROFILE}   Call-as: ${CALL_AS}"
say " Member role name   : ${ROLE_NAME}"
say " Target OU(s)       : ${TARGET_OU_IDS}"
if [ "${ACCOUNTS_SUPPLIED:-0}" -eq 1 ]; then
  say " StackSet scope     : INTERSECTION with the account list below"
else
  say " StackSet scope     : every account in the OU tree"
fi
say " Tooling Account    : ${AGENT_SPACE_PRIMARY_ACCOUNT_ID}  (also the Agent Space host)"
say " Member accounts    : ${MEMBER_ACCOUNT_IDS}"
if [ -n "$TOOLING_ACCOUNT_ID" ]; then
  say " Trust paths        : corgiro-operator + devops-agent (tooling ${TOOLING_ACCOUNT_ID})"
else
  say " Trust paths        : devops-agent only"
fi
say " Mode               : $([ "$DRY" -eq 1 ] && echo 'DRY RUN' || echo APPLY)"
say "=============================================================="

# Ask once, here, where the plan is already on screen. The environment still
# wins: an explicit CONFIRM=yes or NO_PROMPT=1 skips this entirely.
if [ "$DRY" -eq 1 ] && [ "$INTERACTIVE" -eq 1 ] && [ -z "${CONFIRM:-}" ]; then
  _apply=""
  read -rp "
Apply these changes? [y/N]: " _apply || true     # EOF -> empty -> treated as No
  case "$_apply" in
    [yY]*) DRY=0; CONFIRM_PROMPTED=1; say "  applying." ;;
    *)     say "  dry run - showing what would happen, changing nothing." ;;
  esac
elif [ "$DRY" -eq 1 ]; then
  say " (dry run; set CONFIRM=yes to apply)"
fi

# ------------------------------------------------------ template 1, as a StackSet
step "template 1: StackSet ${STACKSET_NAME}"

T1_PARAMS=(
  "ParameterKey=RoleName,ParameterValue=${ROLE_NAME}"
  "ParameterKey=AgentSpacePrimaryAccountId,ParameterValue=${AGENT_SPACE_PRIMARY_ACCOUNT_ID}"
  "ParameterKey=AgentSpaceRegion,ParameterValue=${REGION}"
  "ParameterKey=AgentSpaceArn,ParameterValue=${AGENT_SPACE_ARN}"
  "ParameterKey=ToolingAccountId,ParameterValue=${TOOLING_ACCOUNT_ID}"
  "ParameterKey=ExternalId,ParameterValue=${EXTERNAL_ID}"
  "ParameterKey=PermissionSetNamePrefix,ParameterValue=${PERMISSION_SET_NAME_PREFIX}"
  "ParameterKey=OperatorRoleName,ParameterValue=${OPERATOR_ROLE_NAME}"
)

if "${CFN[@]}" describe-stack-set --stack-set-name "$STACKSET_NAME" --call-as "$CALL_AS" >/dev/null 2>&1; then
  say "  exists -> update-stack-set (also refreshes instances in the OU)"
  STACKSET_UPDATED=1
  run "${CFN[@]}" update-stack-set \
    --stack-set-name "$STACKSET_NAME" --template-body "file://${T1}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --auto-deployment "Enabled=true,RetainStacksOnAccountRemoval=false" \
    --call-as "$CALL_AS" \
    --deployment-targets "$DEPLOY_TARGETS" \
    --regions "$REGION" \
    --operation-preferences "FailureToleranceCount=0,MaxConcurrentCount=1" \
    --parameters "${T1_PARAMS[@]}"
else
  say "  not found -> create-stack-set + create-stack-instances"
  run "${CFN[@]}" create-stack-set \
    --stack-set-name "$STACKSET_NAME" --template-body "file://${T1}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --permission-model SERVICE_MANAGED \
    --auto-deployment "Enabled=true,RetainStacksOnAccountRemoval=false" \
    --call-as "$CALL_AS" \
    --parameters "${T1_PARAMS[@]}"
  run "${CFN[@]}" create-stack-instances \
    --stack-set-name "$STACKSET_NAME" \
    --deployment-targets "$DEPLOY_TARGETS" \
    --regions "$REGION" --call-as "$CALL_AS" \
    --operation-preferences "FailureToleranceCount=0,MaxConcurrentCount=1"
fi

if [ "$DRY" -eq 0 ]; then
  say "  waiting for the StackSet operation to finish..."
  for _ in $(seq 1 60); do
    OP="$("${CFN[@]}" list-stack-set-operations --stack-set-name "$STACKSET_NAME" \
           --call-as "$CALL_AS" --max-results 1 \
           --query 'Summaries[0].{Id:OperationId,Status:Status}' --output json)"
    ST="$(python3 -c "import json,sys;print(json.load(sys.stdin)['Status'])" <<< "$OP")"
    say "    ${ST}"
    case "$ST" in SUCCEEDED) break ;; FAILED|STOPPED) say "  StackSet operation ${ST}; stopping." >&2; exit 1 ;; esac
    sleep 15
  done
  say "  per-account result:"
  "${CFN[@]}" list-stack-instances --stack-set-name "$STACKSET_NAME" --call-as "$CALL_AS" --output json |
  python3 -c "
import sys, json
for s in sorted(json.load(sys.stdin)['Summaries'], key=lambda x: x['Account']):
    print(f\"    {s['Account']}  {s['Status']}\")"
fi

# --------------------------------------------------------- template 2, as a stack
# MemberRoleName is taken from ROLE_NAME, so it cannot drift from the value
# template 1 used - that is the whole reason both templates live in one script.
step "template 2: stack ${STACK_NAME} in ${AGENT_SPACE_PRIMARY_ACCOUNT_ID}"

T2_PARAMS=(
  "ParameterKey=MemberAccountIds,ParameterValue=\"${MEMBER_ACCOUNT_IDS}\""
  "ParameterKey=MemberRoleName,ParameterValue=${ROLE_NAME}"
  "ParameterKey=AgentSpaceName,ParameterValue=${AGENT_SPACE_NAME}"
)

# Template 2 deploys into the Tooling Account, which is the Agent Space host.
CFN2=(aws cloudformation --profile "$TOOLING_PROFILE" --region "$REGION")

T2_OP=create
if "${CFN2[@]}" describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
  T2_OP=update
  say "  exists -> update-stack"
  if [ "$DRY" -eq 1 ]; then
    run "${CFN2[@]}" update-stack --stack-name "$STACK_NAME" --template-body "file://${T2}" \
      --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND --parameters "${T2_PARAMS[@]}"
  else
    run_update "${CFN2[@]}" update-stack \
      --stack-name "$STACK_NAME" --template-body "file://${T2}" \
      --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
      --parameters "${T2_PARAMS[@]}" >/dev/null
    [ "$NOOP" -eq 1 ] && T2_OP=noop
  fi
else
  say "  not found -> create-stack (with termination protection)"
  # Termination protection is a create-stack parameter, not a template property.
  # Deleting this stack deletes the Agent Space and all of its data.
  run "${CFN2[@]}" create-stack \
    --stack-name "$STACK_NAME" --template-body "file://${T2}" \
    --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
    --enable-termination-protection \
    --parameters "${T2_PARAMS[@]}"
fi

if [ "$DRY" -eq 0 ]; then
  # Wait on the operation we actually performed. Chaining the two waiters with
  # `|| true` hides a genuine create failure and then prints an empty Agent
  # Space ID, so branch explicitly instead.
  case "$T2_OP" in
    create)
      say "  waiting for stack create..."
      "${CFN2[@]}" wait stack-create-complete --stack-name "$STACK_NAME" ;;
    update)
      say "  waiting for stack update..."
      "${CFN2[@]}" wait stack-update-complete --stack-name "$STACK_NAME" ;;
    noop)
      say "  nothing to wait for" ;;
  esac
  ST="$("${CFN2[@]}" describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text)"
  case "$ST" in
    CREATE_COMPLETE|UPDATE_COMPLETE) say "  stack status: ${ST}" ;;
    *) say "  stack status: ${ST} - not a successful terminal state; stopping." >&2; exit 1 ;;
  esac
  AGENT_SPACE_ID="$("${CFN2[@]}" describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='AgentSpaceId'].OutputValue" --output text)"
  [ -n "$AGENT_SPACE_ID" ] && [ "$AGENT_SPACE_ID" != "None" ] || {
    say "  could not read the AgentSpaceId output; stopping." >&2; exit 1; }
  say
  say "=============================================================="
  say " Agent Space ID: ${AGENT_SPACE_ID}"
  say
  say " Next:  AGENT_SPACE_ID=${AGENT_SPACE_ID} ./scripts/deploy-assets.sh"
  say "=============================================================="
else
  say
  say "=============================================================="
  if [ "$CONFIRM_PROMPTED" -eq 0 ] && [ "$INTERACTIVE" -eq 1 ]; then
    say " Nothing was changed - you answered no at the apply prompt."
  else
    say " Nothing was changed. Re-run with CONFIRM=yes to apply."
  fi
  say " Then:  AGENT_SPACE_ID=<output> ./scripts/deploy-assets.sh"
  say "=============================================================="
fi
