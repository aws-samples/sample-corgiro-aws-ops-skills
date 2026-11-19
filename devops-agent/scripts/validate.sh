#!/usr/bin/env bash
#
# Read-only verification of a Corgiro DevOps Agent Space.
# Makes no changes. Safe to run repeatedly.
#
# Usage:
#   TOOLING_PROFILE=<profile> ./scripts/validate.sh
#   TOOLING_PROFILE=<profile> STACK_NAME=<stack> ROLE_NAME=<role> ./scripts/validate.sh
#
# This is an operational inspection tool, NOT a test suite. It answers "is the
# deployment healthy right now" - association status, role shape, and what the
# deny policy actually blocked. Automated tests are a separate, deferred piece
# of work.
#
set -euo pipefail

# Aligned with the other scripts: TOOLING_PROFILE, with PROFILE as an alias.
TOOLING_PROFILE="${TOOLING_PROFILE:-${PROFILE:-}}"
: "${TOOLING_PROFILE:?set TOOLING_PROFILE (a profile for the Tooling Account)}"
PROFILE="$TOOLING_PROFILE"
# No default: inspecting the wrong region silently reports on a different,
# parallel deployment. Take the profile's own region, and stop if it has none.
REGION="${REGION:-$(aws configure get region --profile "$PROFILE" 2>/dev/null || echo '')}"
if [[ -z "$REGION" ]]; then
  echo "Cannot determine the region." >&2
  echo "  Profile '${PROFILE}' has no region configured. Either set REGION=<region>" >&2
  echo "  for this run, or: aws configure set region <region> --profile ${PROFILE}" >&2
  exit 1
fi
# Default matches what deploy-infra.sh creates. The bare "CorgiroReadOnlyRole"
# is Corgiro's local-CLI role, so defaulting to it would silently inspect the
# wrong role and report a missing deny policy.
ROLE_NAME="${ROLE_NAME:-CorgiroReadOnlyRole-DevOpsAgent}"
# The Agent Space is identified by its stack, not by a pasted id - same single
# identifier the two deploy scripts use.
STACK_NAME="${STACK_NAME:-corgiro-agent-space}"
LOOKBACK_MINUTES="${LOOKBACK_MINUTES:-60}"

AWSX=(aws --profile "$PROFILE" --region "$REGION")

hr() { printf '%s\n' "------------------------------------------------------------"; }

hr
echo "1. Caller identity"
hr
"${AWSX[@]}" sts get-caller-identity --output json

hr
echo "2. Agent Spaces"
hr
"${AWSX[@]}" devops-agent list-agent-spaces --output json

# Identify the space by the STACK that created it, exactly as deploy-assets.sh
# does. This used to take spaces[0] from list-agent-spaces, which picks an
# ARBITRARY space once the account holds more than one - precisely the
# greenfield-test case, where it would have reported on the deployment you were
# not testing and looked like a result for the one you were.
AGENT_SPACE_ID="$(
  "${AWSX[@]}" cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='AgentSpaceId'].OutputValue" \
    --output text 2>/dev/null || echo ''
)"
if [[ -z "$AGENT_SPACE_ID" || "$AGENT_SPACE_ID" == "None" ]]; then
  echo
  echo "Could not read AgentSpaceId from stack '${STACK_NAME}'."
  echo "  Set STACK_NAME if the Agent Space stack is named differently, or"
  echo "  deploy first with ./scripts/deploy-infra.sh"
  # Exit non-zero: "I could not check" must not be mistakeable for "it is fine".
  exit 1
fi
echo "Agent Space ${AGENT_SPACE_ID} (from stack '${STACK_NAME}')"

hr
echo "3. Associations for ${AGENT_SPACE_ID}"
echo "   Every account should read status=valid."
hr
"${AWSX[@]}" devops-agent list-associations \
  --agent-space-id "$AGENT_SPACE_ID" --output json |
python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = []
for a in d.get('associations', []):
    cfg = a.get('configuration', {})
    inner = cfg.get('aws') or cfg.get('sourceAws') or {}
    rows.append((
        inner.get('accountId', '-'),
        inner.get('accountType', a.get('serviceId', '-')),
        a.get('status', '-'),
        (inner.get('assumableRoleArn') or '-').split('/')[-1],
    ))
