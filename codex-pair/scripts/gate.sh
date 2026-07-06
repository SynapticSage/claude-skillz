#!/usr/bin/env bash
# gate.sh — Step 0.5 single-flight gate + flag dispatch.
# Usage: gate.sh "<raw skill args>"
# Stdout contract (consumed by SKILL.md Step 0.5):
#   RESET: ...          → --reset-pending handled (exit 0)
#   REBOOTSTRAP: ...    → --rebootstrap cleared state (continues)
#   UNHEALTHY: ...      → >=3 protocol violations (exit 0 unless --phase1/--rebootstrap)
#   HOLD: ...           → another invocation in flight (exit 0)
#   STALE_LOCK: ...     → took over an expired lock (continues)
#   STALE_PENDING: ...  → swept an old pending file (continues)
#   GATE: clear         → proceed to Step 1
# Side effects: writes flag-phase1, skill-args-rest, flag-model (or removes
#   it), removes model-warning, creates lock/.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cx_resolve_context

PENDING_DIR="$SESSION_DIR/pending"
LOCK_DIR="$SESSION_DIR/lock"
HEALTH_FILE="$SESSION_DIR/health.json"

# --- Flag dispatch (loop-based; fixes A4) ---
# Consumes leading flags in ANY order and any number, e.g.
#   --phase1 --model gpt-5.5 fix the bug
# leaving the prompt text in SKILL_ARGS_REST. The old single-`case` dispatch
# handled exactly one flag at position zero and swallowed the rest as prompt.
SKILL_ARGS="${1:-${SKILL_ARGS:-}}"
FLAG_RESET_PENDING=0
FLAG_REBOOTSTRAP=0
FLAG_PHASE1=0
FLAG_EXEC=0
MODEL_OVERRIDE=""

REST="$SKILL_ARGS"
while [ -n "$REST" ]; do
  case "$REST" in
    --reset-pending)      FLAG_RESET_PENDING=1; REST="" ;;
    "--reset-pending "*)  FLAG_RESET_PENDING=1; REST="${REST#--reset-pending }" ;;
    --rebootstrap)        FLAG_REBOOTSTRAP=1;   REST="" ;;
    "--rebootstrap "*)    FLAG_REBOOTSTRAP=1;   REST="${REST#--rebootstrap }" ;;
    --phase1)             FLAG_PHASE1=1;        REST="" ;;
    "--phase1 "*)         FLAG_PHASE1=1;        REST="${REST#--phase1 }" ;;
    --exec)               FLAG_EXEC=1;          REST="" ;;
    "--exec "*)           FLAG_EXEC=1;          REST="${REST#--exec }" ;;
    --model)              REST="" ;;   # --model with no value: ignore
    "--model "*)          tmp="${REST#--model }"
                          MODEL_OVERRIDE="${tmp%% *}"
                          if [ "$tmp" = "$MODEL_OVERRIDE" ]; then REST=""
                          else REST="${tmp#"$MODEL_OVERRIDE" }"; fi ;;
    *) break ;;   # first non-flag token → start of the prompt
  esac
done
SKILL_ARGS_REST="$REST"

# Handle --reset-pending early and exit cleanly.
if [ $FLAG_RESET_PENDING -eq 1 ]; then
  if [ -d "$PENDING_DIR" ]; then
    for f in "$PENDING_DIR"/*.json; do
      [ -e "$f" ] || continue
      echo "RESET: removing $(basename "$f")"
      rm -f "$f"
    done
  fi
  rm -rf "$LOCK_DIR"
  echo "RESET: pending cleared, lock removed. Skill exiting; re-invoke /codex-pair to use."
  exit 0
fi

# Handle --rebootstrap: clear bootstrap.json + health.json, fall through.
if [ $FLAG_REBOOTSTRAP -eq 1 ]; then
  rm -f "$SESSION_DIR/bootstrap.json" "$HEALTH_FILE"
  echo "REBOOTSTRAP: cleared bootstrap.json + health.json"
fi

# --- Proactive health check ---
# If the prior reply handler marked Phase 5 unhealthy (>=3 consecutive
# protocol violations), surface the banner before doing anything else.
if [ -f "$HEALTH_FILE" ]; then
  MISSES=$(python3 -c '
import json, sys
try: print(json.load(open(sys.argv[1])).get("phase5_consecutive_misses", 0))
except: print(0)
' "$HEALTH_FILE")
  if [ "$MISSES" -ge 3 ]; then
    echo "UNHEALTHY: Phase 5 has had ${MISSES} consecutive protocol violations."
    echo "  Codex may not be following the contract."
    echo "  Use /codex-pair --phase1 <prompt> to fall back, or"
    echo "      /codex-pair --rebootstrap to retry the handshake."
    [ $FLAG_PHASE1 -eq 0 ] && [ $FLAG_REBOOTSTRAP -eq 0 ] && exit 0
  fi
fi

# --- Single-flight via atomic mkdir ---
# mkdir is atomic on POSIX: exactly one caller wins. Runs BEFORE pane spawn
# so concurrent invocations cannot both spawn duplicate Codex panes.
LOCK_AGE_MAX_S=$(( 60 * 60 ))   # 60 min stale TTL
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  LOCK_AGE_S=$(( $(date +%s) - $(mtime_s "$LOCK_DIR" || echo 0) ))
  if [ "$LOCK_AGE_S" -lt "$LOCK_AGE_MAX_S" ]; then
    echo "HOLD: another /codex-pair is in flight in window $WINDOW_ID (lock ${LOCK_AGE_S}s old)"
    echo "  Use /codex-pair --reset-pending to clear, or wait."
    exit 0
  fi
  echo "STALE_LOCK: claiming lock (>${LOCK_AGE_MAX_S}s old)"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
fi

# Sweep stale pending files (separate from the lock; pending tracks
# individual requests, lock guards the whole turn).
NOW=$(date +%s)
if [ -d "$PENDING_DIR" ]; then
  for f in "$PENDING_DIR"/*.json; do
    [ -e "$f" ] || continue
    AGE_MIN=$(( ( NOW - $(mtime_s "$f") ) / 60 ))
    [ "$AGE_MIN" -ge 60 ] && { echo "STALE_PENDING: clearing $(basename "$f")"; rm -f "$f"; }
  done
fi

# Persist flag state for downstream steps to read.
echo "$FLAG_PHASE1"     > "$SESSION_DIR/flag-phase1"
echo "$FLAG_EXEC"       > "$SESSION_DIR/flag-exec"
echo "$SKILL_ARGS_REST" > "$SESSION_DIR/skill-args-rest"
# flag-model: only present when this turn requested an override. Cleared
# otherwise so a stale override from a previous turn never reanimates.
if [ -n "$MODEL_OVERRIDE" ]; then
  printf '%s\n' "$MODEL_OVERRIDE" > "$SESSION_DIR/flag-model"
else
  rm -f "$SESSION_DIR/flag-model"
fi
# model-warning is per-turn; always clear at the gate so a stale warning
# can't leak into a turn that didn't request --model.
rm -f "$SESSION_DIR/model-warning"

echo "GATE: clear"
