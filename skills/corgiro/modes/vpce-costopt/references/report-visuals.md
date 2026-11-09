# Report Visuals (Step 7)

The visual sections every `vpce-costopt` HTML report carries, on top of the shared [`report-format.md`](../../../references/report-format.md). Each visual answers one question a reader has:

| Section | Question it answers | Built from |
|---------|---------------------|------------|
| Flow diagram | Where does the money go per GB, and what changes? | [`vpce-costopt-flow.svg`](../../../assets/vpce-costopt-flow.svg) template |
| How to read your bill (CUR) | Which bill lines are those hops? | Step 2 Cost Explorer results |
| Cost bars per NAT Gateway | Current vs proposed, by component | `aggregated.json` |
| Break-even chart | Why is the saving what it is? | `aggregated.json` + diagram-region prices |

## Assets and injection

Both visual assets are injected like the shared CSS and logo (report-format.md rule 9): never transcribe them by hand.

- [`vpce-costopt-visuals.css`](../../../assets/vpce-costopt-visuals.css) extends `report-theme.css`. Put the placeholder `/*__VPCE_VISUALS_CSS__*/` in the same `<style>` block, **after** `/*__CORGIRO_CSS__*/`. It adds the diagram, bar and chart classes and a `prefers-color-scheme: dark` remap of the shared palette variables, so the whole report (badges, tables, diagram) follows the reader's theme. It defines no new colours outside that palette.
- [`vpce-costopt-flow.svg`](../../../assets/vpce-costopt-flow.svg) is the flow diagram. Put `<!--__VPCE_FLOW_SVG__-->` inside a `<figure class="vx-figure">`, then replace the tokens below in the SVG text before splicing it in.

```bash
python3 - <<'PY'
a, p = '<assets>', '<run_dir>/VPCE-CostOpt-<DATE>.html'
svg = open(f'{a}/vpce-costopt-flow.svg').read()
for k, v in {'{{REGION}}': '<region>', '{{P_XAZ}}': '<label>', '{{P_NAT}}': '<label>',
             '{{P_RDT}}': '<label>', '{{P_EP_GB}}': '<label>', '{{P_EP_HR}}': '<label>'}.items():
    svg = svg.replace(k, v)
doc = open(p).read()
doc = (doc.replace('/*__CORGIRO_CSS__*/', open(f'{a}/report-theme.css').read())
          .replace('/*__VPCE_VISUALS_CSS__*/', open(f'{a}/vpce-costopt-visuals.css').read())
          .replace('__CORGIRO_LOGO__', open(f'{a}/corgiro-logo.datauri').read().strip())
          .replace('<!--__VPCE_FLOW_SVG__-->', svg))
open(p, 'w').write(doc)   # read fully first, then write - never open for writing before reading
PY
grep -c '{{' '<run_dir>/VPCE-CostOpt-<DATE>.html'    # expect 0: every token filled
grep -c 'id="vx-title"' '<run_dir>/VPCE-CostOpt-<DATE>.html'   # expect 1
```

## Flow diagram

**Region:** draw the region with the highest NAT Gateway data processing cost in `month`. Say so in the caption.

**Hop to bill-line mapping** (the numbers on the diagram are the hop numbers everywhere else in the report):

| Hop | Path | CUR `line_item_operation` | CUR `line_item_usage_type` (suffix) | Price symbol |
|----:|------|---------------------------|--------------------------------------|--------------|
| 1 | current | `InterZone-Out` | `DataTransfer-Regional-Bytes` | `p_xaz` |
| 2 | current | `InterZone-In` | `DataTransfer-Regional-Bytes` | `p_xaz` |
| 3 | current | `NatGateway` | `NatGateway-Bytes` | `p_nat` |
| 4 | current | `PublicIP-Out` or `PublicIP-In` | `DataTransfer-Regional-Bytes` | `p_rdt` |
| 5 | proposed | (endpoint operation) | `VpcEndpoint-Bytes` | `p_ep_gb` |
| 6 | proposed | (endpoint operation) | `VpcEndpoint-Hours` | `p_ep_hr` |

Hops 1-2 apply only when the workload's subnet is in a different AZ from its NAT Gateway (fraction `f` in the savings model). Hop 4 is charged **once per GB**, as Out or In depending on which way the byte moved, not both. Do not add both to a per-GB total.

