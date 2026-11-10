# Report Sections (Step 7)

The mode-specific report sections for `vpce-costopt`. Everything renders with the shared [`report-format.md`](../../../references/report-format.md) components only — `data-table`, badges, KPI cards — and the standard asset injection (Rule 9). The mode adds no CSS, images, or diagrams of its own.

**Focus region** = the region with the highest NAT Gateway data processing cost in `month`. The cost-path, bill, and break-even tables use it; name the region in each section intro.

## KPI cards

In this order: NAT Gateways found · NAT data processing $ in `month` · estimated monthly saving (`is-ok` when $0, else the tier's accent) · VPCs missing gateway endpoints · accounts covered (`reachable / in scope`; `is-critical` when any failed).

Under the KPI cards, one plain `<p>` with the verdict in one sentence that quotes the numbers, led by the overall tier badge, for example: "Your busiest NAT Gateway sends 3.2 GB/month to in-region AWS services; one endpoint in one AZ breaks even at 112–162 GB/month, so no endpoint pays for itself today."

## How the cost works

One `data-table`, one row per hop, with this run's focus-region prices. The hop numbers are reused in every other table.

| Hop | Path | CUR `line_item_operation` | CUR `line_item_usage_type` (suffix) | Price symbol | Price (focus region) |
|----:|------|---------------------------|--------------------------------------|--------------|----------------------|
| 1 | current | `InterZone-Out` | `DataTransfer-Regional-Bytes` | `p_xaz` | |
| 2 | current | `InterZone-In` | `DataTransfer-Regional-Bytes` | `p_xaz` | |
| 3 | current | `NatGateway` | `NatGateway-Bytes` | `p_nat` | |
| 4 | current | `PublicIP-Out` or `PublicIP-In` | `DataTransfer-Regional-Bytes` | `p_rdt` | |
| 5 | proposed | (endpoint operation) | `VpcEndpoint-Bytes` | `p_ep_gb` | |
| 6 | proposed | (endpoint operation) | `VpcEndpoint-Hours` | `p_ep_hr` | |

- Hops 1–2 apply only when the workload's subnet is in a different AZ from its NAT Gateway (fraction `f` in the savings model). Hop 4 is charged **once per GB**, as Out or In depending on which way the byte moved — never add both to a per-GB total.
- Price cell: `$<value>/GB · <source>` (`bill` or `list`), 4 decimal places, from `aggregated.json`. Hop 6: `$<p_ep_hr>/h = $<p_ep_hr x 730>/mo · <source>`. Never fill a price from memory; if unresolved, write `price not resolved`.
- Below the table, state the totals: current per GB = hop 4 + hop 3 (same AZ), and + hops 1 + 2 (cross-AZ); proposed = hop 5 per GB, plus hop 6 x 730 per endpoint per AZ per month as a fixed cost.

## How to read your bill (CUR)

A `data-table` of the real Step 2 rows for the focus region, one row per bill line. Columns: `line_item_usage_type`, `line_item_operation`, `line_item_resource_id` (`mono`), usage amount (`num`), unblended cost (`num`), period, hop. Note under the table that the Cost Explorer dimensions `USAGE_TYPE`, `OPERATION` and `RESOURCE_ID` are the same fields.

- Operation rows come from the Step 2 `USAGE_TYPE` + `OPERATION` breakdown (see [traffic-attribution.md](traffic-attribution.md)). When a run only has the combined `PublicIP-In`/`PublicIP-Out` figure, show one row with operation `PublicIP-Out + PublicIP-In` and say it is combined.
- Resource rows (NAT Gateway ARNs) come from the resource-level pull and cover its 14-day window, not `month`. Label the period on every row.
- Never invent a row the run did not return; write "not queried in this run" in the cell instead.
- Resource IDs and usage types are AWS-returned strings: escape them (report-format.md rule 8).

## Current vs proposed

A `data-table`, one row per NAT Gateway, largest attributed GB first. Columns (`num` except the first and last): NAT Gateway (`mono`), attributed GB, PublicIP $ (hop 4: `G x p_rdt`), NAT processing $ (hop 3: `G x p_nat`), cross-AZ $ (hops 1–2: `G x 2 x f x p_xaz`; when `f` is unknown, use the worst case `f = 1` and mark the cell "worst case"), current total $, endpoint data $ (hop 5: `G x p_ep_gb`), endpoint hours $ (hop 6: `A x E x p_ep_hr x 730`), proposed total $, tier badge.

## Break-even

A `data-table` for the focus region with the break-even GB/month for one interface endpoint in one AZ:

| Scenario | Current $/GB | Break-even GB/month |
|----------|--------------|---------------------|
| Same AZ | `p_rdt + p_nat` | `p_ep_hr x 730 / (p_rdt + p_nat - p_ep_gb)` |
| All cross-AZ | `p_rdt + p_nat + 2 p_xaz` | `p_ep_hr x 730 / (p_rdt + p_nat + 2 p_xaz - p_ep_gb)` |

Follow it with the focus region's NAT Gateways and their attributed GB, each marked above or below break-even.

## Markdown sibling

Same sections and tables in the same order, plain Markdown. Keep the verdict sentence.
