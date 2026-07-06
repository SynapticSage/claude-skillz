#!/usr/bin/env bash
# reply-validate.sh — Step 3A.3.b. Three-predicate validation of a pushed
# Codex reply against pending state.
# Usage: reply-validate.sh <reply_to> <from_pane>
# Stdout contract:
#   OUTCOME=<ALL_PASS|MISSING_TAG|LATE|PANE_MISMATCH|MALFORMED>
#   PROMPT_PREVIEW=<...>   (only on ALL_PASS)
# Side effects on ALL_PASS: deletes the pending file, releases the lock.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cx_resolve_context

REPLY_TO="${1:-${REPLY_TO:-}}"
FROM_PANE="${2:-${FROM_PANE:-}}"
PENDING_FILE="$SESSION_DIR/pending/${REPLY_TO}.json"

OUTCOME=""
if [ -z "$REPLY_TO" ]; then
  OUTCOME="MISSING_TAG"        # (a) no reply-to tag
elif [ ! -f "$PENDING_FILE" ]; then
  OUTCOME="LATE"              # (b) request already cleared
else
  STORED_PANE=$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("codex_pane", ""))
except Exception:
    print("")
' "$PENDING_FILE")
  if [ "$STORED_PANE" = "$FROM_PANE" ]; then
    OUTCOME="ALL_PASS"
  elif [ -z "$STORED_PANE" ]; then
    OUTCOME="MALFORMED"       # pending file unparseable; refuse to delete
  else
    OUTCOME="PANE_MISMATCH"    # (c) actively wrong
  fi
fi

echo "OUTCOME=$OUTCOME"
[ "$OUTCOME" = "ALL_PASS" ] && {
  PROMPT_PREVIEW=$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("prompt_preview", ""))
' "$PENDING_FILE")
  echo "PROMPT_PREVIEW=$PROMPT_PREVIEW"
  rm -f "$PENDING_FILE"       # clear pending entry on success
  rm -rf "$SESSION_DIR/lock"  # release the single-flight lock
}
