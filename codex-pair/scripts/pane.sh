#!/usr/bin/env bash
# pane.sh — Step 1. Attach to the cached Codex pane or spawn a new one.
# Reads flag-model (written by gate.sh). Stdout contract:
#   REUSING: %N                       → reused a live pane
#   STALE: %N (pane gone — respawning) → cached pane dead
#   SPAWNED: %N                        → fresh pane
#   CODEX_PANE=%N FRESH_SPAWN=<0|1>
# Side effects: writes pane-id, fresh-spawn; may write model-warning.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cx_resolve_context

PANE_FILE="$SESSION_DIR/pane-id"
CODEX_PANE=""
FRESH_SPAWN=0

if [ -f "$PANE_FILE" ]; then
  SAVED=$(cat "$PANE_FILE")
  if "$TMUX_BIN" list-panes -a -F '#{pane_id}' | grep -qFx "$SAVED"; then
    CODEX_PANE="$SAVED"
    echo "REUSING: $CODEX_PANE"
    # --model against a reused pane is dead weight (codex's model is fixed at
    # spawn). Don't silent-drop — write a warning Step 5 surfaces.
    if [ -s "$SESSION_DIR/flag-model" ]; then
      REQUESTED=$(cat "$SESSION_DIR/flag-model")
      WARN="WARN: --model $REQUESTED ignored — pane $CODEX_PANE is being reused (codex's model is fixed at spawn). To switch, kill the codex pane (codex /exit, or tmux kill-pane -t $CODEX_PANE) and re-invoke with --model."
      echo "$WARN" >&2
      printf '%s\n' "$WARN" > "$SESSION_DIR/model-warning"
    fi
  else
    echo "STALE: $SAVED (pane gone — respawning)"
    rm -f "$PANE_FILE"
  fi
fi

if [ -z "$CODEX_PANE" ]; then
  # Split the CC pane. -d keeps CC focused, -P -F prints the new pane id.
  # Launch $CODEX_BIN (absolute) so tmux-server PATH differences can't pick
  # the wrong codex. Empty-array expansion under set -u is unsafe on bash 3.2
  # (macOS default), so use the ${arr[@]+"${arr[@]}"} idiom.
  SPAWN_ARGS=()
  [ -s "$SESSION_DIR/flag-model" ] && SPAWN_ARGS+=("--model" "$(cat "$SESSION_DIR/flag-model")")
  CODEX_PANE=$("$TMUX_BIN" split-window -h -d -P -F '#{pane_id}' -t "$CC_PANE" "$CODEX_BIN" ${SPAWN_ARGS[@]+"${SPAWN_ARGS[@]}"})
  echo "$CODEX_PANE" > "$PANE_FILE"
  echo "SPAWNED: $CODEX_PANE"
  [ ${#SPAWN_ARGS[@]} -gt 0 ] && echo "  with: ${SPAWN_ARGS[*]}"
  FRESH_SPAWN=1
  # Codex takes a few seconds to boot its TUI. Give it time before sending.
  sleep 4
fi

echo "$FRESH_SPAWN" > "$SESSION_DIR/fresh-spawn"
echo "CODEX_PANE=$CODEX_PANE FRESH_SPAWN=$FRESH_SPAWN"
