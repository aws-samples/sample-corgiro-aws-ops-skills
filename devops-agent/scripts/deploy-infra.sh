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
# The OU walk always runs and always determines what is in scope.
# MEMBER_ACCOUNT_IDS, when supplied, is INTERSECTED against its result - it
# narrows the scope, it does not replace it. Organizations read is therefore a
# hard prerequisite, not optional.
#
# This script deploys the DevOps Agent trust path only. The member role template
# also supports Corgiro's local-CLI trust path, which setup-corgiro deploys with
# its own parameters; keeping them on separate roles preserves CloudTrail
# attribution per consumer.
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
#
# This assignment sits BEFORE the ask on purpose, so the ask sees the value as
# already set and skips its prompt. That is the only legitimate reason to assign
# a prompted variable outside its `ask`: aliasing another NAME. A default must
# live in exactly one place - the ask's third argument - because `ask` already
# covers all three cases (env set, answered, blank or non-interactive). A second
# `${VAR:-default}` is dead code that silently disagrees the moment one changes.
TOOLING_PROFILE="${TOOLING_PROFILE:-${PROFILE:-}}"
ask TOOLING_PROFILE                "AWS profile for the Tooling Account"
ask REGION                         "Region" "us-east-1"
ask TARGET_OU_IDS                  "Target OU or root IDs (comma-separated)"
ask PIN_AGENT_SPACE                "Pin role trust to this Agent Space only? (y/N)" "N"

# Naming: env-only expert overrides, not questions. The defaults are correct
# unless you are deliberately running a second, parallel deployment - and
# someone doing that knows to set them. Prompting for four names that are almost
# always accepted unchanged is friction, and each prompt is a chance to type a
# ROLE_NAME that collides with Corgiro's local-CLI role.
STACKSET_NAME="${STACKSET_NAME:-corgiro-readonly-devops-agent}"
STACK_NAME="${STACK_NAME:-corgiro-agent-space}"
ROLE_NAME="${ROLE_NAME:-CorgiroReadOnlyRole-DevOpsAgent}"
# Independent of STACK_NAME on purpose: one names a CloudFormation stack, the
# other is the Agent Space's own label. Coupling their defaults would let a
# stack rename silently rename the space. The collision they can produce
# together is caught by a pre-flight check instead.
AGENT_SPACE_NAME="${AGENT_SPACE_NAME:-corgiro-agent-space}"

need TOOLING_PROFILE "Set TOOLING_PROFILE (or PROFILE) to a profile for the Tooling Account."
need REGION          "Set REGION."
need TARGET_OU_IDS   "Set TARGET_OU_IDS, e.g. ou-xxxx-xxxxxxxx or the org root r-xxxx."

PROFILE="$TOOLING_PROFILE"

# Not an input. PIN_AGENT_SPACE derives it from the stack output, which is the
# only coherent source: pinning the role's trust to an Agent Space the stack
# does not own means the role would not trust the space that actually assumes
# it, and the associations would break with nothing reporting why. Same reason
# deploy-assets.sh stopped accepting AGENT_SPACE_ID.
AGENT_SPACE_ARN=""

# Not an input either. Detected in the pre-flight, and an override could only
# ever agree with it: an explicit SELF was accepted only when the caller is the
# management account, which is exactly when detection picks SELF, and an
# explicit DELEGATED_ADMIN only when the probe succeeds, which is exactly when
# detection picks that. 22 lines to reach the same answer.
CALL_AS=""

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

# ------------------------------------------------ pre-flight on the Tooling Account
# All three capabilities belong to the one designated account, so verify them
# here and derive the Agent Space primary from the same identity.
step "pre-flight: Tooling Account via profile '${TOOLING_PROFILE}'"

AGENT_SPACE_PRIMARY_ACCOUNT_ID="$(aws sts get-caller-identity --profile "$TOOLING_PROFILE" \
  --query Account --output text 2>/dev/null || echo '')"
[ -n "$AGENT_SPACE_PRIMARY_ACCOUNT_ID" ] || {
  say "  cannot authenticate with profile '${TOOLING_PROFILE}'" >&2; exit 1; }
say "  Tooling Account = Agent Space primary = ${AGENT_SPACE_PRIMARY_ACCOUNT_ID}"

