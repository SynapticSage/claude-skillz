#!/usr/bin/env bash
# render.sh — HTML → single-page, e-ink-friendly PDF via headless Chrome.
#
# Usage: render.sh <html> <out.pdf> [design-width-px]
# Stdout: RENDERED: <out.pdf> <W>x<H>px orientation=<portrait|landscape>
#         FAIL: <reason>
#
# TWO PASSES, and the second one is the whole trick:
#
#   pass 1 (measure)  Load the page and stamp its real content box into
#                     document.title, then read it back out of --dump-dom.
#                     Chrome will happily tell you the layout it computed; you
#                     just need somewhere to put the answer. No Puppeteer, no CDP.
#
#   pass 2 (render)   Set @page to EXACTLY that content box.
#
# Why pass 2 looks like cheating: the obvious approach — scale the diagram down
# onto a 157×209mm page — does not work. Chrome applies its own implicit
# shrink-to-fit, which compounds with any zoom/scale you set, and you land on a
# page that is mostly dead space with unreadably small text. The way out is to
# stop scaling: make the PAGE equal the CONTENT, so there is nothing to fit and
# nothing to clip. reMarkable then fits the page to its screen by itself — which
# is the one scaler in this pipeline that actually does the right thing.
set -euo pipefail
. "$(dirname "$0")/../../_remarkable/scripts/lib.sh"

SRC="${1:?usage: render.sh <html> <out.pdf> [width]}"
OUT="${2:?usage: render.sh <html> <out.pdf> [width]}"
WIDTH="${3:-1000}"   # design width. Narrower => less downscaling on-device => bigger text.

[ -r "$SRC" ] || { echo "FAIL: not readable: $SRC"; exit 0; }
rm_chrome >/dev/null || { echo "FAIL: no Chrome/Chromium found (set CHROME_BIN)"; exit 0; }

# RM_KEEP=1 preserves the intermediate measure/fit HTML for debugging the CSS
# that was actually injected — the pagination bugs in this pipeline are all
# "what did Chrome really see", and guessing at that is a waste of a afternoon.
W="$(mktemp -d -t rm-render.XXXXXX)"
[ "${RM_KEEP:-0}" = 1 ] || trap 'rm -rf "$W"' EXIT
[ "${RM_KEEP:-0}" = 1 ] && echo "KEEP: $W" >&2

# ── pass 1: measure ──────────────────────────────────────────────────────────
python3 - "$SRC" "$W/measure.html" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()

# The probe writes its answer to a data-attribute on <html>, NOT to document.title.
# Title looks like the obvious channel and is a trap: a React artifact sets its own
# title and silently clobbers the measurement (hit live on a real Claude artifact).
# React owns #root, never <html>, so an attribute there survives every re-render.
#
# It also POLLS rather than firing once on `load`: a client-rendered artifact has an
# empty body at load time, so a single measurement would size the page to nothing.
# Sample until the height stops changing (or we run out of budget), then stop.
probe = ('<script>(function(){var last=-1,stable=0;'
         'function s(){var e=document.documentElement,b=document.body;'
         'var w=Math.max(e.scrollWidth,b?b.scrollWidth:0),'
         'h=Math.max(e.scrollHeight,b?b.scrollHeight:0);'
         'if(h===last){stable++}else{stable=0;last=h}'
         'e.setAttribute("data-rmfit",w+"x"+h);'
         'if(stable<3){setTimeout(s,120)}}'
         's();})();</script>')
out = src.replace("</head>", probe + "</head>", 1) if "</head>" in src else probe + src
open(sys.argv[2], "w", encoding="utf-8").write(out)
PY

MEAS="$(rm_chrome_run --virtual-time-budget=10000 --window-size="$WIDTH",900 \
        --dump-dom "file://$W/measure.html" | grep -o 'data-rmfit="[0-9]*x[0-9]*"' | head -1 || true)"
MEAS="${MEAS#data-rmfit=\"}"; MEAS="${MEAS%\"}"
[ -n "$MEAS" ] || { echo "FAIL: could not measure content (page may not have rendered)"; exit 0; }

CW="${MEAS#RMFIT:}"; CW="${CW%x*}"
CH="${MEAS#*x}"
[ "$CW" -gt 0 ] 2>/dev/null && [ "$CH" -gt 0 ] 2>/dev/null || { echo "FAIL: bad measurement: $MEAS"; exit 0; }

# ── pass 2: render with page == content box ──────────────────────────────────
MODE="$(python3 - "$SRC" "$W/fit.html" "$CW" "$CH" "$RM_PAGE_W_MM" "$RM_PAGE_H_MM" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
dst, cw, ch = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
page_w_mm, page_h_mm = float(sys.argv[5]), float(sys.argv[6])

# Slack: scrollWidth rounds down and ignores a box's outer border/shadow, which
# shaved a hairline off the right-hand column in testing. A few px of headroom
# costs nothing and prevents a clipped edge.
cw += 16; ch += 16

# How tall may ONE page be, if it is to have reMarkable's aspect at this width?
aspect_h = round(cw * (page_h_mm / page_w_mm))

if ch <= aspect_h:
    # FIT — content is roughly page-shaped (a diagram). Make the page exactly the
    # content box: no clipping, no pagination, and no wasted margin. The device
    # scales it to the screen.
    pw, ph, mode = cw, ch, "fit"
else:
    # FLOW — content is far taller than a page (a long doc that happens to contain
    # diagrams). One giant page would shrink to illegibility on-device, so paginate
    # instead — but at pages of the CONTENT's width and the DEVICE's aspect, so
    # every page still fills the screen at a consistent, readable scale.
    pw, ph, mode = cw, aspect_h, "flow"

css = f'''<style id="rm-fit">
  /* e-ink has no backlight: force the light variant even if the page ships a
     prefers-color-scheme dark theme, which would otherwise print as a black slab. */
  :root {{ color-scheme: light only !important; }}
  @page {{ size: {pw}px {ph}px; margin: 0; }}
  html, body {{
    background: #fff !important;
    width: {cw}px !important;
    margin: 0 !important; padding: 8px !important;
  }}
  /* Shadows and gradients dither into muddy noise on a 16-level grayscale panel
     and cost contrast the strokes need. Flatten them. */
  * {{ box-shadow: none !important; text-shadow: none !important; }}
  /* Chrome's print pipeline drops backgrounds by default; diagrams are mostly
     background fills, so this is load-bearing rather than cosmetic. */
  * {{ -webkit-print-color-adjust: exact !important; print-color-adjust: exact !important; }}
  /* Never slice a box across a page break — a half-diagram is worse than a
     page with some slack at the bottom. Only matters in flow mode. */
  section, article, figure, table, svg, pre {{ break-inside: avoid !important; }}
</style>'''
out = src.replace("</head>", css + "</head>", 1) if "</head>" in src else css + src
open(dst, "w", encoding="utf-8").write(out)
print(f"{mode} {pw} {ph}")
PY
)"
read -r FITMODE PW PH <<< "$MODE"

rm_chrome_run --no-pdf-header-footer --virtual-time-budget=5000 \
  --print-to-pdf="$OUT" "file://$W/fit.html" >/dev/null
[ -s "$OUT" ] || { echo "FAIL: chrome produced no PDF"; exit 0; }

ORIENT=portrait; [ "$PW" -gt "$PH" ] && ORIENT=landscape
echo "RENDERED: $OUT mode=$FITMODE page=${PW}x${PH}px content=${CW}x${CH}px orientation=$ORIENT"
