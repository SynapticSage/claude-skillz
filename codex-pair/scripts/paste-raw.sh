#!/usr/bin/env bash
# paste-raw.sh — deliver a file's contents to the Codex pane via bracketed
# paste + Enter, with NO sentinel wrapping. Used to deliver the Phase 5
# bootstrap preamble (send-p1.sh is the sentinel-wrapped Phase 1 variant;
# the bootstrap must NOT carry sentinels — Codex doesn't know the bridge yet).
# Usage: paste-raw.sh <file>
# Stdout contract: PASTED: <file>
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cx_resolve_context
CODEX_PANE=$(cat "$SESSION_DIR/pane-id")
SRC="${1:?usage: paste-raw.sh <file>}"

BUF="codex-pair-raw-$$"
"$TMUX_BIN" load-buffer -b "$BUF" "$SRC"
"$TMUX_BIN" paste-buffer -b "$BUF" -t "$CODEX_PANE" -p
"$TMUX_BIN" delete-buffer -b "$BUF"
sleep 1
"$TMUX_BIN" send-keys -t "$CODEX_PANE" Enter

echo "PASTED: $SRC"
