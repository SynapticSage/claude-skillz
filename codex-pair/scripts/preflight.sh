#!/usr/bin/env bash
# preflight.sh — Step 0. Verify codex + tmux, resolve session dir, ensure
# .context/ is gitignored. Stdout contract (consumed by SKILL.md Step 0):
#   MISSING: codex-binary   → codex not on PATH (exit 0)
#   MISSING: tmux-session   → not inside tmux    (exit 0)
#   OK: codex=... tmux=... repo_root=... window=... session_dir=... exec_bin=...
#     exec_bin=<path>  a codex supporting `codex exec` (Step 3C available)
#     exec_bin=none    no codex here has `exec`; 3C unavailable, panes still fine
#                      (followed by NOTE: lines explaining the fix)
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

# Report exec capability, but do NOT gate on it: the pane transports drive the
# interactive TUI and are perfectly happy on a codex with no `exec` subcommand.
# Surfacing it here means a version split is diagnosed at Step 0 rather than
# blowing up mid-consult with an opaque rc=1 (TODO #171).
EXEC_BIN="$(cx_exec_bin || true)"

echo "OK: codex=$CODEX_BIN tmux=$TMUX_BIN repo_root=$REPO_ROOT window=$WINDOW_ID session_dir=$SESSION_DIR exec_bin=${EXEC_BIN:-none}"

if [ -z "$EXEC_BIN" ]; then
  echo "NOTE: exec transport unavailable — no codex here supports \`codex exec\`."
  echo "      Pane transports (Phase 1 / Phase 5) are unaffected."
  echo "      To enable it: npm install -g @openai/codex@latest"
fi
