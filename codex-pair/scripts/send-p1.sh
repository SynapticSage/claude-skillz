#!/usr/bin/env bash
# send-p1.sh — Step 3B.1. Deliver a prompt to the Codex pane via bracketed
# paste (Phase 1 transport).
# Usage: send-p1.sh <prompt-file>   (prompt passed as a file so multi-line
#        text is delivered as one paste event, not line-by-line Enters)
# Stdout contract:
#   SENT: UUID=<8hex>
#   END_SENTINEL=§cx:<8hex>:E§
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cx_resolve_context
CODEX_PANE=$(cat "$SESSION_DIR/pane-id")

PROMPT_FILE="${1:?usage: send-p1.sh <prompt-file>}"
PROMPT_TEXT=$(cat "$PROMPT_FILE")

# Short sentinels — full UUIDs wrap in panes under ~45 cols and break
# grep -F. An 8-hex slice keeps the token <=20 chars, safe to ~30 cols.
UUID=$(uuidgen | tr -d '\n-' | tr '[:upper:]' '[:lower:]' | cut -c1-8)
START="§cx:${UUID}:S§"
END="§cx:${UUID}:E§"

WRAPPED=$(cat <<EOF
${START}
${PROMPT_TEXT}

When your response is complete, output this exact line (and nothing after it):
${END}
EOF
)

# Delivery via tmux paste-buffer with bracketed paste (-p). send-keys -l
# would type embedded newlines as Enter keypresses (submitting partial
# prompts); bracketed paste makes the TUI treat the block as one paste. The
# explicit Enter at the end is what submits.
BUF="codex-pair-$UUID"
TMPF=$(mktemp)
printf '%s' "$WRAPPED" > "$TMPF"
"$TMUX_BIN" load-buffer -b "$BUF" "$TMPF"
"$TMUX_BIN" paste-buffer -b "$BUF" -t "$CODEX_PANE" -p
"$TMUX_BIN" delete-buffer -b "$BUF"
rm -f "$TMPF"
sleep 1
"$TMUX_BIN" send-keys -t "$CODEX_PANE" Enter

echo "SENT: UUID=$UUID"
echo "END_SENTINEL=$END"
