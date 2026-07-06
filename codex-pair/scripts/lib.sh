#!/usr/bin/env bash
# lib.sh — shared environment resolution for codex-pair scripts.
#
# Source at the top of every codex-pair script:
#     . "$(dirname "$0")/lib.sh"
#
# This file encodes, ONCE, the environment logic that was previously
# copy-pasted into ~9 inline bash blocks in SKILL.md. That duplication was
# the root cause of the bug class in TODO.md #15/#16 (each fix had to land
# in every block). Centralizing it here means those invariants can no
# longer drift between call sites.

# TMUX_BIN — env-overridable so the test harness can stub tmux
# (TMUX_BIN=/path/to/fake-tmux). oh-my-zsh's `tmux` plugin replaces bare
# `tmux` with a shell function that does NOT exist in bash subshells, so we
# must resolve an absolute path. `command -v` works on Intel + Apple Silicon
# + Linux; the homebrew path is only a last-resort fallback (fixes A3: the
# old hardcoded /opt/homebrew path broke on non-Apple-Silicon hosts).
TMUX_BIN="${TMUX_BIN:-$(command -v tmux 2>/dev/null || echo /opt/homebrew/bin/tmux)}"
CODEX_BIN="${CODEX_BIN:-$(command -v codex 2>/dev/null || true)}"

# REPO_ROOT — anchor state to the repo root so .context/ doesn't fragment
# across subdirectory invocations. Falls back to CWD outside a repo.
# Overridable (the test harness points it at a temp dir for isolation).
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# mtime_s FILE — file mtime in epoch seconds, portable across BSD (macOS)
# and GNU (Linux) stat. Fixes A3's `stat -f %m` BSD-only assumption.
mtime_s() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# cx_resolve_context — set CC_PANE, WINDOW_ID, SESSION_DIR. Requires tmux to
# be reachable, so callers must confirm we're inside tmux first (preflight
# does). Kept as a function (not run on source) so preflight can emit its
# MISSING: messages before any tmux call under `set -euo pipefail`.
#
# Invariant #9: $TMUX_PANE isn't reliably inherited by CC's bash subshells;
#   fall back to the currently-active pane.
# Invariant #10: `-t` must precede the format string, or tmux parses it as a
#   positional arg and errors "too many arguments".
cx_resolve_context() {
  CC_PANE="${TMUX_PANE:-$("$TMUX_BIN" display-message -p '#{pane_id}')}"
  WINDOW_ID="$("$TMUX_BIN" display-message -p -t "$CC_PANE" '#{window_id}')"
  SESSION_DIR="$REPO_ROOT/.context/codex-pair/$WINDOW_ID"
}
