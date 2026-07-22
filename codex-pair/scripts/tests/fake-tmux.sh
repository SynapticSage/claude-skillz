#!/usr/bin/env bash
# fake-tmux.sh — minimal tmux stub for unit tests.
#
#   display-message -p '#{pane_id}'          → %1
#   display-message -p -t %X '#{window_id}'  → @1
#   list-panes -a -F '#{pane_id}'            → contents of $CX_TEST_PANES (else nothing)
#   split-window ... <cmd> <args...>         → %9, and appends the full argv to
#                                              $CX_TEST_SPAWN_LOG
#
# split-window is recorded rather than swallowed so the tests can assert on the
# EXACT codex command line pane.sh builds — the model/effort args are the thing
# that used to be wrong, and only the argv proves them right.
# Any other subcommand is a quiet no-op.
case "${1:-}" in
  display-message)
    if printf '%s\n' "$@" | grep -q 'window_id'; then
      echo "@1"
    else
      echo "%1"
    fi
    ;;
  list-panes)
    [ -n "${CX_TEST_PANES:-}" ] && printf '%s\n' "$CX_TEST_PANES"
    ;;
  split-window)
    [ -n "${CX_TEST_SPAWN_LOG:-}" ] && printf '%s\n' "$*" >> "$CX_TEST_SPAWN_LOG"
    echo "%9"
    ;;
  *)
    # Swallow anything else quietly so a stray call can't fail a test.
    exit 0
    ;;
esac
