#!/usr/bin/env bash
#
# Deploy the Corgiro asset layer into an Agent Space, idempotently:
#
#   1. skill         imported from a GitHub repository URL
#   2. custom_agent  prompt + skills + tools + memory_stores
#                    (local corgiro-agent-prompt.md -> asset CUSTOM_AGENT.md)
#
# Scheduled triggers are deliberately NOT handled - see the note at the end.
#
# Re-running updates in place rather than duplicating. The asset `version`
# field bumps on every successful update, which is the drift signal.
#
# Why a script and not CloudFormation:
#   AWS::DevOpsAgent::Asset exposes only Files and Zip, NOT SourceUrl. The
#   repo-URL import is API-only. Since the custom agent depends on the skill's
#   asset ID and the trigger depends on the custom agent's, chaining all three
#   here is simpler than CloudFormation plus manual parameter passing.
#
# DRY RUN BY DEFAULT. Set CONFIRM=yes to apply.
#
set -euo pipefail

# TOOLING_PROFILE must reach the Tooling Account, which hosts the Agent Space -
# the same account deploy-infra.sh deploys template 2 into. PROFILE is accepted
# as an alias so older invocations keep working.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
common_init_interactive
common_init_dry

[ "$INTERACTIVE" -eq 1 ] && printf '\nCorgiro DevOps Agent assets - press Enter to accept defaults\n\n'

TOOLING_PROFILE="${TOOLING_PROFILE:-${PROFILE:-}}"
ask TOOLING_PROFILE "AWS profile for the Tooling Account"
ask REGION          "Region" "us-east-1"
ask AGENT_NAME      "Custom agent name" "corgiro-agent"

need TOOLING_PROFILE "Set TOOLING_PROFILE (or PROFILE) to a profile for the Tooling Account."
need REGION          "Set REGION."
PROFILE="$TOOLING_PROFILE"
STACK_NAME="${STACK_NAME:-corgiro-agent-space}"

# AGENT_SPACE_ID is derived from the template 2 stack output when not supplied,
# so the usual case needs only TOOLING_PROFILE.
if [ -z "${AGENT_SPACE_ID:-}" ]; then
  AGENT_SPACE_ID="$(aws cloudformation describe-stacks --profile "$TOOLING_PROFILE" \
    --region "$REGION" --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='AgentSpaceId'].OutputValue" \
    --output text 2>/dev/null || echo '')"
  if [ -n "$AGENT_SPACE_ID" ] && [ "$AGENT_SPACE_ID" != "None" ]; then
    echo "AGENT_SPACE_ID derived from stack '${STACK_NAME}': ${AGENT_SPACE_ID}"
  else
    echo "Could not derive AGENT_SPACE_ID from stack '${STACK_NAME}'." >&2
    echo "  Pass AGENT_SPACE_ID=<uuid>, or STACK_NAME=<name> if the stack is named" >&2
    echo "  differently. List spaces with: aws devops-agent list-agent-spaces" >&2
    exit 1
  fi
fi

# Lookup key, not a name we assign - must equal the SKILL.md frontmatter name.
# Not a parameter. This is the LOOKUP KEY used to find an existing skill, and it
# is owned by the `name:` field in skills/corgiro/SKILL.md - a different value
# cannot rename anything, it can only fail to match and create a duplicate. It
# therefore tracks SKILL.md, and the check below catches it if that ever drifts.
SKILL_NAME="corgiro"
SKILL_URL="${SKILL_URL:-https://github.com/aws-samples/sample-corgiro-aws-ops-skills/tree/main/skills/corgiro}"
SKILL_AGENT_TYPES="${SKILL_AGENT_TYPES:-GENERIC}"

AGENT_NAME="${AGENT_NAME:-corgiro-agent}"
PROMPT_FILE="${PROMPT_FILE:-${SCRIPT_DIR}/../custom-agent/corgiro-agent-prompt.md}"

# Matches the live corgiro-agent. The first seven are the starter set; the rest
# were added for specific modes. See custom-agent/SETUP.md for the rationale and
# the deliberate exclusions.
TOOLS="${TOOLS:-\
use_aws,\
get_associations,\
verify_aws_claim,\
create_or_update_artifact,\
get_skill_resource,\
get_skill_resource_manifest,\
list_skills_metadata,\
list_resources,\
list_resources_by_type,\
list_resource_details,\
list_resource_history,\
get_account_cloudformation_stacks,\
lookup_cloudtrail_events,\
trusted_advisor_list_recommendations,\
trusted_advisor_get_recommendation_details}"


