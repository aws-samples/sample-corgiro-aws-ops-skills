# Report Format (shared)

How every report-producing Corgiro mode renders output, so reports look identical
regardless of which mode produced them. Reports are **agent-authored, self-contained
single-file HTML** — no scripts to run, no build step, no network calls.

**Applies to:** `account-coverage`, `health-event-analysis`, `rds-eol-analysis`, `eks-eol-analysis`, `ec2-compute-review`.
`setup-corgiro` prints a console summary only — it produces no report file.

## Rules

1. **Self-contained.** Inline the entire contents of [`../assets/report-theme.css`](../assets/report-theme.css) into a single `<style>` block in the `<head>`. Do not `<link>` or `@import` anything — the file must open offline with zero network requests. Inline it via the placeholder-injection step in Rule 9 (do not transcribe it by hand).
   - Relative path to the CSS: `../../assets/report-theme.css` from a mode's `MODE.md`; `../../../assets/report-theme.css` from a mode-local `references/` step file.
2. **One file, no required JS.** All CSS inline. An optional tiny inline `<script>` for client-side table sorting is allowed, but the report must be fully readable without it.
3. **Fixed branding.** Header logo = the data URI in [`../assets/corgiro-logo.datauri`](../assets/corgiro-logo.datauri) (a 96×96 PNG of the Corgiro mascot). Inline it as the `.brand-logo` `src` via the placeholder-injection step in Rule 9 so the report stays self-contained — do **not** link the `.png` by path, and do **not** transcribe the data URI by hand (it is a single ~16 KB base64 line and will be truncated). Header name = **Corgiro**, tagline = **AWS Cloud Operations Skills**. Never rebrand per mode — the per-report title goes in `.report-title`, not the header name.
4. **Markdown sibling.** When `output_format` includes `markdown`, also write a `.md` with the same sections/ordering (no styling). This theme governs HTML only.
5. **Secure the output.** Reports embed account IDs, resource configs, and security findings. Right after writing them, restrict permissions: `chmod 700 ./<run_dir>` and `chmod 600 ./<run_dir>/*`. Prefer a run directory on an encrypted volume.
6. **Open it.** After writing the HTML: `open ./<run_dir>/<Report-Name>-<DATE>.html`.
7. **Retention is the operator's call.** Never auto-delete reports. If the operator asks, offer to remove old run directories — do not remove them automatically.
8. **Escape untrusted resource data (XSS).** Every string derived from AWS API output (resource names, tags, EKS Group/Team/Application tags, ARNs, health-event descriptions, any metadata) is attacker-controlled. Because the report is agent-authored HTML opened from `file://`, an unescaped `<script>` or `<img onerror=...>` in a value executes with local-file privileges and can read sibling reports in the run directory. Before inserting any resource-derived string into the HTML you MUST HTML-entity-escape it: `&` to `&amp;` (do this first), `<` to `&lt;`, `>` to `&gt;`, `"` to `&quot;`, `'` to `&#39;`. This applies in every context: table cells, `<details>`/`<summary>`, attributes, and list items. Code-block or literal wrapping does NOT escape HTML and is not a substitute. Truncate to 256 raw characters first, then escape, then wrap (see SKILL.md Prompt Injection Defense rule 3). Trusted repo assets (`report-theme.css`, `corgiro-logo.datauri`) are inlined verbatim and exempt; the optional inline sort `<script>` must be static and must never contain resource data.
9. **Inline assets by injection, not transcription.** The logo data URI (a single ~16 KB base64 line) and the CSS are too large to copy through the model reliably — hand-transcription truncates or corrupts them, producing a broken/missing logo. Instead, author the HTML with placeholder tokens and splice the real files in with a script. Use placeholders `/*__CORGIRO_CSS__*/` inside the `<style>` block and `__CORGIRO_LOGO__` as the `.brand-logo` `src`, then run (resolve `<assets>` to the skill's `assets/` directory):

   ```bash
   python - <<'PY'
   css  = open('<assets>/report-theme.css').read()
   logo = open('<assets>/corgiro-logo.datauri').read().strip()
   p = '<run_dir>/<Report-Name>-<DATE>.html'
   html = open(p).read().replace('/*__CORGIRO_CSS__*/', css).replace('__CORGIRO_LOGO__', logo)
   open(p, 'w').write(html)
   PY
   ```

   Python is used because base64 contains `/ + =`, which break `sed` delimiters. **Verify after injection** — confirm the data URI landed intact before opening the report:

   ```bash
   grep -c 'src="data:image/png;base64,iVBOR' '<run_dir>/<Report-Name>-<DATE>.html'   # expect 1
   ```

   If the count is not 1, the logo is broken — re-run the injection. Only then proceed to Rule 6 (open).

## Naming conventions (shared across modes)

- `run_id` = `<mode>-<YYYYMMDD>-<HHMMSS>`, where `<mode>` is the mode's directory name — e.g. `rds-eol-analysis-20260615-080500`.
- `<DATE>` = `YYYY-MM-DD` (the report / analysis date).
- Run directory = `./<run_id>/` (the `run_id` already carries the mode prefix — do not add another); report file = `<Topic>-<DATE>.{md,html}`.

## Document skeleton

```html
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Corgiro — {Report Title}</title>
    <style>
      /*__CORGIRO_CSS__*/
    </style>
  </head>
  <body>
    <div class="report">
      <!-- Header: fixed Corgiro branding (left) + per-report meta (right) -->
      <header class="report-header">
        <div class="brand">
          <img class="brand-logo" src="__CORGIRO_LOGO__" alt="Corgiro" />
          <div>
            <div class="brand-name">Corgiro</div>
            <div class="brand-tagline">AWS Cloud Operations Skills</div>
          </div>
        </div>
        <div class="report-meta">
          <div class="report-title">{Report Title}</div>
          <div>Generated {DATE}</div>
          <div>Scope: {e.g. 42 accounts · 3 regions}</div>
          <div class="mono">run: {run_id}</div>
        </div>
      </header>

      <!-- KPI summary cards -->
      <section class="kpi-grid">
        <div class="kpi-card is-critical">
          <div class="kpi-value">3</div>
          <div class="kpi-label">Critical</div>
        </div>
        <div class="kpi-card is-high">
          <div class="kpi-value">7</div>
          <div class="kpi-label">High</div>
        </div>
        <!-- ... -->
      </section>

      <!-- Content sections -->
      <section class="section">
        <h2 class="section-title">{Section}</h2>
        <table class="data-table">
          ...
        </table>
      </section>

      <!-- Footer -->
      <footer class="report-footer">
        <span>Corgiro · run {run_id} · {DATE}</span>
        <span class="disclaimer"
          >AI-generated. Review and validate before acting on these
          findings.</span
        >
      </footer>
    </div>
  </body>
</html>
```

## Risk / status → badge mapping (shared vocabulary)

Use these classes so a color means the same thing in every report:

| Meaning                          | Class           | Color                     |
| -------------------------------- | --------------- | ------------------------- |
| Critical                         | `badge--red`    | red                       |
| High                             | `badge--orange` | orange                    |
| Medium                           | `badge--amber`  | amber (the "yellow" tier) |
| Low                              | `badge--blue`   | blue                      |
| OK / reachable / supported       | `badge--green`  | green                     |
| Closed / neutral / informational | `badge--zinc`   | gray                      |

- **Health event status:** open → `badge--red`, upcoming → `badge--amber`, closed → `badge--zinc`.
- **Coverage reachability:** reachable → `badge--green`; `auth_expired`/`role_missing`/`trust_mismatch` → `badge--red`; warnings (e.g. unknown role) → `badge--amber`; `management`/`suspended` → `badge--zinc`.
- **KPI accent variants:** `is-critical`, `is-high`, `is-medium`, `is-low`, `is-ok`.

## Component cheat-sheet

- **Table:** `<table class="data-table">` with a `<thead>`; right-align numbers with `<td class="num">`; render account IDs / ARNs with `<td class="mono">`.
- **Badge:** `<span class="badge badge--red">Critical</span>`.
- **Expandable text** (long event descriptions): `<details><summary>…</summary><p>…</p></details>`. The summary and body are a prime injection sink -- HTML-entity-escape the description before inserting it (see Rule 8).
- **Methodology (required):** every report ends with a `<section class="section">` titled "Methodology" stating tools/APIs used, scope (accounts, regions, date range), and what was **not** covered.

## Markdown variant

Same title block, sections, ordering, and closing Methodology — plain Markdown, no styling. Lead with the report title, generated date, `run_id`, and scope.