# 1. Organizations read - a hard prerequisite, not optional.
#
# Probe the API whose RESULT this script depends on, and keep that result. It
# used to probe list-roots, which the script never calls anywhere else, while
# describe-organization - the one it does use - was allowed to fail silently
# behind `|| echo ''`. That mattered twice over: an empty MGMT_ACCOUNT makes
# SELF unreachable even when correct, and stops the management account being
# excluded from the association list, which with TARGET_OU_IDS set to the org
# root creates an association that can never reach status valid.
#
# The walk's own two APIs report their own failures; neither swallows errors now.
if ! MGMT_ACCOUNT="$(aws organizations describe-organization --profile "$TOOLING_PROFILE" \
     --region "$REGION" --query 'Organization.MasterAccountId' --output text 2>&1)"; then
  say "  [FAIL] Organizations    cannot read the organization." >&2
  say "         ${MGMT_ACCOUNT}" >&2
  say "" >&2
  say "         This is a prerequisite. Granting organizations:ListAccounts in an" >&2
  say "         IAM policy is necessary but not sufficient: most Organizations" >&2
  say "         read APIs are callable only from the management account, or from" >&2
  say "         an account the payer has delegated to via an Organizations" >&2
  say "         resource-based policy." >&2
  say "" >&2
  say "         Either run from the management account, or ask the payer to" >&2
  say "         delegate Organizations read to the Tooling Account. See item 0 in" >&2
  say "         CORGIRO-CHANGES-NEEDED.md for the exact policy." >&2
  exit 1
fi
case "$MGMT_ACCOUNT" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) say "  [FAIL] Organizations    unexpected management account id:" >&2
     say "         '${MGMT_ACCOUNT}'" >&2
     exit 1 ;;
esac
say "  [ok]   Organizations    read access present"

# 2. StackSet administration, and which call-as this account must use.
#
# Not worth asking: there are two valid answers and the account decides which.
# The wrong one is not cosmetic - describe-stack-set reports
# StackSetNotFoundException for a StackSet that plainly exists.
#
# SELF is valid ONLY from the management account. This script creates
# SERVICE_MANAGED StackSets, which live in the management account and are
# otherwise reached through a delegated administrator; SELF from anywhere else
# addresses that account's own self-managed StackSets - a different, usually
# empty namespace. That is why identity decides SELF rather than a probe:
# `list-stack-sets --call-as SELF` SUCCEEDS from any account (returning an empty
# list), so probing it proves nothing. `--call-as DELEGATED_ADMIN` does
# discriminate - it fails unless the account is registered.
# MGMT_ACCOUNT came from the gate above, where it is validated, so it can be
# compared directly rather than defensively.
_is_mgmt=0
[ "$AGENT_SPACE_PRIMARY_ACCOUNT_ID" = "$MGMT_ACCOUNT" ] && _is_mgmt=1

_probe_delegated() {
  aws cloudformation list-stack-sets --profile "$TOOLING_PROFILE" --region "$REGION" \
    --call-as DELEGATED_ADMIN >/dev/null 2>&1
}

if [ "$_is_mgmt" -eq 1 ]; then
  CALL_AS=SELF
  say "  [ok]   StackSet admin   --call-as SELF (management account)"
elif _probe_delegated; then
  CALL_AS=DELEGATED_ADMIN
  say "  [ok]   StackSet admin   --call-as DELEGATED_ADMIN (delegated administrator)"
else
  say "  [FAIL] StackSet admin   this account is neither the management account" >&2
  say "         nor a registered StackSets delegated administrator." >&2
  say "         Register it as a CloudFormation StackSets delegated" >&2
  say "         administrator, or run from the management account." >&2
  exit 1
fi

# 3. Agent Space name collision.
#
# Space names are NOT unique - the API accepts a second space with an existing
# name - so creating one is not self-policing. STACK_NAME and AGENT_SPACE_NAME
# are independent, which is correct, but it means a parallel deployment that
# overrides only the stack name would quietly produce two spaces called the
# same thing, and anything matching by name then breaks.
#
# A collision is: a space already carries this name, and it is not the one this
# stack owns.
_this_space="$("${CFN[@]}" describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='AgentSpaceId'].OutputValue" \
  --output text 2>/dev/null || echo '')"