**Token values.** Each price token is `$<value>/GB · <source>`, where source is `bill` or `list`, from `aggregated.json` prices for the diagram region (bill-derived when based on >= 1 GB, else Price List). Use 4 decimal places. `{{P_EP_HR}}` is `$<p_ep_hr>/h = $<p_ep_hr x 730>/mo · <source>`. Never fill a token with a remembered price; if a price is unresolved, write `price not resolved`.

**Legend under the diagram** (two `.vx-legend-card`s, `is-current` and `is-proposed`):

- Current per GB: hop 4 + hop 3 = same-AZ total; + hops 1 + 2 = cross-AZ total. Show both totals.
- Proposed: hop 5 per GB, plus hop 6 x 730 per endpoint per AZ per month as a fixed cost.

## How to read your bill (CUR)

A table (`data-table`) of the real Step 2 rows for the diagram region, one row per bill line, with a **Hop** column holding a `.hop .hop--red` / `.hop--blue` chip. Columns: `line_item_usage_type`, `line_item_operation`, `line_item_resource_id`, usage amount (`num`), unblended cost (`num`), period, hop. Note under the table that Cost Explorer dimensions `USAGE_TYPE`, `OPERATION` and `RESOURCE_ID` are the same fields.

- Operation rows come from the Step 2 `REGION` + `OPERATION` breakdown (see [traffic-attribution.md](traffic-attribution.md)). When a run only has the combined `PublicIP-In`/`PublicIP-Out` figure, show one row with operation `PublicIP-Out + PublicIP-In` and say it is combined.
- Resource rows (NAT Gateway ARNs) come from the resource-level pull and cover its 14-day window, not `month`. Label the period on every row.
- Never invent a row the run did not return; write "not queried in this run" in the cell instead.
- Resource IDs and usage types are AWS-returned strings: escape them (report-format.md rule 8).

## Cost bars per NAT Gateway

One `.bar-row` per NAT Gateway (largest attributed GB first), two tracks each: current and proposed, on **one shared $ scale** (the largest value across all rows maps to 100%), so a tiny current cost visibly looks tiny next to the endpoint's fixed cost.

- Current track segments: `seg-rdt` (`G x p_rdt`), `seg-nat` (`G x p_nat`), `seg-xaz` (`G x 2 x f x p_xaz`; when `f` is unknown, draw the worst case `f = 1` with the hatched style and say so).
- Proposed track segments: `seg-epgb` (`G x p_ep_gb`), `seg-ephr` (`A x E x p_ep_hr x 730`).
- Segment width = `value / scale_max x 100%`. Right column: the total in $, and a tier badge.
- Add a `.bar-key` legend: `<span style="--k:var(--red-500)">PublicIP (hop 4)</span>`, and so on for each segment.

## Break-even chart

An inline SVG line chart (`<svg class="vx-chart">`), for the diagram region, with cost per month on the y-axis against GB per month on the x-axis:

- `l-cur`: current, same AZ: `y = x (p_rdt + p_nat)`. `l-cur2` (dashed): current, all cross-AZ: `y = x (p_rdt + p_nat + 2 p_xaz)`.
- `l-prop`: proposed with one endpoint in one AZ: `y = p_ep_hr x 730 + x p_ep_gb`.
- `be` vertical lines at both break-evens: `p_ep_hr x 730 / (p_rdt + p_nat (+ 2 p_xaz) - p_ep_gb)`. Label them with the GB values.
- A `zone` rectangle right of the break-even marked "endpoint pays off".
- One `dot` per NAT Gateway in that region at `(G, current)`.
- x-axis range: `max(1.5 x same-AZ break-even, 1.1 x largest G)`.

Directly above the chart, put a `.callout` with the verdict in one sentence that quotes the numbers, for example: "Your busiest NAT Gateway sends 3.2 GB/month to in-region AWS services; one endpoint in one AZ breaks even at 112-162 GB/month, so no endpoint pays for itself today." Use `.callout.is-warn` when there is a positive saving to act on.

## KPI cards

In this order: NAT Gateways found · NAT data processing $ in `month` · estimated monthly saving (`is-ok` when $0, else tier colour) · VPCs missing gateway endpoints · accounts covered (`reachable / in scope`; `is-critical` when any failed).

## Markdown sibling

Markdown cannot carry the SVG. Use the hop table above (with per-region prices) in place of the diagram, the same CUR table, and a plain table of per-NAT current vs proposed totals in place of the bars and chart. Keep the verdict sentence.
