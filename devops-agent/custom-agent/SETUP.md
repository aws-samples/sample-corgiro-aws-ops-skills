# Creating the custom agent

`scripts/deploy-assets.sh` does all of this. These steps are for creating the
agent by hand, or for understanding what the script produces.

## Step 1: create the agent

The console form has two fields only, Name and System prompt.

```
Name            corgiro-agent
System prompt   the entire contents of corgiro-agent-prompt.md
```

`corgiro-agent-prompt.md` carries no frontmatter, so paste it whole. The quota
is 50,000 characters.

## Step 2: attach the skill

Attach the `corgiro` skill. Find its asset ID with:

```bash
aws devops-agent list-assets \
  --agent-space-id <space-id> --profile <profile> --region <region>
```

## Step 3: configure tools through Chat, not the form

Per the AWS documentation:

> Tools can only be configured through Chat. To assign tools when creating an
> agent, use the Chat creation method. To add or change tools on an existing
> agent, ask Chat to update the agent.

So the form never shows tools. Ask Chat instead:

```
Add the use_aws, get_associations, verify_aws_claim, create_or_update_artifact,
get_skill_resource, get_skill_resource_manifest and list_skills_metadata tools
to my corgiro-agent agent.
```

The API does accept tools in `custom_agent` metadata, which is how
`deploy-assets.sh` sets them. The Chat-only restriction is a console limitation.

### Two different sets of tool names

AWS does not publish the tool list. The authoritative set of **selectable**
names is the `toolbox_list_tools` manifest, visible in any execution's
`tool_manifest` journal record. The `tool_name` values in journal records are
**runtime** names, and several have no selectable equivalent:

| Journal `tool_name` | Selectable name |
|---|---|
| `list_associations` | `get_associations` |
| `generate_artifact` | `create_or_update_artifact` |
| `skill_read`, `read_skill_resource` | `get_skill_resource` |
| `gather_context` | none, built in |
| `ask_user` | none, built in |

## Tool selection

The manifest offers well over a hundred tools. Do not select all: it contains
write tools that act on systems the AWS deny policy does not protect
(`retry_jenkins_build`, `post_github_pr_comment`, `create_github_issue`,
`upload_skill`, `delete_memory`), every tool schema consumes context needed for
skill content, and irrelevant tools give the agent plausible-looking wrong paths.

### Start with these seven

```
use_aws                        AWS API access
get_associations               account scope discovery
verify_aws_claim               fetch AWS docs for end-of-support dates
create_or_update_artifact      the report
get_skill_resource             read the attached skill
get_skill_resource_manifest
list_skills_metadata
```

Artifact creation is documented as built in for all custom agents, so
`create_or_update_artifact` may be redundant. Harmless to include.

### Add per mode, if something is visibly missing

```
list_resources                              inventory
list_resources_by_type
list_resource_details
list_resource_history
get_account_cloudformation_stacks
lookup_cloudtrail_events                    access-key recency (iam-security-review)
trusted_advisor_list_recommendations        overlaps ec2-compute-review
trusted_advisor_get_recommendation_details
```

### Deliberately exclude

Everything GitHub, GitLab, Jenkins, ArgoCD, Azure DevOps, PagerDuty, ServiceNow,
Dynatrace and Prometheus. Also `use_kubectl`, `use_azure`, `execute_dql_query`,
and every `retry_*`, `post_*`, `create_*` other than the artifact one,
`upload_*` and `delete_*`.

`query_cloudwatch_logs` is pointless here: the deny policy blocks
`logs:GetLogEvents` and `logs:FilterLogEvents` underneath it.

`get_cloud_resource_topology` is not needed either, since every Corgiro mode
reaches service APIs directly rather than traversing the graph.

`run_subagent` is a judgement call. A sub-agent given one account will return a
confident answer about one account, and section 1 of the prompt exists because
that happened. The prompt now constrains it, but excluding the tool removes the
failure mode entirely at the cost of parallelism.

## Memory stores: attach none

> A new custom agent starts with no memory stores attached, so it has no memory
> access until you attach one.

Leave it that way. Corgiro should read live APIs, not the topology Understanding
memory, which would add context and tempt the agent to answer from the graph.

## Invoking it

```
Run my corgiro-agent agent.
Run corgiro-agent, mode rds-eol-analysis.
```

Any extra context in the chat message is passed as the prompt for that run,
alongside the system prompt. `Run this agent now.` with no context leaves the
mode unspecified, and the agent will choose one.

There is no slash-command system here. `/corgiro <mode>` belongs to the local
CLI; name the mode in plain language instead.

A custom agent runs one invocation at a time. If it is already running you must
wait for it to finish, time out, or be cancelled.

## What to check on the first run

1. Does it reach all associated accounts on the first attempt, with no
   self-correcting detour?
2. Does the artifact follow the prompt's element sequence rather than a
   reinvented one?
3. Are there tool errors in the journal?

```bash
aws devops-agent list-backlog-tasks \
  --agent-space-id <space-id> --profile <profile> --region <region>

aws devops-agent list-journal-records \
  --agent-space-id <space-id> --execution-id <execution-id> \
  --profile <profile> --region <region>
```
