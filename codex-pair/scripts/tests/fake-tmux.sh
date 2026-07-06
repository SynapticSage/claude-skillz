#!/usr/bin/env bash
# fake-tmux.sh — minimal tmux stub for unit tests. Handles only the
# display-message forms cx_resolve_context calls:
#   display-message -p '#{pane_id}'          → %1
#   display-message -p -t %X '#{window_id}'  → @1
# Any other subcommand is a no-op (the pure-logic scripts under test don't
# reach real tmux; the tmux-heavy scripts are covered by bash -n only).
case "${1:-}" in
  display-message)
    if printf '%s\n' "$@" | grep -q 'window_id'; then
      echo "@1"
    else
      echo "%1"
    fi
    ;;
  *)
    # Swallow anything else quietly so a stray call can't fail a test.
    exit 0
    ;;
esac
