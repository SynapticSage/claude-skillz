#!/usr/bin/env bash
# classify.sh — decide how a given HTML file should reach the tablet.
#
# Claude emits two very different shapes of HTML and they want opposite pipelines:
#
#   diagram   layout-driven: flex/grid boxes, inline <svg>, arrows, few words.
#             The LAYOUT *is* the content. Converting it to Markdown flattens the
#             boxes into an unordered pile of text and drops the SVG — the signal
#             is destroyed and only the noise survives.  → render via Chrome
#
#   document  prose-driven: headings, paragraphs, tables.
#             Rendering it produces a fixed-width image-of-a-page: text too small
#             on a 157mm screen, unselectable, no reflow.  → pandoc → Typst
#
# Usage: classify.sh <html>
# Stdout: RENDER: <reason>   |   TEXT: <reason>
#
# THE DEFAULT IS `RENDER`, on purpose. The two errors are not symmetric:
# rendering a document is merely suboptimal (small text), but text-converting a
# diagram is unrecoverable (the diagram is gone). When the signals are ambiguous,
# take the lossless path.
set -euo pipefail

SRC="${1:?usage: classify.sh <html>}"
[ -r "$SRC" ] || { echo "FAIL: not readable: $SRC"; exit 0; }

python3 - "$SRC" <<'PY'
import re, sys

html = open(sys.argv[1], encoding="utf-8", errors="replace").read()

# Strip <script>/<style> before counting prose so a big JS blob or a long CSS
# block can't masquerade as body text.
body = re.sub(r"(?is)<(script|style)\b.*?</\1>", " ", html)

def n(p, s=None):
    return len(re.findall(p, s if s is not None else html, re.I))

layout   = n(r"display\s*:\s*(?:inline-)?flex") + n(r"display\s*:\s*(?:inline-)?grid") \
         + n(r"grid-template") + n(r"position\s*:\s*absolute")
graphics = n(r"<svg\b") + n(r"<canvas\b") + n(r"\bmermaid\b")
prose    = n(r"<p\b", body) + n(r"<h[1-6]\b", body) + n(r"<li\b", body) + n(r"<table\b", body)

# Visible-text density: how much of the file is words vs markup. Diagrams are
# markup-heavy (lots of styled divs, few words); documents are the reverse.
text  = re.sub(r"(?s)<[^>]+>", " ", body)
words = len(text.split())
ratio = words / max(len(html), 1)

sig = f"layout={layout} graphics={graphics} prose={prose} words={words} density={ratio:.3f}"

if graphics:
    print(f"RENDER: {graphics} inline graphic(s) — vector content pandoc would drop ({sig})")
elif layout >= 5:
    print(f"RENDER: {layout} layout containers — the layout carries the meaning ({sig})")
elif prose >= 10 and layout <= 2 and ratio > 0.02:
    print(f"TEXT: prose-shaped ({prose} blocks, {layout} layout) — reflows better as text ({sig})")
else:
    # Genuinely ambiguous. Choose the path that cannot destroy anything.
    print(f"RENDER: ambiguous — defaulting to lossless render ({sig})")
PY
