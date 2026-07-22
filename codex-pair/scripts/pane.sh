#!/usr/bin/env bash
# pane.sh — Step 1. Attach to the cached Codex pane or spawn a new one.
# Reads flag-model / flag-effort (written by gate.sh). Stdout contract:
#   REUSING: %N                       → reused a live pane
#   STALE: %N (pane gone — respawning) → cached pane dead
#   SPAWNED: %N                        → fresh pane
#   CODEX_PANE=%N FRESH_SPAWN=<0|1>
# Side effects: writes pane-id, fresh-spawn; may write model-warning.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cx_resolve_context

PANE_FILE="$SESSION_DIR/pane-id"
PANE_MODEL_FILE="$SESSION_DIR/pane-model"   # what the live pane was SPAWNED with
CODEX_PANE=""
FRESH_SPAWN=0

# What this turn would launch with: the explicit flag if the gate recorded one,
# else the skill default (gpt-5.6-sol / high — see lib.sh). On a reused pane
# these are overwritten below by what the pane is ACTUALLY running.
MODEL="$(cx_flag "$SESSION_DIR/flag-model"   "$CX_DEFAULT_MODEL")"
EFFORT="$(cx_flag "$SESSION_DIR/flag-effort" "$CX_DEFAULT_EFFORT")"

if [ -f "$PANE_FILE" ]; then
  SAVED=$(cat "$PANE_FILE")
  if "$TMUX_BIN" list-panes -a -F '#{pane_id}' | grep -qFx "$SAVED"; then
    CODEX_PANE="$SAVED"
    echo "REUSING: $CODEX_PANE"
    # --model/--effort against a reused pane is dead weight (both are fixed at
    # spawn). Don't silent-drop — write a warning Step 5 surfaces. Keyed on the
    # flag FILES, not on MODEL/EFFORT: the defaults must not trip this, or every
    # reuse turn would warn about a switch the user never asked for.
    REQ=""
    [ -s "$SESSION_DIR/flag-model" ]  && REQ="--model $(cat "$SESSION_DIR/flag-model")"
    [ -s "$SESSION_DIR/flag-effort" ] && REQ="$REQ --effort $(cat "$SESSION_DIR/flag-effort")"
    if [ -n "$REQ" ]; then
      WARN="WARN:${REQ} ignored — pane $CODEX_PANE is being reused (codex fixes model and effort at spawn). To switch, kill the codex pane (codex /exit, or tmux kill-pane -t $CODEX_PANE) and re-invoke."
      echo "$WARN" >&2
      printf '%s\n' "$WARN" > "$SESSION_DIR/model-warning"
    fi
    # Report what the pane IS running, not what we'd have launched — otherwise
    # Step 5 would credit an answer to a model that never saw the prompt.
    if [ -s "$PANE_MODEL_FILE" ]; then
      read -r MODEL EFFORT < "$PANE_MODEL_FILE"
    else
      MODEL="unknown"; EFFORT="unknown"   # pane predates this bookkeeping
    fi
  else
    echo "STALE: $SAVED (pane gone — respawning)"
    rm -f "$PANE_FILE" "$PANE_MODEL_FILE"
  fi
fi

if [ -z "$CODEX_PANE" ]; then
  # Split the CC pane. -d keeps CC focused, -P -F prints the new pane id.
  # Launch $CODEX_BIN (absolute) so tmux-server PATH differences can't pick
  # the wrong codex. Empty-array expansion under set -u is unsafe on bash 3.2
  # (macOS default), so use the ${arr[@]+"${arr[@]}"} idiom.
  #
  # Model and effort are ALWAYS passed now (defaulted, not optional): leaving
  # them off meant the pane silently inherited whatever ~/.codex/config.toml
  # said, so "which model answered me?" had no answer at the call site.
  SPAWN_ARGS=(--model "$MODEL" -c "$(cx_effort_conf "$EFFORT")")
  CODEX_PANE=$("$TMUX_BIN" split-window -h -d -P -F '#{pane_id}' -t "$CC_PANE" "$CODEX_BIN" "${SPAWN_ARGS[@]}")
  echo "$CODEX_PANE" > "$PANE_FILE"
  printf '%s %s\n' "$MODEL" "$EFFORT" > "$PANE_MODEL_FILE"
  echo "SPAWNED: $CODEX_PANE"
  echo "  with: ${SPAWN_ARGS[*]}"
  FRESH_SPAWN=1
  # Codex takes a few seconds to boot its TUI. Give it time before sending.
  # (Overridable so the test suite doesn't pay 4s per spawn assertion.)
  sleep "${CX_SPAWN_SLEEP:-4}"
fi

# Step 5 reports these; they're the answer to "which model actually replied?"
echo "MODEL=$MODEL EFFORT=$EFFORT"

echo "$FRESH_SPAWN" > "$SESSION_DIR/fresh-spawn"
echo "CODEX_PANE=$CODEX_PANE FRESH_SPAWN=$FRESH_SPAWN"
