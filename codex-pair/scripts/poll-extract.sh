#!/usr/bin/env bash
# poll-extract.sh — Step 3B.2. Poll the Codex pane until TWO END sentinels
# appear (my echoed END + Codex's emitted END), then extract the response
# between them.
# Usage: poll-extract.sh <end_sentinel>
# Stdout contract:
#   <response body>                              (success)
#   TIMEOUT: fewer than 2 END sentinels after 5min
#   EXTRACT_FAIL: fewer than 2 END sentinels
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cx_resolve_context
CODEX_PANE=$(cat "$SESSION_DIR/pane-id")
END="${1:?usage: poll-extract.sh <end_sentinel>}"

DEADLINE=$(( $(date +%s) + 300 ))

# Wait for TWO END occurrences, not one — breaking on the first aborts while
# Codex is still thinking (Codex review 2026-04-24 item 1/CRITICAL).
# `|| true` keeps a zero-match `grep -c` (exit 1) from tripping set -e.
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  COUNT=$("$TMUX_BIN" capture-pane -t "$CODEX_PANE" -p -J -S -5000 2>/dev/null | grep -cF "$END" || true)
  [ "$COUNT" -ge 2 ] && break
  sleep 2
done

CAPTURE=$("$TMUX_BIN" capture-pane -t "$CODEX_PANE" -p -J -S -5000)

if [ "$(printf '%s\n' "$CAPTURE" | grep -cF "$END" || true)" -lt 2 ]; then
  echo "TIMEOUT: fewer than 2 END sentinels after 5min"
  exit 0
fi

# Extract between the last two ENDs. LAST = Codex's echoed END; the one
# before it = the echo of my typed END; the body is the lines between.
END_LINES=()
while IFS= read -r n; do END_LINES+=("$n"); done \
  < <(printf '%s\n' "$CAPTURE" | grep -nF "$END" | cut -d: -f1)

if [ "${#END_LINES[@]}" -lt 2 ]; then
  echo "EXTRACT_FAIL: fewer than 2 END sentinels"
  RESPONSE=""
else
  if [ -n "${ZSH_VERSION:-}" ]; then
    LAST="${END_LINES[${#END_LINES[@]}]}"
    PREV="${END_LINES[$((${#END_LINES[@]}-1))]}"
  else
    LAST="${END_LINES[$((${#END_LINES[@]}-1))]}"
    PREV="${END_LINES[$((${#END_LINES[@]}-2))]}"
  fi
  RESPONSE=$(printf '%s\n' "$CAPTURE" | sed -n "$((PREV+1)),$((LAST-1))p")
fi

printf '%s\n' "$RESPONSE"