_named_space="$(aws devops-agent list-agent-spaces --profile "$TOOLING_PROFILE" \
  --region "$REGION" --output json 2>/dev/null |
  N="$AGENT_SPACE_NAME" python3 -c '
import sys, json, os
n = os.environ["N"]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for s in d.get("agentSpaces") or []:
    if s.get("name") == n:
        print(s.get("agentSpaceId") or ""); break
' || echo '')"

if [ -n "$_named_space" ] && [ "$_named_space" != "${_this_space}" ]; then
  say "  [FAIL] Agent Space     '${AGENT_SPACE_NAME}' already exists as" >&2
  say "         ${_named_space}, which stack '${STACK_NAME}' does not own." >&2
  say "" >&2
  say "         Space names are not unique, so deploying would create a SECOND" >&2
  say "         space with the same name and anything matching by name would" >&2
  say "         then break." >&2
  say "" >&2
  say "         Set AGENT_SPACE_NAME to something else, or set STACK_NAME to the" >&2
  say "         stack that already owns that space." >&2
  exit 1
fi
say "  [ok]   Agent Space     '${AGENT_SPACE_NAME}' is free or already ours"

# ------------------------------------------------- derive the member account list
#
# Walks the OU tree RECURSIVELY. A service-managed StackSet targeting an OU
# deploys into its child OUs as well, so a flat list-accounts-for-parent would
# leave nested accounts holding the role with no association - silently narrower
# coverage that nothing surfaces.
collect_accounts() {
  local parent="$1" child out kids
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

  # Same reasoning for the recursion, which used to send its error to
  # /dev/null. That made a permissions failure indistinguishable from "this OU
  # has no children", so coverage came out NARROWER with nothing reported:
  # nested accounts simply went missing.
  if ! kids="$("${ORG[@]}" list-organizational-units-for-parent --parent-id "$parent" \
                --query 'OrganizationalUnits[].Id' --output text 2>&1)"; then
    say "  cannot list child OUs of '${parent}':" >&2
    say "    ${kids}" >&2
    return 1
  fi
  while read -r child; do
    if [ -n "$child" ]; then
      collect_accounts "$child" || return 1
    fi
  # printf '%s\n', not '%s': without the trailing newline `read` returns EOF on
  # the final line, so the LAST child OU was silently skipped - the same
  # narrower-coverage failure this block exists to prevent.
  done < <(printf '%s\n' "$kids" | tr '\t' '\n')
  # Explicit: without it the function inherits the status of its last body
  # command, which for a childless OU is a failed test.
  return 0
}

# The OU walk ALWAYS runs. MEMBER_ACCOUNT_IDS, when supplied, is intersected
# against its result rather than replacing it.
#
# It used to bypass the walk, which let an account outside TARGET_OU_IDS through.
# That produced a silent half-deployment: AWS applies
# AccountFilterType=INTERSECTION to the StackSet, so the out-of-OU account got no
# role, but template 2 still created its association - which then never reached
# status "valid" and nothing surfaced why.
REQUESTED="${MEMBER_ACCOUNT_IDS:-}"

# MGMT_ACCOUNT was resolved during pre-flight, where it also ordered the
# call-as probe. Service-managed StackSets never deploy to the management
# account, so including it would create an association pointing at a role that
# does not exist. Matters when TARGET_OU_IDS is the org root.

RAW=()
IFS=',' read -r -a OUS <<< "$TARGET_OU_IDS"
for ou in "${OUS[@]}"; do
  case "$ou" in
    r-*|ou-*) ;;
    *) say "'${ou}' is not an OU or root id." >&2
       say "  Expected a root like 'r-abcd' or an OU like 'ou-abcd-1a2b3c4d'." >&2
       say "  List them with:" >&2
       say "    aws organizations list-roots --profile ${TOOLING_PROFILE}" >&2  # discovery aid
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
  say "  Check the id is correct and that the OU actually contains accounts." >&2
  exit 1
fi

# De-duplicate and classify. A string seen-set avoids expanding a possibly-empty
# array, which is an unbound-variable error under `set -u` on bash 3.2 (macOS).
WALKED=" "; ACCTS=(); SKIPPED=()
for a in "${RAW[@]}"; do
  case "$WALKED" in *" $a "*) continue ;; esac
  WALKED="${WALKED}${a} "
  if [ "$a" = "$AGENT_SPACE_PRIMARY_ACCOUNT_ID" ]; then
    SKIPPED+=("$a (Tooling Account - gets the monitor association)"); continue
  fi
  if [ -n "$MGMT_ACCOUNT" ] && [ "$a" = "$MGMT_ACCOUNT" ]; then
    SKIPPED+=("$a (management - service-managed StackSets skip it)"); continue
  fi
  ACCTS+=("$a")
