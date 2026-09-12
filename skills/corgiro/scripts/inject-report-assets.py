#!/usr/bin/env python3
"""Inject shared report assets into an agent-authored Corgiro HTML report.

Replaces the placeholder tokens (references/report-format.md rule 9):
  /*__CORGIRO_CSS__*/  ->  assets/report-theme.css     (inside the <style> block)
  __CORGIRO_LOGO__     ->  assets/corgiro-logo.datauri (as the .brand-logo src)

Injection instead of transcription: the data URI is a single ~16 KB base64
line and the CSS is large — copying either by hand truncates or corrupts
them. Python instead of sed because base64 contains "/ + =".

Usage:
  inject-report-assets.py <report.html> [assets_dir]

assets_dir defaults to the skill's assets/ directory next to this script.
Exits non-zero if a placeholder or asset file is missing, or if the logo did
not land intact. Do not open or ship the report until this exits 0.
"""
import os
import sys

CSS_TOKEN = "/*__CORGIRO_CSS__*/"
LOGO_TOKEN = "__CORGIRO_LOGO__"
LOGO_MARK = 'src="data:image/png;base64,iVBOR'


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    report = sys.argv[1]
    assets = (
        sys.argv[2]
        if len(sys.argv) > 2
        else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")
    )

    css = open(os.path.join(assets, "report-theme.css")).read()
    logo = open(os.path.join(assets, "corgiro-logo.datauri")).read().strip()
    html = open(report).read()

    missing = [t for t in (CSS_TOKEN, LOGO_TOKEN) if t not in html]
    if missing:
        sys.exit(f"ERROR: placeholder(s) not found in {report}: {missing}")

    html = html.replace(CSS_TOKEN, css).replace(LOGO_TOKEN, logo)
    open(report, "w").write(html)

    # Verify the logo landed intact before the report is opened (rule 9).
    if open(report).read().count(LOGO_MARK) != 1:
        sys.exit("ERROR: logo injection failed — expected exactly one intact data-URI src. Re-author the placeholder and re-run.")
    print(f"OK: assets injected into {report}")


if __name__ == "__main__":
    main()