header = ('account', 'type', 'status', 'role')
if not rows:
    print('  (no associations)')
else:
    w = [max(len(str(r[i])) for r in rows + [header]) for i in range(4)]
    fmt = '  {:<%d}  {:<%d}  {:<%d}  {:<%d}' % tuple(w)
    print(fmt.format(*header))
    print(fmt.format(*['-' * n for n in w]))
    for r in rows:
        print(fmt.format(*[str(x) for x in r]))
"

hr
echo "4. Local role: ${ROLE_NAME} (this account only)"
hr
if "${AWSX[@]}" iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "trust policy (sts:ExternalId redacted):"
  # Corgiro rule: never display the external ID. It is not categorically secret
  # - it appears in the role's own AssumeRolePolicyDocument and iam:GetRole
  # returns it to anyone with IAM read in the account - but narrowing who reads
  # it is still worthwhile, and it must never land in logs or terminal history.
  "${AWSX[@]}" iam get-role --role-name "$ROLE_NAME" \
    --query 'Role.AssumeRolePolicyDocument' --output json |
  python3 -c "
import sys, json

def scrub(node):
    if isinstance(node, dict):
        return {
            k: ('<redacted>' if k == 'sts:ExternalId' else scrub(v))
            for k, v in node.items()
        }
    if isinstance(node, list):
        return [scrub(x) for x in node]
    return node

print(json.dumps(scrub(json.load(sys.stdin)), indent=4))
"
  echo
  echo "attached managed policies:"
  "${AWSX[@]}" iam list-attached-role-policies --role-name "$ROLE_NAME" \
    --query 'AttachedPolicies[].PolicyName' --output json
  echo
  echo "inline policies:"
  "${AWSX[@]}" iam list-role-policies --role-name "$ROLE_NAME" \
    --query 'PolicyNames' --output json
  echo
  echo "expected after template 1 with an Agent Space configured:"
  echo "  managed : ReadOnlyAccess, AIDevOpsAgentAccessPolicy, ${ROLE_NAME}-DataPlaneDeny"
  echo "  inline  : AllowCreateServiceLinkedRoles"
  echo "  trust   : AllowCorgiroOperatorFromTooling + AllowAWSDevOpsAgentForAgentSpace"
else
  echo "  ${ROLE_NAME} not present in this account (expected if the primary"
  echo "  account is not itself in StackSet scope)."
fi

hr
echo "5. Agent API activity in the last ${LOOKBACK_MINUTES} minutes"
echo "   Expect AccessDenied only on apigateway:GET and lambda:GetFunction."
echo "   Anything else denied means the deny policy is too broad."
hr
START="$(python3 -c "
import datetime, os
m = int(os.environ['LOOKBACK_MINUTES'])
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=m)
print(t.strftime('%Y-%m-%dT%H:%M:%SZ'))
")"

"${AWSX[@]}" cloudtrail lookup-events \
  --start-time "$START" --max-results 50 --output json 2>/dev/null |
python3 -c "
import sys, json
from collections import Counter
try:
    d = json.load(sys.stdin)
except Exception:
    print('  (could not read CloudTrail)'); raise SystemExit
ok, denied = Counter(), Counter()
for e in d.get('Events', []):
    raw = json.loads(e['CloudTrailEvent'])
    arn = (raw.get('userIdentity') or {}).get('arn', '') or ''
    if 'DevOpsAgent' not in arn and 'Corgiro' not in arn:
        continue
    key = '{}:{}'.format(raw.get('eventSource','').split('.')[0], raw.get('eventName'))
    if raw.get('errorCode'):
        denied['{}  [{}]'.format(key, raw['errorCode'])] += 1
    else:
        ok[key] += 1
print('  allowed ({} distinct):'.format(len(ok)))
for k, v in ok.most_common(25):
    print('    {}  x{}'.format(k, v))
print()
print('  DENIED / errored ({} distinct):'.format(len(denied)))
if not denied:
    print('    none')
for k, v in denied.most_common(25):
    print('    {}  x{}'.format(k, v))
"

hr
echo "Done. Nothing was modified."
hr