done

# The Tooling Account needs the role, because the Agent Space's monitor
# association points at it. Under INTERSECTION, adding it to the Accounts list
# achieves nothing unless it is ALSO inside TARGET_OU_IDS - so verify, and fail
# with the remedy rather than deploying an association that cannot validate.
case "$WALKED" in
  *" ${AGENT_SPACE_PRIMARY_ACCOUNT_ID} "*) ;;
  *) say "" >&2
     say "[FAIL] The Tooling Account ${AGENT_SPACE_PRIMARY_ACCOUNT_ID} is not in any OU" >&2
     say "       under ${TARGET_OU_IDS}." >&2
     say "" >&2
     say "       It needs the member role, because the Agent Space's monitor" >&2
     say "       association points at it. Under AccountFilterType=INTERSECTION," >&2
     say "       listing it is not enough - it must also belong to a target OU." >&2
     say "" >&2
     say "       Add the OU containing it to TARGET_OU_IDS. If you do not want the" >&2
     say "       role in that OU's other accounts, narrow with MEMBER_ACCOUNT_IDS:" >&2
     say "         TARGET_OU_IDS=<tooling-ou>,<workload-ou>" >&2
     say "         MEMBER_ACCOUNT_IDS=<the accounts you actually want>" >&2
     exit 1 ;;
esac

# Report the walk BEFORE prompting, so the choice is made with the result in
# view - including what was excluded and why - rather than typing ids blind.
say "member accounts: walked ${TARGET_OU_IDS} recursively, found ${#RAW[@]}, using ${#ACCTS[@]}"
if [ "${#SKIPPED[@]}" -gt 0 ]; then
  for x in "${SKIPPED[@]}"; do say "  skipped ${x}"; done
fi

if [ -z "$REQUESTED" ] && [ "$INTERACTIVE" -eq 1 ]; then
  say ""
  say "  Leave blank to associate all ${#ACCTS[@]}, or enter a comma-separated subset."
  ask REQUESTED "Narrow to specific accounts" ""
fi

ACCOUNTS_SUPPLIED=0
[ -n "$REQUESTED" ] && ACCOUNTS_SUPPLIED=1

if [ "$ACCOUNTS_SUPPLIED" -eq 1 ]; then
  # Intersect the supplied list with the walk. Anything outside it is dropped
  # here, so the association list matches what the StackSet will actually reach.
  KEPT=(); DROPPED=()
  IFS=',' read -r -a WANT <<< "$REQUESTED"
  for a in "${WANT[@]}"; do
    a="$(printf '%s' "$a" | tr -d '[:space:]')"       # tolerate "a, b"
    [ -n "$a" ] || continue
    case "$a" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
      *) say "'${a}' is not a 12-digit account id." >&2; exit 1 ;;
    esac
    if [ "$a" = "$AGENT_SPACE_PRIMARY_ACCOUNT_ID" ]; then
      DROPPED+=("$a (Tooling Account - gets the monitor association)"); continue
    fi
    if [ -n "$MGMT_ACCOUNT" ] && [ "$a" = "$MGMT_ACCOUNT" ]; then
      DROPPED+=("$a (management - service-managed StackSets skip it)"); continue
    fi
    case "$WALKED" in
      *" $a "*) KEPT+=("$a") ;;
      *) DROPPED+=("$a (not in any OU under ${TARGET_OU_IDS})") ;;
    esac
  done
  MEMBER_ACCOUNT_IDS="$(IFS=,; echo "${KEPT[*]:-}")"
  say "member accounts: ${#WANT[@]} requested, intersected with the OU walk, using ${#KEPT[@]}"
  if [ "${#DROPPED[@]}" -gt 0 ]; then
    for x in "${DROPPED[@]}"; do say "  dropped ${x}"; done
  fi
else
  MEMBER_ACCOUNT_IDS="$(IFS=,; echo "${ACCTS[*]:-}")"
