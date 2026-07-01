---
name: ec2-compute-review
description: "EC2 fleet health assessment across every reachable account - instance generation, Graviton eligibility, EBS optimization, security configuration, instance utilization, and snapshot coverage. Use when reviewing EC2 fleet health, EC2 best practices, EC2 security posture, Graviton migration candidates, or EBS optimization opportunities."
user-invocable: true
---

# EC2 Compute Review

Assess EC2 fleet health across every reachable account in the organization. Evaluates instance generation, rightsizing signals, EBS volume optimization, security group configuration, IMDSv2 enforcement, Graviton eligibility, and snapshot coverage. Produces a prioritized risk report with actionable recommendations and cost savings estimates.

## Prerequisites

- `~/.corgiro/config.json` exists (run `/corgiro setup-corgiro` if not) and a valid SSO session.
- A fresh coverage snapshot (run `/corgiro account-coverage` if stale).
- Read [`../../references/credential-resolution.md`](../../references/credential-resolution.md) and [`../../references/cross-account-defaults.md`](../../references/cross-account-defaults.md).

## Parameters

| Parameter         | Default         | Description                                                      |
| ----------------- | --------------- | ---------------------------------------------------------------- |
| `regions`         | `auto`          | Region list, or `auto` to discover from Cost Explorer spend data |
| `account_filter`  | _(from config)_ | Include/exclude lists                                            |
| `instance_filter` | all             | Specific instance IDs (comma-separated), or `all`                |
| `max_parallel`    | `4`             | Concurrent accounts                                              |
| `output_format`   | `both`          | `markdown`, `html`, or `both`                                    |

## Workflow

### Step 1: Prerequisite Check

Confirm coverage snapshot is fresh and SSO session is valid. Read `accessMode` from `~/.corgiro/config.json`.

### Step 2: Determine Scope

Build the account list from `~/.corgiro/state/roster.json`, applying `account_filter`.

If `regions = auto`, use Cost Explorer to discover account/region combos with EC2 Compute spend > $0 in the last 90 days. Cost Explorer is a payer/org-level API, not a per-account call:

- **`cross-account-role`:** query CE from the tooling/management session (delegated admin / payer access) — use local credentials, no per-account profile.
- **`identity-center-direct`:** use a profile that has payer-level CE access (shown below as `corgiro-<payerAccountId>`); if none is available, skip `auto` and fall back to the default region set.

```bash
aws ce get-cost-and-usage \
  --time-period Start=<90-days-ago>,End=<today> \
  --granularity MONTHLY \
  --metrics "UnblendedCost" \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Elastic Compute Cloud - Compute"]}}' \
  --group-by Type=DIMENSION,Key=LINKED_ACCOUNT Type=DIMENSION,Key=REGION \
  --region us-east-1 --output json
  # cross-account-role: run with the tooling/management session (local creds)
  # identity-center-direct: add --profile corgiro-<payerAccountId>
```

> **Payer-level caveat:** Under `identity-center-direct`, the operator may not have payer-level CE access. If CE returns `AccessDeniedException`, fall back to probing a default region set (`us-east-1`, `us-west-2`, `eu-west-1`, `ap-southeast-1`) per reachable account.

Extract unique `{account_id, region}` pairs with spend > $0. Save to `scope.json`.

### Step 3: Instance Inventory

For each reachable account + region (up to `max_parallel` concurrently):

1. Resolve credentials per [`../../references/credential-resolution.md`](../../references/credential-resolution.md) -- dispatch on the account's `via`. The commands below omit credential flags; apply the resolved per-account credentials: `--profile corgiro-<accountId>` for `via: sso`, or the exported AssumeRole credentials for `via: assume-role`.
2. Collect instances:
   ```bash
   aws ec2 describe-instances \
     --filters "Name=instance-state-name,Values=running,stopped,stopping" \
     --query "Reservations[].Instances[]" \
     --region <region> --output json
   ```
   If `instance_filter` is set (not `all`), add `--instance-ids <id1> <id2> ...`.
   Paginate with `--next-token` if response is truncated.
3. Collect volumes:
   ```bash
   aws ec2 describe-volumes \
     --query "Volumes[]" \
     --region <region> --output json
   ```
   Paginate with `--next-token` if response is truncated. Join volumes to instances by `Attachments[].InstanceId`.
4. Save to `per-account/<account_id>/<region>/instances.json`.

Skip accounts that fail credential resolution; record in `skipped_accounts` and continue.

### Step 4: CloudWatch Performance Metrics

For each account + region with running instances:

1. Batch instances into `get-metric-data` calls (up to 500 MetricDataQueries per call, ~40 instances per batch):
   ```bash
   aws cloudwatch get-metric-data \
     --metric-data-queries file:///tmp/corgiro-metrics-query.json \
     --start-time <14-days-ago-ISO> \
     --end-time <now-ISO> \
     --region <region> --output json
   ```
