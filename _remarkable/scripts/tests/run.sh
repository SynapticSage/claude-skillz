#!/usr/bin/env bash
# run.sh — tests for the remarkable-* skills (shared lib + uploader + html front end).
#   1. bash -n on every script
#   2. shellcheck if present
#   3. classifier routing (incl. the non-destructive default)
#   4. renderer: measure → fit/flow, on real HTML, asserting NON-BLANK output
#
# The blank-page assertion is not ceremony: an early version emitted a perfectly
# well-formed PDF with the right page count and page size and NOTHING on it
# (pass 2 read the file *path* instead of the file *contents*). Page count and
# page size both looked plausible. Only extractable text caught it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SHARED="$(cd "$HERE/.." && pwd)"
HTML="$(cd "$SHARED/../../remarkable-html/scripts" && pwd)"

FAILS=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS+1)); }
check()    { [ "$2" = "$3" ] && pass "$1" || fail "$1 (want [$2] got [$3])"; }
contains() { case "$3" in *"$2"*) pass "$1";; *) fail "$1 (missing [$2])";; esac; }

echo "== 1. syntax =="
for f in "$SHARED"/*.sh "$HTML"/*.sh "$0"; do
  bash -n "$f" 2>/dev/null && pass "$(basename "$f")" || fail "$(basename "$f") syntax"
done

echo "== 2. shellcheck (if present) =="
if command -v shellcheck >/dev/null 2>&1; then
  for f in "$SHARED"/*.sh "$HTML"/*.sh; do
    shellcheck -e SC1090,SC1091,SC2086 "$f" >/dev/null 2>&1 \
      && pass "shellcheck $(basename "$f")" || fail "shellcheck $(basename "$f")"
  done
else
  echo "  (not installed — skipped)"
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "== 3. classify.sh routing =="
# A diagram: layout-driven, no prose. Must RENDER (converting it would destroy it).
{ echo '<html><head></head><body>'
  for i in $(seq 1 8); do echo "<div style=\"display:flex\"><div style=\"display:grid\">b$i</div></div>"; done
  echo '</body></html>'; } > "$WORK/diagram.html"
contains "layout-heavy → RENDER" "RENDER:" "$(bash "$HTML/classify.sh" "$WORK/diagram.html")"

# Inline SVG must RENDER even with little else — pandoc would drop the vector.
printf '<html><head></head><body><svg><circle r="1"/></svg><p>hi</p></body></html>' > "$WORK/svg.html"
contains "inline <svg> → RENDER" "RENDER:" "$(bash "$HTML/classify.sh" "$WORK/svg.html")"

# Prose: reflows better as text, so TEXT.
{ echo '<html><head></head><body><h1>R</h1>'
  for i in $(seq 1 12); do echo "<h2>S$i</h2><p>Some analysis prose about the subsystem under load, at length.</p><li>x</li>"; done
  echo '</body></html>'; } > "$WORK/prose.html"
contains "prose-shaped → TEXT" "TEXT:" "$(bash "$HTML/classify.sh" "$WORK/prose.html")"

# THE IMPORTANT ONE: ambiguous input must NOT take the destructive path.
printf '<html><head></head><body><div>a</div></body></html>' > "$WORK/amb.html"
contains "ambiguous → RENDER (non-destructive default)" "RENDER:" \
  "$(bash "$HTML/classify.sh" "$WORK/amb.html")"

echo "== 4. render.sh (needs Chrome) =="
if ! bash -c '. '"$SHARED"'/lib.sh; rm_chrome >/dev/null'; then
  echo "  (no Chrome — skipped)"
else
  # Page-shaped content → fit: exactly one page bounding the content.
  printf '<html><head><style>body{width:800px}</style></head><body><div style="display:flex;height:700px">DIAGRAM CONTENT HERE</div></body></html>' > "$WORK/fit.html"
  out="$(bash "$HTML/render.sh" "$WORK/fit.html" "$WORK/fit.pdf" 2>&1)"
  contains "page-shaped → mode=fit" "mode=fit" "$out"
  check "fit → 1 page" "1" "$(pdfinfo "$WORK/fit.pdf" 2>/dev/null | awk '/^Pages/{print $2}')"

  # Tall content → flow: paginated, never one unreadable giant page.
  { echo '<html><head></head><body>'
    for i in $(seq 1 60); do echo "<p>Paragraph $i with enough text to build real height on the page.</p>"; done
    echo '</body></html>'; } > "$WORK/tall.html"
  out="$(bash "$HTML/render.sh" "$WORK/tall.html" "$WORK/tall.pdf" 2>&1)"
  contains "tall → mode=flow" "mode=flow" "$out"
  pages="$(pdfinfo "$WORK/tall.pdf" 2>/dev/null | awk '/^Pages/{print $2}')"
  [ "${pages:-0}" -gt 1 ] && pass "flow → paginates (${pages}p)" || fail "flow → expected >1 page, got ${pages:-0}"

  # NOT BLANK. The regression that page-count alone could not see.
  chars="$(pdftotext "$WORK/tall.pdf" - 2>/dev/null | tr -d '[:space:]' | wc -c | tr -d ' ')"
  [ "${chars:-0}" -gt 100 ] && pass "output has real text (${chars} chars)" \
    || fail "output is BLANK (${chars:-0} chars) — pass 2 likely not reading file contents"

  # JS-rendered content must be measured AFTER it paints, and a page that
  # overwrites document.title must not break the probe (both hit live).
  printf '<html><head><title>orig</title></head><body><div id="r"></div><script>document.title="APP OVERWROTE IT";var d=document.getElementById("r");for(var i=0;i<40;i++){var p=document.createElement("p");p.textContent="js generated line "+i;d.appendChild(p);}</script></body></html>' > "$WORK/js.html"
  out="$(bash "$HTML/render.sh" "$WORK/js.html" "$WORK/js.pdf" 2>&1)"
  contains "JS-rendered page measures" "RENDERED:" "$out"
  jc="$(pdftotext "$WORK/js.pdf" - 2>/dev/null | grep -c 'js generated line' || true)"
  [ "${jc:-0}" -gt 10 ] && pass "JS-generated content captured (${jc} lines)" \
    || fail "JS content missing (${jc:-0} lines) — probe fired before paint?"
fi

echo "== 5. upload.sh (manual transport, no tablet needed) =="
printf '%%PDF-1.4\n' > "$WORK/x.pdf"
out="$(HOME="$WORK" bash "$SHARED/upload.sh" "$WORK/x.pdf" "TestDoc" manual 2>&1 || true)"
contains "manual → STAGED (not success)" "STAGED: manual" "$out"
out="$(bash "$SHARED/upload.sh" "$WORK/x.pdf" "T" bogus-transport 2>&1 || true)"
contains "unknown transport → FAIL" "FAIL: unknown transport" "$out"
out="$(bash "$SHARED/upload.sh" "$WORK/nope.pdf" "T" manual 2>&1 || true)"
contains "missing pdf → FAIL" "FAIL: pdf not readable" "$out"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL TESTS PASSED"; exit 0
else echo "$FAILS ASSERTION(S) FAILED"; exit 1; fi