fi

[ -n "$MEMBER_ACCOUNT_IDS" ] || { say "no member accounts resolved; template 2 needs at least one" >&2; exit 1; }

# ------------------------------------------------------ resolve the trust scope
# Pinning is inherently a SECOND-pass action: the role must exist before an
# association can reference it, and the Agent Space must exist before its ARN
# does. So the first run always uses the wildcard, and a later run can narrow it.
case "$PIN_AGENT_SPACE" in
  [yY]*)
    AGENT_SPACE_ARN="$("${CFN[@]}" describe-stacks --stack-name "$STACK_NAME" \
      --query "Stacks[0].Outputs[?OutputKey=='AgentSpaceArn'].OutputValue" \
      --output text 2>/dev/null || echo '')"
    if [ -z "$AGENT_SPACE_ARN" ] || [ "$AGENT_SPACE_ARN" = "None" ]; then
      say "" >&2
      say "[FAIL] Cannot pin: no Agent Space exists yet." >&2
      say "       Stack '${STACK_NAME}' has no AgentSpaceArn output, so there is" >&2
      say "       nothing to pin the role trust to." >&2
      say "" >&2
      say "       Run once WITHOUT pinning to create the Agent Space, then re-run" >&2
      say "       with PIN_AGENT_SPACE=yes to narrow the trust." >&2
      exit 1
    fi
    say "  pin: derived the Agent Space ARN from stack '${STACK_NAME}'" ;;
esac

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
if [ -n "$AGENT_SPACE_ARN" ]; then
  say " Role trust scope   : pinned to one Agent Space"
else
  say " Role trust scope   : any Agent Space in this account and region (recommended)"
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

# Template 2 deploys into the Tooling Account, which is the Agent Space host -
# the same account and region as CFN, since PROFILE is set from TOOLING_PROFILE.

T2_OP=create
if "${CFN[@]}" describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
  T2_OP=update
  say "  exists -> update-stack"
  if [ "$DRY" -eq 1 ]; then
    run "${CFN[@]}" update-stack --stack-name "$STACK_NAME" --template-body "file://${T2}" \
      --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND --parameters "${T2_PARAMS[@]}"
  else
    run_update "${CFN[@]}" update-stack \
      --stack-name "$STACK_NAME" --template-body "file://${T2}" \
      --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
      --parameters "${T2_PARAMS[@]}" >/dev/null
    [ "$NOOP" -eq 1 ] && T2_OP=noop
  fi
else
  say "  not found -> create-stack (with termination protection)"
  # Termination protection is a create-stack parameter, not a template property.
  # Deleting this stack deletes the Agent Space and all of its data.
  run "${CFN[@]}" create-stack \
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
      "${CFN[@]}" wait stack-create-complete --stack-name "$STACK_NAME" ;;
    update)
      say "  waiting for stack update..."
      "${CFN[@]}" wait stack-update-complete --stack-name "$STACK_NAME" ;;
    noop)
      say "  nothing to wait for" ;;
  esac
  ST="$("${CFN[@]}" describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text)"
  case "$ST" in
    CREATE_COMPLETE|UPDATE_COMPLETE) say "  stack status: ${ST}" ;;
    *) say "  stack status: ${ST} - not a successful terminal state; stopping." >&2; exit 1 ;;
  esac
  AGENT_SPACE_ID="$("${CFN[@]}" describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='AgentSpaceId'].OutputValue" --output text)"
  [ -n "$AGENT_SPACE_ID" ] && [ "$AGENT_SPACE_ID" != "None" ] || {
    say "  could not read the AgentSpaceId output; stopping." >&2; exit 1; }
  say
  say "=============================================================="
  say " Agent Space ID: ${AGENT_SPACE_ID}"
  say
  say " Next:  ./scripts/deploy-assets.sh   (it reads this id from the stack)"
  say "=============================================================="
else
  say
  say "=============================================================="
  if [ "$CONFIRM_PROMPTED" -eq 0 ] && [ "$INTERACTIVE" -eq 1 ]; then
    say " Nothing was changed - you answered no at the apply prompt."
  else
    say " Nothing was changed. Re-run with CONFIRM=yes to apply."
  fi
  say " Then:  ./scripts/deploy-assets.sh"
  say "=============================================================="
fi
