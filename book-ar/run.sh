#!/bin/bash
# run.sh — build chain for The Sourdough Framework: Arabic Edition
#
# Original: The Sourdough Framework by Hendrik Kleinwächter,
# the-sourdough-framework.com, CC BY-SA 4.0. The Arabic edition inherits
# CC BY-SA 4.0.
#
# Phase 28R reconstruction of the lost original, from the project record.
# Chain: lualatex -> biber -> lualatex x2 -> tounicode-fix.py.
# TEXINPUTS resolves the upstream support files (abbreviations.tex,
# colors.tex, figures/flowcharts_tikz.tex, references.bib, cover assets)
# from the sibling upstream checkout at ../book.
#
# Usage: ./run.sh [driver]            (default: book-ar)
#        ./run.sh smoke               (smoke build, no biber/overrides)

set -e
cd "$(dirname "$0")"

DRIVER="${1:-book-ar}"
export TEXINPUTS="../book:"
# biber does not honor TEXINPUTS; it needs BIBINPUTS to find
# ../book/references.bib (unit-5 session finding, 2026-11-15).
export BIBINPUTS="../book:"

lualatex -interaction=nonstopmode "$DRIVER.tex"
if [ "$DRIVER" != "smoke" ]; then
  biber "$DRIVER"
fi
lualatex -interaction=nonstopmode "$DRIVER.tex"
lualatex -interaction=nonstopmode "$DRIVER.tex"

if [ "$DRIVER" != "smoke" ]; then
  # Ruling 2026-11-15 (unit 5 relay): --require-overrides DROPPED. Under the
  # R1-FIGURES TikZ route the override fonts (/KMVOJZ+/YFXCFN+ Amiri subsets,
  # former rsvg SVG XObject artifacts) cannot exist by construction, so the
  # flag could only abort a correct build. The 0-CID / 0-unresolved report
  # below still runs and still catches silent font substitution.
  python3 tounicode-fix.py "$DRIVER.pdf"
else
  python3 tounicode-fix.py "$DRIVER.pdf"
fi

echo "build complete: $DRIVER.pdf"