2. For each running instance, request (Period=3600, 14 days):
   - `AWS/EC2` / `CPUUtilization` -- Average, Maximum
   - `AWS/EC2` / `NetworkIn` -- Sum
   - `AWS/EC2` / `NetworkOut` -- Sum
   - `AWS/EC2` / `StatusCheckFailed` -- Sum
3. For EBS volumes (`AWS/EBS` / `VolumeId` dimension):
   - `VolumeReadOps` -- Sum
   - `VolumeWriteOps` -- Sum
   - `VolumeQueueLength` -- Average
   - `BurstBalance` -- Minimum (for gp2/st1/sc1 only)
4. Save to `per-account/<account_id>/<region>/metrics.json`.

### Step 5: Security & Snapshot Audit

For each account + region:

1. Collect unique security group IDs from instances; describe them:
   ```bash
   aws ec2 describe-security-groups \
     --group-ids <sg-1> <sg-2> ... \
     --query "SecurityGroups[]" \
     --region <region> --output json
   ```
2. Collect all volume IDs from instances; check snapshot coverage:
   ```bash
   aws ec2 describe-snapshots \
     --filters "Name=volume-id,Values=<vol-1>,<vol-2>,..." \
     --owner-ids <accountId> \
     --query "Snapshots[]" \
     --region <region> --output json
   ```
   Keep only the most recent snapshot per volume (sort by `StartTime` desc).
3. Save to `per-account/<account_id>/<region>/security-snapshots.json`.

### Step 6: Analyze and Score

Aggregate all per-account data into `aggregated.json`. Flag each instance:

**Configuration flags:**

| Flag                      | Trigger                                                                                                                |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `PREVIOUS_GEN_INSTANCE`   | Instance type starts with previous gen family (m4, c4, r4, m3, c3, t2, i2, d2, t1, m1, m2, c1)                         |
| `GRAVITON_CANDIDATE`      | Current x86 type (m5, c5, r5, m6i, c6i, r6i, m7i, c7i, r7i, t3, m5a, c5a, r5a, m6a, c6a) where arm64 equivalent exists |
| `STOPPED_INSTANCE`        | State = stopped for > 30 days                                                                                          |
| `STOPPED_WITH_VOLUMES`    | State = stopped with attached EBS volumes                                                                              |
| `IMDSV1_ENABLED`          | `MetadataOptions.HttpTokens` != `required`                                                                             |
| `NO_IAM_ROLE`             | No IAM instance profile attached                                                                                       |
| `EBS_NOT_OPTIMIZED`       | `EbsOptimized` = false on a type that supports it                                                                      |
| `DETAILED_MONITORING_OFF` | Monitoring state != `enabled`                                                                                          |
| `PUBLIC_IP`               | Public IP address assigned                                                                                             |
| `DEDICATED_TENANCY`       | Placement tenancy = `dedicated`                                                                                        |
| `UNENCRYPTED_EBS`         | Any attached volume with `Encrypted` = false                                                                           |
| `GP2_VOLUME`              | Any attached gp2 volume (size <= 100 GB)                                                                               |
| `GP2_VOLUME_LARGE`        | Any attached gp2 volume (size > 100 GB)                                                                                |
| `IO1_VOLUME`              | Any attached io1 volume                                                                                                |

**Performance flags:**

| Flag                    | Trigger                                   |
| ----------------------- | ----------------------------------------- |
| `CPU_IDLE`              | Average CPU < 5% over 14 days             |
| `CPU_UNDERUTILIZED`     | Average CPU 5-15% over 14 days            |
| `CPU_SATURATED`         | Max CPU > 95% for > 50% of hourly periods |
| `NETWORK_IDLE`          | Total network I/O < 0.1 GB over 14 days   |
| `STATUS_CHECK_FAILURES` | Any status check failures in 14 days      |
| `EBS_BURST_DEPLETED`    | Min BurstBalance < 20%                    |
| `EBS_QUEUE_HIGH`        | Average queue length > 1                  |

**Security flags:**

| Flag                  | Trigger                                |
| --------------------- | -------------------------------------- |
| `SSH_OPEN_TO_WORLD`   | Ingress 0.0.0.0/0 or ::/0 on port 22   |
| `RDP_OPEN_TO_WORLD`   | Ingress 0.0.0.0/0 or ::/0 on port 3389 |
| `ALL_PORTS_OPEN`      | Ingress 0.0.0.0/0 or ::/0 on all ports |
| `NO_SNAPSHOT`         | Volume has no snapshot                 |
| `STALE_SNAPSHOT`      | Most recent snapshot > 30 days old     |
| `VERY_STALE_SNAPSHOT` | Most recent snapshot > 90 days old     |