AWSX=(aws devops-agent --profile "$PROFILE" --region "$REGION")


[ -f "$PROMPT_FILE" ] || { say "prompt file not found: $PROMPT_FILE" >&2; exit 1; }

say "=============================================================="
say " Agent Space : ${AGENT_SPACE_ID}"
say " Region      : ${REGION}   Profile: ${PROFILE}"
say " Skill       : ${SKILL_NAME}  <- ${SKILL_URL}"
say " Custom agent: ${AGENT_NAME}  prompt: $(basename "$PROMPT_FILE") ($(wc -c < "$PROMPT_FILE" | tr -d ' ') chars)"
say " Tools       : ${TOOLS}"
say " Mode        : $([ "$DRY" -eq 1 ] && echo 'DRY RUN' || echo APPLY)"
say "=============================================================="
common_confirm
say

# ---------------------------------------------------------------- helpers
# Find an existing asset of a given type by its metadata name.
find_asset() {
  local atype="$1" aname="$2"
  "${AWSX[@]}" list-assets --agent-space-id "$AGENT_SPACE_ID" --output json 2>/dev/null |
  ATYPE="$atype" ANAME="$aname" python3 -c '
import sys, json, os
t, n = os.environ["ATYPE"], os.environ["ANAME"]
for a in json.load(sys.stdin).get("items", []):
    if a.get("assetType") == t and (a.get("metadata") or {}).get("name") == n:
        print(a["assetId"]); break
'
}

# ---------------------------------------------------------------- 1. skill
say "--- 1. skill: ${SKILL_NAME} ---"
SKILL_ID="$(find_asset skill "$SKILL_NAME" || true)"

# A skill imported from a sourceUrl takes its name and description from the
# SKILL.md frontmatter, in BOTH directions:
#   - update rejects them outright:
#       ValidationException: Imported skills do not support direct updates to
#       name and description.
#   - create silently IGNORES a supplied name. Verified: creating with
#       {"name":"corgiro-createtest-a"} produced an asset named "corgiro".
# So only status and agent_types are ever ours to set, and one payload serves
# create and update alike.
#
# Consequence for SKILL_NAME: it is a LOOKUP KEY, not a name we assign. It must
# match the frontmatter name in the repo (currently "corgiro"). If it does not,
# find_asset never matches, every run takes the create branch, and duplicate
# skills accumulate.
SKILL_META="$(T="$SKILL_AGENT_TYPES" python3 -c '
import json, os
print(json.dumps({
  "agent_types": os.environ["T"].split(","),
  "status": "ACTIVE",
}))')"
SKILL_CONTENT="sourceUrl={url=${SKILL_URL}}"

if [ -n "$SKILL_ID" ]; then
  say "  exists: ${SKILL_ID} -> re-syncing from source URL"
  # Two calls, deliberately. Sending --metadata and a sourceUrl --content in the
  # same UpdateAsset returns InternalServerException; each works alone. Verified
  # against the live service.
  run "${AWSX[@]}" update-asset \
    --agent-space-id "$AGENT_SPACE_ID" --asset-id "$SKILL_ID" \
    --content "$SKILL_CONTENT" >/dev/null
  run "${AWSX[@]}" update-asset \
    --agent-space-id "$AGENT_SPACE_ID" --asset-id "$SKILL_ID" \
    --metadata "$SKILL_META" >/dev/null
  say "  re-synced and metadata applied"
