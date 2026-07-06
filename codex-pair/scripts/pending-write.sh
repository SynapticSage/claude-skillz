#!/usr/bin/env bash
# pending-write.sh — Step 3A.2.a. Generate a req-id and persist the pending
# request record the gate and reply handler read.
# Usage: pending-write.sh <prompt-file>   (prompt passed as a file, not an
#        argument, so multi-line text never has to survive shell quoting)
# Stdout contract: REQ_ID=<8hex>
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cx_resolve_context
CODEX_PANE=$(cat "$SESSION_DIR/pane-id")

PROMPT_FILE="${1:?usage: pending-write.sh <prompt-file>}"
PROMPT_TEXT=$(cat "$PROMPT_FILE")

REQ_ID=$(uuidgen | tr -d '\n-' | tr '[:upper:]' '[:lower:]' | cut -c1-8)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Sanitized first 200 chars (no newlines that would break the JSON).
PROMPT_PREVIEW=$(printf '%s' "$PROMPT_TEXT" | tr '\n\r\t' ' ' | cut -c1-200)

cat > "$SESSION_DIR/pending/${REQ_ID}.json" <<EOF
{
  "req_id": "${REQ_ID}",
  "started_at": "${TS}",
  "prompt_preview": $(printf '%s' "$PROMPT_PREVIEW" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))'),
  "codex_pane": "${CODEX_PANE}",
  "window_id": "${WINDOW_ID}",
  "cc_pane": "${CC_PANE}"
}
EOF

echo "REQ_ID=$REQ_ID"
