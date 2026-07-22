#!/usr/bin/env bash
# lib.sh — shared environment for the remarkable-* skills.
#
# Source at the top of every remarkable script:
#     . "$(dirname "$0")/lib.sh"
#
# Both front-ends — remarkable-md (markdown → typst → pdf) and remarkable-html
# (html → chrome → pdf) — end in the SAME upload ladder. That ladder is the
# hard-won part (UUID sidecars, xochitl restart, rmapi fallback), so it lives
# here exactly once. A firmware change is then one edit, not two.
#
# This directory is deliberately NOT a skill: it has no SKILL.md, so the skill
# loader skips it (same as skills/journal/, skills/tmux-bridge-mcp/).

have() { command -v "$1" >/dev/null 2>&1; }

# rm_chrome — resolve headless Chrome.
#
# Chrome is not one option among several; it is the ONLY renderer that handles
# the CSS grid/flex layouts Claude's diagrams are actually built from.
# wkhtmltopdf is often present and looks like a fallback, but its WebKit predates
# CSS grid and silently mangles those layouts — a wrong diagram is worse than no
# diagram, so we fail loudly rather than degrade to it.
rm_chrome() {
  [ -n "${CHROME_BIN:-}" ] && { printf '%s\n' "$CHROME_BIN"; return 0; }
  local c
  for c in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium" \
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
    "$(command -v google-chrome 2>/dev/null || true)" \
    "$(command -v chromium 2>/dev/null || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# rm_chrome_run — invoke Chrome headless, muting the benign macOS sandbox noise
# ("task_policy_set ... invalid argument") that Chrome prints on every run and
# that otherwise buries real errors.
rm_chrome_run() {
  local chrome; chrome="$(rm_chrome)" || { echo "MISSING: chrome" >&2; return 1; }
  "$chrome" --headless --disable-gpu --no-sandbox "$@" 2>&1 \
    | grep -vi 'task_policy_set\|DevTools listening\|bytes written' || true
}

# Page geometry. reMarkable 2's usable screen is ~157×209mm (A5-ish).
RM_PAGE_W_MM=157
RM_PAGE_H_MM=209
