#!/usr/bin/env bash
# exec.sh — "exec" transport: run Codex non-interactively via `codex exec`.
# No tmux, no pane, no sentinels, no bootstrap — synchronous request/response.
# Persists the thread id and resumes it on later calls so multi-turn
# continuity works without a live pane.
#
# Verified against codex-cli 0.139.0 (2026-07-06): `codex exec --json -o <file>`
# writes the final agent message to <file>; the session id is the top-level
# `thread_id` in the JSONL event stream; `codex exec resume <thread_id>`
# carries prior context (confirmed with a two-call recall test).
#
# Usage: exec.sh <prompt-file> [model]
# Stdout contract:
#   <response body>       success (the agent's final message)
#   EXEC_FAIL: <reason>   failure
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ -n "$CODEX_BIN" ] || { echo "EXEC_FAIL: codex not on PATH"; exit 0; }

# Exec state is per-repo (not per-tmux-window — there's no window here).
SESSION_DIR="$REPO_ROOT/.context/codex-pair/exec"
mkdir -p "$SESSION_DIR"
SID_FILE="$SESSION_DIR/thread-id"
LASTMSG="$SESSION_DIR/last-message.txt"
EVENTS="$SESSION_DIR/events.jsonl"
ERRLOG="$SESSION_DIR/stderr.log"

PROMPT_FILE="${1:?usage: exec.sh <prompt-file> [model]}"
MODEL="${2:-}"
MODEL_ARGS=()
[ -n "$MODEL" ] && MODEL_ARGS+=("-m" "$MODEL")

: > "$LASTMSG"
# Prompt via stdin (`-`) avoids arg-length and quoting limits. --json gives the
# event stream (for the thread id); -o writes the clean final message. Resume if
# we already have a thread id, else start a fresh session.
if [ -s "$SID_FILE" ]; then
  SID="$(cat "$SID_FILE")"
  set +e
  "$CODEX_BIN" exec resume "$SID" --skip-git-repo-check ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
      --json -o "$LASTMSG" - < "$PROMPT_FILE" > "$EVENTS" 2>"$ERRLOG"
  rc=$?; set -e
  [ $rc -eq 0 ] || { echo "EXEC_FAIL: codex exec resume rc=$rc ($(tail -1 "$ERRLOG" 2>/dev/null))"; exit 0; }
else
  set +e
  "$CODEX_BIN" exec --skip-git-repo-check ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
      --json -o "$LASTMSG" - < "$PROMPT_FILE" > "$EVENTS" 2>"$ERRLOG"
  rc=$?; set -e
  [ $rc -eq 0 ] || { echo "EXEC_FAIL: codex exec rc=$rc ($(tail -1 "$ERRLOG" 2>/dev/null))"; exit 0; }
fi

# Persist the thread id (top-level `thread_id` in the JSONL) for next-turn resume.
NEWSID="$(python3 - "$EVENTS" <<'PY'
import json, sys
sid = ""
try:
    for line in open(sys.argv[1]):
        line = line.strip()
        if not line: continue
        try: ev = json.loads(line)
        except Exception: continue
        if isinstance(ev, dict) and isinstance(ev.get("thread_id"), str):
            sid = ev["thread_id"]
    print(sid)
except Exception:
    print("")
PY
)"
[ -n "$NEWSID" ] && printf '%s\n' "$NEWSID" > "$SID_FILE"

if [ -s "$LASTMSG" ]; then
  cat "$LASTMSG"
else
  echo "EXEC_FAIL: no final message captured (see $ERRLOG)"
fi
