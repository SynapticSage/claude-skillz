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
# Usage: exec.sh <prompt-file> [--model <m>] [--effort <e>]
# Stdout contract:
#   <response body>        success (the agent's final message)
#   EXEC_FAIL: <reason>    failure
#   INVALID_MODEL: ...     unknown model/effort — nothing was sent
#   INVALID_EFFORT: ...
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ -n "$CODEX_BIN" ] || { echo "EXEC_FAIL: codex not on PATH"; exit 0; }

# This transport needs a codex with an `exec` subcommand — strictly more than
# "a codex exists". Probing beats trusting PATH order: the first codex on PATH
# is often a stale major that would fail here with an opaque rc=1 (TODO #171).
CODEX_EXEC_BIN="$(cx_exec_bin || true)"
if [ -z "$CODEX_EXEC_BIN" ]; then
  echo "EXEC_FAIL: no codex on this machine supports \`codex exec\`"
  echo "  probed: $(cx_codex_candidates | tr '\n' ' ')"
  echo "  fix:    npm install -g @openai/codex@latest"
  echo "  or:     pin a known-good binary with CODEX_BIN=/path/to/codex"
  echo "  note:   the tmux pane transports still work — they only need the TUI."
  exit 0
fi

# Exec state is per-repo (not per-tmux-window — there's no window here).
SESSION_DIR="$REPO_ROOT/.context/codex-pair/exec"
mkdir -p "$SESSION_DIR"
SID_FILE="$SESSION_DIR/thread-id"
LASTMSG="$SESSION_DIR/last-message.txt"
EVENTS="$SESSION_DIR/events.jsonl"
ERRLOG="$SESSION_DIR/stderr.log"

PROMPT_FILE="${1:?usage: exec.sh <prompt-file> [--model <m>] [--effort <e>]}"
shift

# --- model / effort resolution -----------------------------------------------
# Precedence: explicit flag > this turn's gate flags > skill default.
#
# The middle rung matters. `--exec` used to bypass the gate, so the model
# arrived here as a positional the CALLER typed from memory — unvalidated, with
# no slot for effort. That is how "gpt-5.6-sol-high" was born and how it reached
# the API. Now the gate persists validated flags and we read them, and anything
# that still reaches the CLI is checked below.
MODEL=""; EFFORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model)  MODEL="${2:-}";  shift 2 || true ;;
    --effort) EFFORT="${2:-}"; shift 2 || true ;;
    *) echo "EXEC_FAIL: unknown arg '$1' (usage: exec.sh <prompt-file> [--model <m>] [--effort <e>])"; exit 0 ;;
  esac
done

# In tmux the gate ran this turn: it validated and persisted the flags, and it
# holds the single-flight lock. Resolve that window dir once — we both READ the
# flags from it and must RELEASE THE LOCK on the way out.
#
# cx_resolve_context runs in a SUBSHELL on purpose: it sets SESSION_DIR to the
# tmux *window* dir, and this script has already bound SESSION_DIR to the *exec*
# state dir above. Isolating it keeps that one name meaning one thing.
WIN_DIR=""
if [ -n "${TMUX:-}" ] && [ -n "$TMUX_BIN" ]; then
  WIN_ID="$(cx_resolve_context 2>/dev/null && printf '%s' "$WINDOW_ID" || true)"
  [ -n "$WIN_ID" ] && WIN_DIR="$REPO_ROOT/.context/codex-pair/$WIN_ID"
fi

# Release the gate's lock on EVERY exit path. The pane transports release it in
# reply-validate.sh (3A.3) when the reply lands; exec has NO reply handler — it's
# synchronous, so the request ends when this script returns. Without this, an
# --exec turn leaves the lock held and HOLDs the next invocation for the full
# 60-min TTL. (A trap, not a tidy line at the bottom: EXEC_FAIL and INVALID_*
# both exit early, and a turn that failed must not hold the lock either.)
if [ -n "$WIN_DIR" ]; then
  trap 'rm -rf "$WIN_DIR/lock"' EXIT
fi

if [ -n "$WIN_DIR" ]; then
  if [ -z "$MODEL" ];  then MODEL="$(cx_flag  "$WIN_DIR/flag-model"  "")";  fi
  if [ -z "$EFFORT" ]; then EFFORT="$(cx_flag "$WIN_DIR/flag-effort" "")"; fi
fi

MODEL="${MODEL:-$CX_DEFAULT_MODEL}"
EFFORT="${EFFORT:-$CX_DEFAULT_EFFORT}"
cx_validate model  "$MODEL"  || exit 0
cx_validate effort "$EFFORT" || exit 0

# codex exposes no --reasoning-effort flag; effort rides -c (see lib.sh).
MODEL_ARGS=(-m "$MODEL" -c "$(cx_effort_conf "$EFFORT")")
# stderr, not stdout — stdout is the verbatim response body.
echo "MODEL=$MODEL EFFORT=$EFFORT" >&2

# exec_err — the reason a failed run failed, in one line.
# codex reports API errors as {"type":"error"} events on STDOUT (the --json
# stream), NOT on stderr — so the obvious `tail -1 $ERRLOG` reports nothing and
# every failure looked like a contentless `rc=1 ()`. That silence is what made
# the bad-model-string bug so hard to see. Read the event stream first.
exec_err() {
  python3 - "$EVENTS" "$ERRLOG" <<'PY' 2>/dev/null || true
import json, sys
msg = ""
try:
    for line in open(sys.argv[1]):
        try: ev = json.loads(line)
        except Exception: continue
        if ev.get("type") in ("error", "turn.failed"):
            m = ev.get("message") or ev.get("error", {}).get("message", "")
            try: m = json.loads(m)["error"]["message"]   # nested API error blob
            except Exception: pass
            if m: msg = " ".join(str(m).split())
except Exception:
    pass
if not msg:
    try: msg = open(sys.argv[2]).read().strip().splitlines()[-1]
    except Exception: msg = "no error detail; see the logs below"
print(msg)
PY
}

: > "$LASTMSG"
# Prompt via stdin (`-`) avoids arg-length and quoting limits. --json gives the
# event stream (for the thread id); -o writes the clean final message. Resume if
# we already have a thread id, else start a fresh session.
if [ -s "$SID_FILE" ]; then
  SID="$(cat "$SID_FILE")"
  set +e
  "$CODEX_EXEC_BIN" exec resume "$SID" --skip-git-repo-check "${MODEL_ARGS[@]}" \
      --json -o "$LASTMSG" - < "$PROMPT_FILE" > "$EVENTS" 2>"$ERRLOG"
  rc=$?; set -e
  [ $rc -eq 0 ] || { echo "EXEC_FAIL: codex exec resume rc=$rc — $(exec_err)"; exit 0; }
else
  set +e
  "$CODEX_EXEC_BIN" exec --skip-git-repo-check "${MODEL_ARGS[@]}" \
      --json -o "$LASTMSG" - < "$PROMPT_FILE" > "$EVENTS" 2>"$ERRLOG"
  rc=$?; set -e
  [ $rc -eq 0 ] || { echo "EXEC_FAIL: codex exec rc=$rc — $(exec_err)"; exit 0; }
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