**Health scoring:**

| Health                  | Criteria                                                                                                                                                                                                     |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Critical (`badge--red`) | Any: PREVIOUS_GEN_INSTANCE, IMDSV1_ENABLED, SSH_OPEN_TO_WORLD, RDP_OPEN_TO_WORLD, ALL_PORTS_OPEN, CPU_SATURATED, STATUS_CHECK_FAILURES, UNENCRYPTED_EBS                                                      |
| High (`badge--orange`)  | Any: CPU_IDLE (running), STOPPED_WITH_VOLUMES, GP2_VOLUME_LARGE, NO_SNAPSHOT, EBS_BURST_DEPLETED, NO_IAM_ROLE, VERY_STALE_SNAPSHOT                                                                           |
| Medium (`badge--amber`) | Any: GRAVITON_CANDIDATE, CPU_UNDERUTILIZED, DETAILED_MONITORING_OFF, GP2_VOLUME, IO1_VOLUME, STALE_SNAPSHOT, EBS_NOT_OPTIMIZED, PUBLIC_IP, NETWORK_IDLE, EBS_QUEUE_HIGH, DEDICATED_TENANCY, STOPPED_INSTANCE |
| Low (`badge--green`)    | No flags                                                                                                                                                                                                     |

### Step 7: Cost Savings Estimates

If Cost Explorer is accessible (payer account), estimate savings:

**Graviton savings:** For each `GRAVITON_CANDIDATE`, query CE for its instance type's monthly spend. Apply 20% savings estimate for the arm64 equivalent.

**gp2 to gp3 savings:** For each gp2 volume: storage savings = size x $0.02/GB/mo (gp2 $0.10 - gp3 $0.08).

**Stopped instance EBS waste:** For each `STOPPED_WITH_VOLUMES`: sum EBS costs of attached volumes using on-demand pricing (gp2: $0.10/GB/mo, gp3: $0.08/GB/mo, io1/io2: $0.125/GB/mo + $0.065/IOPS/mo, st1: $0.045/GB/mo, sc1: $0.015/GB/mo).

> These are estimates based on us-east-1 on-demand pricing. Actual savings vary by region and RI/SP coverage.

If CE is inaccessible, skip this step and note the gap in the report.

### Step 8: Generate Report

Render per the shared [`../../references/report-format.md`](../../references/report-format.md) -- self-contained HTML + Markdown, Corgiro branding, KPI cards, tables, badges, and a closing Methodology section.

Report sections:

1. **Executive Summary** -- KPI cards: total instances (running/stopped), health breakdown (Critical/High/Medium/Low), estimated monthly savings
2. **Critical Findings** -- instances with red health flags, grouped by finding type
3. **Cost Optimization** -- Graviton candidates, gp2-to-gp3, stopped instance waste
4. **Security Findings** -- open security groups, IMDSv1, unencrypted EBS, missing IAM roles
5. **Performance** -- idle/underutilized/saturated instances
6. **EBS & Snapshots** -- volume type distribution, snapshot coverage gaps
7. **Per-Account Summary** -- table with account name, instance count, health breakdown
8. **Recommendations** -- prioritized action items
9. **Methodology** -- APIs used, scope, what was not covered

Write `EC2-Compute-Review-<DATE>.md` and/or `.html` per `output_format`. Then open the HTML report.

## Safety

- Read-only: only describe/list/get calls (`ec2 describe-instances`, `ec2 describe-volumes`, `ec2 describe-security-groups`, `ec2 describe-snapshots`, `cloudwatch get-metric-data`, `ce get-cost-and-usage`).
- Never print access keys, session tokens, or the external ID.
- Cost estimates use published on-demand pricing and are clearly labeled as estimates.

## Output

```
./<run_id>/
├── scope.json
├── per-account/<account_id>/<region>/
│   ├── instances.json
│   ├── metrics.json
│   └── security-snapshots.json
├── aggregated.json
├── EC2-Compute-Review-<DATE>.md
└── EC2-Compute-Review-<DATE>.html
```

## Error Handling

| Symptom                                     | Action                                                                                              |
| ------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Credential resolution fails for one account | Skip, note in report, continue (see `credential-resolution.md`)                                     |
| Cost Explorer `AccessDeniedException`       | Under `identity-center-direct`, fall back to default region set; note savings estimates unavailable |
| `ThrottlingException`                       | Exponential backoff (base 1s, cap 30s); reduce `max_parallel`                                       |
| CloudWatch returns no data for an instance  | Instance may be newly launched (< 14 days); note gap, skip performance scoring                      |
| No instances found in any account           | Report "no EC2 instances found" in the summary; still generate report showing scope                 |
