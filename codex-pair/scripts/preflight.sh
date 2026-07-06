#!/usr/bin/env bash
# preflight.sh — Step 0. Verify codex + tmux, resolve session dir, ensure
# .context/ is gitignored. Stdout contract (consumed by SKILL.md Step 0):
#   MISSING: codex-binary   → codex not on PATH (exit 0)
#   MISSING: tmux-session   → not inside tmux    (exit 0)
#   OK: codex=... tmux=... repo_root=... window=... session_dir=...
set -euo pipefail
. "$(dirname "$0")/lib.sh"

# Codex CLI must be on PATH
if [ -z "$CODEX_BIN" ]; then
  echo "MISSING: codex-binary"
  echo "Install: npm install -g @openai/codex"
  echo "Auth: codex login (uses your ChatGPT subscription)"
  exit 0
fi

# Must be inside tmux — the whole skill depends on panes
if [ -z "${TMUX:-}" ]; then
  echo "MISSING: tmux-session"
  echo "This skill requires Claude Code to be running inside a tmux pane."
  exit 0
fi

cx_resolve_context
mkdir -p "$SESSION_DIR/pending"

# Add .context/ to .gitignore if we're in a git repo AND a .gitignore
# already exists. Skip if .gitignore is absent — creating one is a bigger
# opinion than this skill should impose.
if [ -d "$REPO_ROOT/.git" ] && [ -f "$REPO_ROOT/.gitignore" ] \
   && ! grep -qE '^\.context/?$' "$REPO_ROOT/.gitignore"; then
  {
    echo ""
    echo "# Codex skill state (pane ID, session ID, transient prompts)"
    echo ".context/"
  } >> "$REPO_ROOT/.gitignore"
fi

echo "OK: codex=$CODEX_BIN tmux=$TMUX_BIN repo_root=$REPO_ROOT window=$WINDOW_ID session_dir=$SESSION_DIR"
