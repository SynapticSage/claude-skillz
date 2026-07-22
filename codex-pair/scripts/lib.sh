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

# ── model policy ─────────────────────────────────────────────────────────────
# The ONE place that knows which model/effort this skill hands to codex.
#
# Why an allow-list at all: the model string used to be free text that flowed
# gate → pane/exec → the API, where a bad one died as an opaque error. And
# because codex exposes NO effort flag (it rides `-c` below), a caller who
# wanted effort had nowhere to put it — so it got smuggled into the model name
# ("gpt-5.6-sol-high"). Both holes are closed here: effort gets its own channel,
# and neither value reaches codex unvalidated.
#
# Refresh after a codex upgrade adds models (values are the embedded catalog's):
#   B=$(npm root -g)/@openai/codex/node_modules/@openai/codex-*/vendor/*/bin/codex
#   strings $B | grep -oE '"(slug|effort)": "[^"]+"' | sort -u
# Verified against codex-cli 0.144.1 (2026-07-12).
CX_DEFAULT_MODEL="${CX_DEFAULT_MODEL:-gpt-5.6-sol}"
CX_DEFAULT_EFFORT="${CX_DEFAULT_EFFORT:-high}"
CX_MODELS="gpt-5.2 gpt-5.4 gpt-5.4-mini gpt-5.5 gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna"
CX_EFFORTS="low medium high xhigh max ultra"

# cx_validate KIND VALUE — 0 if VALUE is a known model/effort, else print the
# valid set and return 1. CX_ALLOW_UNKNOWN=1 forces a pass, so a model released
# after this list was written is never permanently blocked by our own guardrail.
cx_validate() {
  local kind="$1" val="$2" allowed a
  case "$kind" in
    model)  allowed="$CX_MODELS" ;;
    effort) allowed="$CX_EFFORTS" ;;
  esac
  for a in $allowed; do [ "$val" = "$a" ] && return 0; done
  [ "${CX_ALLOW_UNKNOWN:-0}" = 1 ] && return 0
  echo "INVALID_$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]'): '$val' is not a known $kind"
  echo "  valid: $allowed"
  echo "  (CX_ALLOW_UNKNOWN=1 bypasses this if codex has added a new $kind)"
  return 1
}

# cx_effort_conf EFFORT — codex has no --reasoning-effort flag; effort reaches
# it only through -c. The value is parsed as TOML, hence the inner quotes.
cx_effort_conf() { printf 'model_reasoning_effort="%s"' "$1"; }

# cx_flag FILE DEFAULT — this turn's requested value, or DEFAULT. The flag file
# exists iff the user explicitly asked for it (gate.sh writes/clears it), which
# is what lets pane.sh tell "asked for a model" from "took the default".
cx_flag() { [ -s "$1" ] && tr -d '\n' < "$1" || printf '%s' "$2"; }

# ── codex capability resolution ──────────────────────────────────────────────
# CODEX_BIN above answers only "is there a codex?" — which is all the *pane*
# transports need, since they drive the interactive TUI that every codex major
# has. The *exec* transport needs strictly more: a real `codex exec` subcommand,
# which the 0.1.x research-preview TUI does not have.
#
# Resolving by PATH order alone silently picks the wrong binary on any machine
# with a version split (TODO #171, confirmed live 2026-07-11: `command -v codex`
# here is a 0.1.x npm-global with no `exec`, while a 0.143.0 lives under a
# homebrew node whose bin shim dangles — so PATH skips the *only* candidate that
# could have worked). Probe for the capability; never infer it from the path.

# cx_supports_exec BIN — does BIN have a real `exec` subcommand?
# stdin is closed so a TUI-only codex that reads "exec" as a prompt cannot hang
# waiting for input, and a broken npm shim (missing native sidecar) throws and
# fails here too. The probe, not the path, is the judge.
cx_supports_exec() {
  [ -n "${1:-}" ] || return 1
  "$1" exec --help </dev/null >/dev/null 2>&1
}

# cx_codex_candidates — every plausible codex, in preference order, deduped:
#   1. an explicit CODEX_BIN pin — the user's word is final
#   2. every codex on PATH, not just the first (`type -aP`)
#   3. npm-global package entrypoints, reached directly — a dangling or absent
#      bin shim makes `command -v` skip an otherwise-healthy install
cx_codex_candidates() {
  {
    [ -n "${CODEX_BIN:-}" ] && printf '%s\n' "$CODEX_BIN"
    type -aP codex 2>/dev/null || true
    for nr in $(npm root -g 2>/dev/null || true); do
      printf '%s\n' "$nr/@openai/codex/bin/codex.js"
    done
  } | awk 'NF && !seen[$0]++'
}

# cx_exec_bin — first candidate that actually supports `codex exec`.
# Prints it and returns 0; prints nothing and returns 1 if none qualifies.
cx_exec_bin() {
  local c
  while IFS= read -r c; do
    cx_supports_exec "$c" && { printf '%s\n' "$c"; return 0; }
  done < <(cx_codex_candidates)
  return 1
}

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