else
  say "  not found -> creating from source URL"
  if [ "$DRY" -eq 0 ]; then
    _created="$("${AWSX[@]}" create-asset \
      --agent-space-id "$AGENT_SPACE_ID" --asset-type skill \
      --metadata "$SKILL_META" --content "$SKILL_CONTENT" \
      --query 'asset.{id:assetId,name:metadata.name}' --output json)"
    SKILL_ID="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' <<< "$_created")"
    _actual="$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("name") or "")' <<< "$_created")"
    say "  created: ${SKILL_ID} (name from frontmatter: ${_actual:-unknown})"
    if [ -n "$_actual" ] && [ "$_actual" != "$SKILL_NAME" ]; then
      say "  WARNING: SKILL_NAME='${SKILL_NAME}' but the skill is named" >&2
      say "           '${_actual}', taken from its SKILL.md frontmatter. The" >&2
      say "           lookup is by name, so the next run will NOT find it and" >&2
      say "           will create a duplicate. Update SKILL_NAME in this script" >&2
      say "           to '${_actual}' to match SKILL.md." >&2
    fi
  else
    say "  DRY-RUN would create-asset --asset-type skill --content ${SKILL_CONTENT}"
    SKILL_ID="<skill-asset-id>"
  fi
fi
say

# A freshly imported skill is not loadable for several minutes. Observed:
# skill_read failed 3x with "Skill not found: corgiro" and only succeeded
# 5.5 minutes after import, despite the skill being ACTIVE the whole time.
say "  NOTE: a newly imported skill takes a few minutes to become loadable."
say "        Do not invoke the agent immediately after a first-time create."
say

# ---------------------------------------------------------- 2. custom agent
say "--- 2. custom agent: ${AGENT_NAME} ---"
AGENT_ID="$(find_asset custom_agent "$AGENT_NAME" || true)"

AGENT_META="$(N="$AGENT_NAME" S="$SKILL_ID" T="$TOOLS" python3 -c '
import json, os
print(json.dumps({
  "name": os.environ["N"],
  "skills": [os.environ["S"]],
  "tools": os.environ["T"].split(","),
  "memory_stores": [],
  "status": "ACTIVE",
}))')"

# The path INSIDE the asset must be CUSTOM_AGENT.md - that is what the service
# creates and expects, not AGENT.md as the CDK sample in the docs shows. The
# local repo filename (corgiro-agent-prompt.md) is independent of it.
AGENT_CONTENT="$(F="$PROMPT_FILE" python3 -c '
import json, os
body = open(os.environ["F"], encoding="utf-8").read()
print(json.dumps({"file": {"path": "CUSTOM_AGENT.md", "body": {"text": body}}}))')"

if [ -n "$AGENT_ID" ]; then
  say "  exists: ${AGENT_ID} -> updating prompt, skills and tools"
  run "${AWSX[@]}" update-asset \
    --agent-space-id "$AGENT_SPACE_ID" --asset-id "$AGENT_ID" \
    --metadata "$AGENT_META" --content "$AGENT_CONTENT"
else
  say "  not found -> creating"
  if [ "$DRY" -eq 0 ]; then
    AGENT_ID="$("${AWSX[@]}" create-asset \
      --agent-space-id "$AGENT_SPACE_ID" --asset-type custom_agent \
      --metadata "$AGENT_META" --content "$AGENT_CONTENT" \
      --query 'asset.assetId' --output text)"
    say "  created: ${AGENT_ID}"
  else
    say "  DRY-RUN would create-asset --asset-type custom_agent"
    AGENT_ID="<custom-agent-asset-id>"
  fi
fi
say

# --------------------------------------------------------- triggers: not handled
#
# A trigger is what runs a custom agent on a schedule instead of only when
# someone clicks "Run this agent now". It is deliberately out of scope here.
#
# If you want one later, note that it is NOT safely scriptable as-is:
# Condition and Action are create-only properties, so there is no update path
# for a schedule - only Status (Active|Inactive) can change, which is how you
# pause one. create-trigger therefore always creates, and re-running this script
# would stack duplicate triggers on the same agent. Handling it properly means
# listing triggers first and deleting before recreating.
#
# The shape, for reference:
#
#   aws devops-agent create-trigger \
#     --agent-space-id <space> --type TIME_BASED \
#     --condition '{"schedule":{"expression":"cron(0 2 1 * ? *)"}}' \
#     --action '{"actionType":"create:task","task":{"agent":"custom:<assetId>"}}' \
#     --status Active
#
# Prefer cron over rate: cron(0 2 1 * ? *) pins the run to the 1st of each month
# at 02:00 UTC, which keeps reports comparable month to month, whereas
# rate(30 days) drifts against the calendar.

say "=============================================================="
say " skill        ${SKILL_ID}"
say " custom agent ${AGENT_ID}"
[ "$DRY" -eq 1 ] && common_nochange_note
say "=============================================================="
