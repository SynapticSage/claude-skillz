---
name: codex-pair
description: |
  Pair-program with OpenAI Codex as a teammate. Spawns and manages a persistent
  Codex CLI in a sibling tmux pane, hands it prompts, and captures responses
  verbatim — preserving session memory across turns. Uses ChatGPT subscription
  (via `codex login`), not OpenAI API. Prefers the bidirectional
  tmux-bridge-mcp path when installed; falls back to raw-tmux sentinel polling
  when it isn't.
  Use when the user asks to "pair with codex", "ask codex", "consult codex",
  "get a second opinion from codex", "codex review", "codex challenge", or
  "show me what codex thinks".
allowed-tools:
  - Bash
  - Read
  - Write
  - AskUserQuestion
---

# /codex-pair — Pair-program with Codex in a sibling pane

Keeps a long-running `codex` CLI alive in a tmux pane next to Claude Code.
Each invocation delivers a prompt to that pane and gets Codex's response
back. Pane ID and Codex session ID persist in the repo-local `.context/`
directory so they survive across skill invocations and CC restarts.

The skill has **two transports**. Which one runs is decided at the top of
Step 3 based on what MCP tools you (Claude) have available:

- **Phase 5 (preferred, bidirectional push):** MCP tools from
  `tmux-bridge` are loaded → use them. Codex can reply by pushing back
  into CC's pane, so CC's turn ends cleanly after delivering the prompt.
- **Phase 1 (fallback, one-way pull):** no bridge tools → use raw
  `tmux send-keys` and `capture-pane` with sentinel-based extraction.

## First-time setup

If `tmux-bridge-mcp` has never been built and registered, tell the user:

> First-time setup needed for the Phase 5 transport. Run
> `~/.claude/skills/codex-pair/install.sh --dry-run` to preview, then
> drop `--dry-run` to apply. That builds the bridge, registers it with
> Claude Code, and registers it with Codex. Add `--global` to make the
> skill available from any project. **Restart Claude Code after running
> the installer** so CC picks up the new MCP tools.

Until the user has restarted CC with MCP tools loaded, the skill works
via Phase 1 transport. No error; the skill degrades gracefully.

The install script is idempotent. Re-running it only adds missing pieces.

---

## Step 0: Preflight

Run this block first. Stop and tell the user what's missing if any check fails.

```bash
set -euo pipefail

TMUX_BIN=/opt/homebrew/bin/tmux
CODEX_BIN=$(command -v codex 2>/dev/null || true)

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

# Anchor state to the repo root so .context/ doesn't fragment across
# subdirectory invocations. Fall back to CWD if we're not in a repo.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# Per-window state directory. Multiple /codex-pair sessions in different
# tmux windows of the same repo each get their own state dir, keyed by
# tmux window_id (e.g. @5). Without this scoping, concurrent windows
# stomp on the same pane-id/lock/pending files. Window IDs are stable
# within a tmux server lifetime.
# $TMUX_PANE isn't always inherited by CC's bash subshells (see Invariant
# #9); fall back to the currently-active pane via tmux. The arg order
# below also matters: `-t` must precede the format string, or tmux
# treats `-t` and its value as positional args and errors with "too
# many arguments" (Invariant #10).
CC_PANE="${TMUX_PANE:-$($TMUX_BIN display-message -p '#{pane_id}')}"
WINDOW_ID=$($TMUX_BIN display-message -p -t "$CC_PANE" '#{window_id}')
SESSION_DIR="$REPO_ROOT/.context/codex-pair/$WINDOW_ID"
mkdir -p "$SESSION_DIR/pending"

# Add .context/ to .gitignore if we're in a git repo AND a .gitignore
# already exists. Skip if .gitignore is absent — creating one is a
# bigger opinion than this skill should impose.
if [ -d "$REPO_ROOT/.git" ] && [ -f "$REPO_ROOT/.gitignore" ] \
   && ! grep -qE '^\.context/?$' "$REPO_ROOT/.gitignore"; then
  {
    echo ""
    echo "# Codex skill state (pane ID, session ID, transient prompts)"
    echo ".context/"
  } >> "$REPO_ROOT/.gitignore"
fi

echo "OK: codex=$CODEX_BIN tmux=$TMUX_BIN repo_root=$REPO_ROOT window=$WINDOW_ID session_dir=$SESSION_DIR"
```

If output starts with `MISSING:`, stop and relay the message to the user.
Do not proceed to Step 1.

The variables `TMUX_BIN`, `CODEX_BIN`, `REPO_ROOT`, `WINDOW_ID`, and
`SESSION_DIR` are used in every subsequent bash block — re-declare them
at the top of each block (each bash call is a separate subshell and
does not inherit these).

---

## Step 0.5 — Concurrency gate (single-flight per window)

Only one outstanding `/codex-pair` request per window at a time. The
gate runs **before** Step 1's pane spawn so concurrent invocations in
the same window can't race during spawning. Different windows have
separate `SESSION_DIR`s and run independently.

The gate checks `$SESSION_DIR/pending/` (created in Step 0):
- **No files** → free; proceed.
- **One or more files exist** → check their age.
  - Any file fresher than 60 min → **HOLD**. Refuse with a clear
    message and point the user at the active pane. They can run
    `/codex-pair --reset-pending` to force-clear.
  - All files older than 60 min → **STALE**. Treat as crashed prior
    session; delete them and proceed.

```bash
set -euo pipefail
TMUX_BIN=/opt/homebrew/bin/tmux
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# $TMUX_PANE isn't always inherited by CC's bash subshells (see Invariant
# #9); fall back to the currently-active pane via tmux. The arg order
# below also matters: `-t` must precede the format string, or tmux
# treats `-t` and its value as positional args and errors with "too
# many arguments" (Invariant #10).
CC_PANE="${TMUX_PANE:-$($TMUX_BIN display-message -p '#{pane_id}')}"
WINDOW_ID=$($TMUX_BIN display-message -p -t "$CC_PANE" '#{window_id}')
SESSION_DIR="$REPO_ROOT/.context/codex-pair/$WINDOW_ID"
PENDING_DIR="$SESSION_DIR/pending"
LOCK_DIR="$SESSION_DIR/lock"
HEALTH_FILE="$SESSION_DIR/health.json"

# --- Flag dispatch ---
# $SKILL_ARGS contains the user's args after /codex-pair. Parse the
# documented flags and act. After flag handling, $SKILL_ARGS_REST holds
# whatever remains (the actual prompt text, possibly empty).
FLAG_RESET_PENDING=0
FLAG_REBOOTSTRAP=0
FLAG_PHASE1=0
MODEL_OVERRIDE=""
SKILL_ARGS_REST=""

# This block reads $SKILL_ARGS (set by Claude from user input). When
# invoking the skill, the orchestration sets SKILL_ARGS to the raw
# argument string. Substitute $SKILL_ARGS with the actual user input
# at runtime. For documentation purposes:
#   /codex-pair --reset-pending      → SKILL_ARGS="--reset-pending"
#   /codex-pair --phase1 fix the bug → SKILL_ARGS="--phase1 fix the bug"
#   /codex-pair --model gpt-5.5 hi   → SKILL_ARGS="--model gpt-5.5 hi"
case "${SKILL_ARGS:-}" in
  "--reset-pending"*)  FLAG_RESET_PENDING=1 ;;
  "--rebootstrap"*)    FLAG_REBOOTSTRAP=1; SKILL_ARGS_REST="${SKILL_ARGS#--rebootstrap}"; SKILL_ARGS_REST="${SKILL_ARGS_REST# }" ;;
  "--phase1 "*)        FLAG_PHASE1=1;     SKILL_ARGS_REST="${SKILL_ARGS#--phase1 }" ;;
  "--model "*)         REST="${SKILL_ARGS#--model }"
                       MODEL_OVERRIDE="${REST%% *}"
                       SKILL_ARGS_REST="${REST#"$MODEL_OVERRIDE"}"
                       SKILL_ARGS_REST="${SKILL_ARGS_REST# }" ;;
  *)                   SKILL_ARGS_REST="${SKILL_ARGS:-}" ;;
esac

# Handle --reset-pending early and exit cleanly.
if [ $FLAG_RESET_PENDING -eq 1 ]; then
  if [ -d "$PENDING_DIR" ]; then
    for f in "$PENDING_DIR"/*.json; do
      [ -e "$f" ] || continue
      echo "RESET: removing $(basename "$f")"
      rm -f "$f"
    done
  fi
  rm -rf "$LOCK_DIR"
  echo "RESET: pending cleared, lock removed. Skill exiting; re-invoke /codex-pair to use."
  exit 0
fi

# Handle --rebootstrap: clear bootstrap.json + health.json, fall through.
if [ $FLAG_REBOOTSTRAP -eq 1 ]; then
  rm -f "$SESSION_DIR/bootstrap.json" "$HEALTH_FILE"
  echo "REBOOTSTRAP: cleared bootstrap.json + health.json"
  # Continue to gate logic below.
fi

# --- Proactive health check ---
# If the prior reply handler marked Phase 5 unhealthy (>=3 consecutive
# protocol violations), surface the banner before doing anything else.
# User can choose --phase1 or --rebootstrap from there.
if [ -f "$HEALTH_FILE" ]; then
  MISSES=$(python3 -c '
import json, sys
try: print(json.load(open(sys.argv[1])).get("phase5_consecutive_misses", 0))
except: print(0)
' "$HEALTH_FILE")
  if [ "$MISSES" -ge 3 ]; then
    echo "UNHEALTHY: Phase 5 has had ${MISSES} consecutive protocol violations."
    echo "  Codex may not be following the contract."
    echo "  Use /codex-pair --phase1 <prompt> to fall back, or"
    echo "      /codex-pair --rebootstrap to retry the handshake."
    [ $FLAG_PHASE1 -eq 0 ] && [ $FLAG_REBOOTSTRAP -eq 0 ] && exit 0
  fi
fi

# --- Single-flight via atomic mkdir ---
# mkdir is atomic on POSIX: exactly one caller wins. This runs BEFORE
# pane spawn so concurrent invocations cannot both spawn duplicate
# Codex panes. The lock dir holds metadata; we delete it on the reply
# handler success path, on --reset-pending, or on stale TTL.
LOCK_AGE_MAX_S=$(( 60 * 60 ))   # 60 min stale TTL

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # Lock held by another invocation. Check its age.
  LOCK_AGE_S=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ))
  if [ "$LOCK_AGE_S" -lt "$LOCK_AGE_MAX_S" ]; then
    echo "HOLD: another /codex-pair is in flight in window $WINDOW_ID (lock ${LOCK_AGE_S}s old)"
    echo "  Use /codex-pair --reset-pending to clear, or wait."
    exit 0
  fi
  # Stale: take it over.
  echo "STALE_LOCK: claiming lock (>${LOCK_AGE_MAX_S}s old)"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
fi

# Sweep stale pending files (separate from the lock; pending tracks
# individual requests, lock guards the whole turn).
NOW=$(date +%s)
if [ -d "$PENDING_DIR" ]; then
  for f in "$PENDING_DIR"/*.json; do
    [ -e "$f" ] || continue
    AGE_MIN=$(( ( NOW - $(stat -f %m "$f") ) / 60 ))
    [ "$AGE_MIN" -ge 60 ] && { echo "STALE_PENDING: clearing $(basename "$f")"; rm -f "$f"; }
  done
fi

# Persist flag state for downstream steps to read.
echo "$FLAG_PHASE1"     > "$SESSION_DIR/flag-phase1"
echo "$SKILL_ARGS_REST" > "$SESSION_DIR/skill-args-rest"
# flag-model: only present when this turn requested an override. Cleared
# otherwise so a stale override from a previous turn never reanimates.
if [ -n "$MODEL_OVERRIDE" ]; then
  printf '%s\n' "$MODEL_OVERRIDE" > "$SESSION_DIR/flag-model"
else
  rm -f "$SESSION_DIR/flag-model"
fi
# model-warning is per-turn (Step 1 writes it on reuse path; Step 5 reads
# and surfaces it). Always clear at the gate so a stale warning can't
# leak into a turn that didn't request --model.
rm -f "$SESSION_DIR/model-warning"

echo "GATE: clear"
```

If output starts with `HOLD:` or `UNHEALTHY:`, **stop** and surface the
message to the user verbatim. Do not proceed to Step 1.

The lock (`$SESSION_DIR/lock/`) is **released** when:
- the reply handler (3A.3) successfully matches a reply (`ALL_PASS`
  outcome) — `rm -rf "$LOCK_DIR"` after deleting the pending file.
- the user runs `/codex-pair --reset-pending`.
- the lock is older than 60 min (next invocation force-takes it with
  the `STALE_LOCK` warning).

If 3A.1.d fails (BOOTSTRAP_TIMEOUT or ACK_INVALID), the lock IS
released — bootstrap failure shouldn't strand the window. The
pending file (if 3A.2.a wrote one) stays so the user can see what
they tried.

### Skill flags handled here

These flags short-circuit the gate / change its behavior:

- `/codex-pair --reset-pending` — clear all pending files in this
  window's session dir, show what was cleared, **exit cleanly without
  running Steps 1+**. The user is using this to recover from a stuck
  state.
- `/codex-pair --rebootstrap` — clear `$SESSION_DIR/bootstrap.json`
  and `$SESSION_DIR/health.json`, then proceed normally. Forces a
  fresh Phase 5 handshake. Pending state is NOT touched (use
  `--reset-pending` separately if also needed).
- `/codex-pair --phase1 <prompt>` — force the Phase 1 transport for
  this turn even if MCP tools are loaded. Useful when Phase 5 has
  marked itself unhealthy (see Health tracking section), or for
  debugging.
- `/codex-pair --model <name> <prompt>` — request a specific Codex
  model for *this spawn only*. The flag is consumed at
  `tmux split-window` time (Step 1) and threaded into `codex` as
  `--model <name>`. **Spawn-time only**: codex's model is fixed once
  the TUI is up, so passing `--model` against an existing pane is a
  no-op for the running codex. The skill detects this case (reuse
  path) and emits a `WARN` line that Step 5 surfaces in the status
  block. To actually switch models, kill the codex pane
  (`codex /exit` inside the pane, or `tmux kill-pane -t <CODEX_PANE>`)
  and re-invoke with the new `--model`. With no flag, codex picks up
  whatever `~/.codex/config.toml` declares (default behavior
  unchanged).

Strip these flags from `PROMPT_TEXT` before delivery in Step 3.

---

## Step 1: Attach to or spawn the Codex pane

The Codex pane is the long-running resource. We cache its pane ID in
`$SESSION_DIR/pane-id` (per-window). On each invocation:

1. If the cache file exists, verify the pane is still alive.
2. If alive, reuse it (this is the common path).
3. If dead or missing, spawn a new sibling pane running `codex`.

```bash
set -euo pipefail
TMUX_BIN=/opt/homebrew/bin/tmux
CODEX_BIN=$(command -v codex)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# $TMUX_PANE isn't always inherited by CC's bash subshells (see Invariant
# #9); fall back to the currently-active pane via tmux. The arg order
# below also matters: `-t` must precede the format string, or tmux
# treats `-t` and its value as positional args and errors with "too
# many arguments" (Invariant #10).
CC_PANE="${TMUX_PANE:-$($TMUX_BIN display-message -p '#{pane_id}')}"
WINDOW_ID=$($TMUX_BIN display-message -p -t "$CC_PANE" '#{window_id}')
SESSION_DIR="$REPO_ROOT/.context/codex-pair/$WINDOW_ID"

PANE_FILE="$SESSION_DIR/pane-id"
# CC_PANE is already resolved above (with $TMUX_PANE fallback) and is
# the target for split-window; no redeclaration needed.

CODEX_PANE=""
FRESH_SPAWN=0

if [ -f "$PANE_FILE" ]; then
  SAVED=$(cat "$PANE_FILE")
  if $TMUX_BIN list-panes -a -F '#{pane_id}' | grep -qFx "$SAVED"; then
    CODEX_PANE="$SAVED"
    echo "REUSING: $CODEX_PANE"
    # If --model was passed but we're reusing a pane, the flag is dead
    # weight: codex's model is fixed at spawn. Don't silent-drop —
    # write a warning that Step 5 surfaces in the status line.
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
  # Split the CC pane horizontally. -d keeps CC focused. -P prints the new
  # pane ID. -F formats it. Launches $CODEX_BIN (absolute) in the new pane
  # so PATH differences between CC's shell env and tmux server env cannot
  # leave us with the wrong codex.
  # SPAWN_ARGS optionally carries --model <value> from Step 0.5. Empty
  # array expansion under set -u is unsafe on bash 3.2 (macOS default),
  # so use the ${arr[@]+"${arr[@]}"} idiom — expands to nothing when
  # unset, splats correctly when set.
  SPAWN_ARGS=()
  [ -s "$SESSION_DIR/flag-model" ] && SPAWN_ARGS+=("--model" "$(cat "$SESSION_DIR/flag-model")")
  CODEX_PANE=$($TMUX_BIN split-window -h -d -P -F '#{pane_id}' -t "$CC_PANE" "$CODEX_BIN" ${SPAWN_ARGS[@]+"${SPAWN_ARGS[@]}"})
  echo "$CODEX_PANE" > "$PANE_FILE"
  echo "SPAWNED: $CODEX_PANE"
  [ ${#SPAWN_ARGS[@]} -gt 0 ] && echo "  with: ${SPAWN_ARGS[*]}"
  FRESH_SPAWN=1
  # Codex takes a few seconds to boot its TUI. Give it time before sending.
  sleep 4
fi

echo "$FRESH_SPAWN" > "$SESSION_DIR/fresh-spawn"
echo "CODEX_PANE=$CODEX_PANE FRESH_SPAWN=$FRESH_SPAWN"
```

Remember whether this turn used `REUSING` or `SPAWNED` — include it in the
final status line so the user knows whether Codex is fresh or continuing.
`FRESH_SPAWN=1` means you should run the bootstrap preamble in Step 3A
(if on the Phase 5 path).

---

## Step 2: Gather the user's prompt

Everything after `/codex-pair` is the prompt. If the user said just
`/codex-pair` with no args, ask them what they want to ask Codex using
AskUserQuestion:

```
What would you like to ask Codex?
A) Review the current diff against the base branch
B) Ask a free-form question (I'll provide the prompt)
C) Cancel
```

For A, construct the prompt: `"Review the changes on this branch against
the base branch. Run git diff to see them. Flag bugs, edge cases, and
anything that looks wrong."`

For B, ask what the question is.

Call the final prompt text `PROMPT_TEXT`. It gets delivered in Step 3.

---

## Step 3: Select transport

Check your tool list (use the `ToolSearch` tool with query
`tmux_message tmux_read tmux_list bridge` or inspect the loaded tools
directly):

- **If tools named `mcp__tmux-bridge__tmux_read`, `mcp__tmux-bridge__tmux_message`,
  etc. ARE available** → follow **Step 3A** (Phase 5, push model).
- **If those tools are NOT available** → follow **Step 3B** (Phase 1,
  sentinel pull).

If the user recently ran `install.sh` but MCP tools aren't yet loaded,
tell them: "Phase 5 transport is installed but requires a CC restart to
activate. Using Phase 1 fallback for this turn." Then proceed with 3B.

---

## Step 3A — Phase 5: push model via tmux-bridge MCP

### 3A.1 — Bootstrap Codex (always, on Phase 5 path) with verified ACK

**Run this block every time the Phase 5 path is taken, regardless of
`FRESH_SPAWN`.** A reused Codex pane may predate Codex's own MCP-load
restart — it would have bridge tools unavailable even though CC has
them. Cheapest fix: always re-run the bootstrap and let it be a no-op
when Codex is already set up. The preamble's actions are idempotent.
Credit: Codex review 2026-04-24 Part B #2 / HIGH.

#### 3A.1.a — Skip only if recent AND fully validated

Check `$SESSION_DIR/bootstrap.json`. The skip path must run the **same
4-predicate validation** as 3A.1.c — `mtime` alone is insufficient
because a stale file from a prior pane can suppress rebootstrap and
send into an unverified pane. The check below uses the actual
`$CODEX_PANE_ID` from this turn, so a recycled bootstrap.json keyed
to a different pane fails predicate (2) and triggers full rebootstrap.

**TTL** is defined once as `$TTL_S` and applied to *both* freshness
gates (the outer `mtime` check and the inner predicate-4 `ts` check)
so they can't drift. Cold turns saved by extending the TTL are paid
back by a cheap `tmux_id()` health probe in 3A.1.a.x — that catches
the stale-tool-surface case (Codex restart with the bridge unloaded,
config drift, tmux server restart with pane-id reuse). Credit:
Codex round-1 review HIGH on H2 / 2026-05-02. (H2 — was 5 min, now
30 min. Per-turn cost of probe ~10 tok; amortized across ~15× more
hot turns vs. before.)

```bash
set -euo pipefail
TMUX_BIN=/opt/homebrew/bin/tmux
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# $TMUX_PANE isn't always inherited by CC's bash subshells (see Invariant
# #9); fall back to the currently-active pane via tmux. The arg order
# below also matters: `-t` must precede the format string, or tmux
# treats `-t` and its value as positional args and errors with "too
# many arguments" (Invariant #10).
CC_PANE="${TMUX_PANE:-$($TMUX_BIN display-message -p '#{pane_id}')}"
WINDOW_ID=$($TMUX_BIN display-message -p -t "$CC_PANE" '#{window_id}')
SESSION_DIR="$REPO_ROOT/.context/codex-pair/$WINDOW_ID"
BFILE="$SESSION_DIR/bootstrap.json"
# $CODEX_PANE_ID set in Step 1.

# H2: bootstrap-skip TTL. Define once; both gates (outer bash mtime
# and inner python ts) read this. 30 min lets idle-resume cases
# (user steps away, comes back) skip the full bootstrap; the
# tmux_id() health probe in 3A.1.a.x catches stale-tool-surface
# regressions.
TTL_S=1800

SKIP_BOOTSTRAP=0
if [ -f "$BFILE" ]; then
  AGE_S=$(( $(date +%s) - $(stat -f %m "$BFILE") ))
  if [ "$AGE_S" -lt "$TTL_S" ]; then
    # Fresh enough; now run the same 4 predicates as 3A.1.c. We don't
    # have a $BOOTSTRAP_UUID to check against on this skip-path because
    # the existing file was bootstrapped with a prior UUID — so we
    # accept any non-empty bootstrap_id, but require codex_pane_id +
    # doctor_status + ts to all pass. Effectively: "this file is fresh,
    # the right pane is bootstrapped, and the bridge works."
    RESULT=$(python3 - "$BFILE" "$CODEX_PANE_ID" "$TTL_S" <<'PY'
import json, sys, datetime
path, want_pane, ttl_s = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    with open(path) as f: d = json.load(f)
except Exception as e:
    print(f"FAIL parse: {e}"); sys.exit(0)
if not d.get("bootstrap_id"):
    print("FAIL no_bootstrap_id"); sys.exit(0)
if d.get("codex_pane_id") != want_pane:
    print(f"FAIL pane_mismatch want={want_pane} got={d.get('codex_pane_id')}")
    sys.exit(0)
if "Status: OK" not in d.get("doctor_status", ""):
    print("FAIL doctor_unhealthy"); sys.exit(0)
try:
    ts = datetime.datetime.strptime(d["ts"], "%Y-%m-%dT%H:%M:%SZ")
    age = (datetime.datetime.utcnow() - ts).total_seconds()
    # H2: both gates use the same TTL_S. -60s tolerates clock skew.
    if age > ttl_s or age < -60:
        print(f"FAIL ts_stale age={age:.0f} ttl={ttl_s}"); sys.exit(0)
except Exception as e:
    print(f"FAIL ts_unparseable: {e}"); sys.exit(0)
print("OK")
PY
)
    [ "$RESULT" = "OK" ] && SKIP_BOOTSTRAP=1 || echo "SKIP_BLOCKED: $RESULT (forcing rebootstrap)"
  fi
fi
echo "SKIP_BOOTSTRAP=$SKIP_BOOTSTRAP"
```

If `SKIP_BOOTSTRAP=1`, run 3A.1.a.x (the probe) before jumping to
3A.2. Otherwise (file-check predicates failed, or freshness expired)
fall through to 3A.1.b for a full rebootstrap.

#### 3A.1.a.x — Cheap health probe on the skip path

The 4-predicate check in 3A.1.a verifies the *cached* bootstrap state.
Predicate 3 (`Status: OK` in `doctor_status`) checks the doctor output
captured during the *previous* bootstrap, not the current state. With
the TTL extended to 30 min, that cache can mask Codex-side MCP tool
loss, config drift, or pane-id reuse after a tmux server restart.

Mitigation: when `SKIP_BOOTSTRAP=1`, call `tmux_id()` via the bridge
**once** as a current-state probe. Two outcomes:

- `tmux_id()` returns a value matching `$CODEX_PANE_ID` → bridge is
  healthy on Codex's side, proceed to 3A.2 with `SKIP_BOOTSTRAP=1`.
- `tmux_id()` errors, returns mismatched value, or times out → force
  `SKIP_BOOTSTRAP=0`. Surface to the user:
  > "Phase 5 health probe failed (Codex's bridge tools may have
  > unloaded). Forcing rebootstrap. If this recurs, try
  > `/codex-pair --rebootstrap` explicitly or check the pane state."
  Then fall through to 3A.1.b.

Cost: one MCP call (~10 tok). Catches the stale-tool-surface failure
mode that the longer TTL otherwise enables.

If you reach this step from a SKIP path and the probe fails, the
`tmux_id` call's own tool args + response are the cleanup cost — no
pending file is in flight yet (3A.2.a hasn't run), so no extra
state to delete.

#### 3A.1.b — Compose and deliver the bootstrap preamble

H1 from token-optimization: the **static** bridge contract (Read-Act-
Read cycle, never poll, pane-ID routing, tool quick-reference) is
loaded into Codex's context once at TUI startup via the managed section
of `~/.codex/AGENTS.md` (written by `install.sh`'s `--skip-agents`
gated step). The per-turn preamble below carries only the **dynamic**
bits that change per-turn: this turn's `BOOTSTRAP_UUID`, the CC pane
ID, the session-dir path, the file-ACK protocol, correlation tags,
and labeling commands. Net per-cold-turn savings: ~370 tok.

If `~/.codex/AGENTS.md` is missing the managed section (e.g. user
hasn't run `install.sh`), Codex won't know the static contract and
this preamble alone is insufficient. Symptom: bootstrap ACKed but
later replies don't include `[reply-to:...]` tags or come from the
wrong pane. Recovery: re-run `~/.claude/skills/codex-pair/install.sh`
and exit/respawn the codex pane (TUI reload).

Generate a `BOOTSTRAP_UUID` (8-hex), then compose the preamble Codex
must read. The preamble instructs Codex to:
1. Run a bridge self-test (`tmux_id()` + `tmux_doctor()`) to prove the
   MCP layer is functional from its side.
2. Write `bootstrap.json` via temp-file + atomic rename (so CC's
   reader never sees a partial write).

Send via bracketed paste (same mechanism as Phase 1 — see Step 3B.1),
then Enter. Substitute `<CC_PANE>`, `<BOOTSTRAP_UUID>`, `<SESSION_DIR>`
with concrete values from this turn:

```
You are paired with Claude Code in tmux pane <CC_PANE>.
The static bridge contract (Read-Act-Read, never poll, pane-ID
routing, tool quick-ref) is in your AGENTS.md context. This message
carries the dynamic per-turn bits.

PER-TURN ROUTING:
  - CC's pane: <CC_PANE>
  - Reply by: tmux_read(<CC_PANE>) → tmux_message(<CC_PANE>, text=YOUR_RESPONSE) → tmux_read(<CC_PANE>) → tmux_keys(<CC_PANE>, keys=["Enter"]).

CORRELATION:
  Every prompt is tagged [req:<8-char-uuid>]. Your reply must include
  [reply-to:<8-char-uuid>] on its own line, matching the uuid exactly.
  Without this, Claude treats your message as unsolicited.

BOOTSTRAP HANDSHAKE (do this BEFORE waiting for the next prompt):
  Confirm setup by running a bridge self-test and writing a file Claude
  will poll for. This proves your MCP tools work end-to-end.

  Step 1: Get your own pane ID via the bridge:
        my_pane = tmux_id()
  Step 2: Run the bridge diagnostic:
        doctor = tmux_doctor()
  Step 3: Write bootstrap.json via a temp-file + atomic rename so
          Claude does not see a partial file. **The doctor output is
          multi-line — embedding it raw in JSON produces invalid JSON
          (literal newlines in a string).** Use python3 to JSON-encode
          all string values before writing.

        TMPF="<SESSION_DIR>/bootstrap.json.tmp"
        FINAL="<SESSION_DIR>/bootstrap.json"

        python3 - <<PY > "$TMPF"
        import json, datetime
        # Substitute the literals below with the actual values you
        # computed in steps 1 and 2.
        d = {
            "acked": True,
            "bootstrap_id": "<BOOTSTRAP_UUID>",
            "codex_pane_id": "<my_pane from step 1>",
            "doctor_status": """<full output of doctor from step 2>""",
            "ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        print(json.dumps(d, indent=2))
        PY
        mv "$TMPF" "$FINAL"

  python3's json.dumps handles all escaping automatically — newlines in
  doctor_status become `\n` literals, quotes are escaped, etc. The
  resulting bootstrap.json parses cleanly.

  Do this BEFORE acknowledging via tmux_message or waiting for input.
  The file write IS the acknowledgement. Do not use tmux_message for
  the ACK — Claude waits on the file, not a message.

LABELING (cosmetic, AFTER bootstrap ACK):
  tmux_read(target=tmux_id()); tmux_name(target=tmux_id(), label="codex-<WINDOW_ID>")
  tmux_read(target="<CC_PANE>"); tmux_name(target="<CC_PANE>", label="claude-<WINDOW_ID>")

Wait for the user's actual prompt in the next message (it will contain a [req:<uuid>] tag).
```

Substitute `<CC_PANE>`, `<BOOTSTRAP_UUID>`, `<SESSION_DIR>` with their
values, then deliver via the bracketed-paste mechanism in Step 3B.1
below (yes, we use Phase 1 mechanics to bootstrap Phase 5 — this is
the one thing we can't do via MCP on first spawn because Codex hasn't
been told about the bridge yet).

#### 3A.1.c — Verify the ACK (4-predicate file check)

After sending the preamble + Enter, CC polls `bootstrap.json` for up
to 90 seconds. The file presence is necessary but not sufficient:
validate four predicates before treating the bootstrap as confirmed.

```bash
set -euo pipefail
TMUX_BIN=/opt/homebrew/bin/tmux
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# $TMUX_PANE isn't always inherited by CC's bash subshells (see Invariant
# #9); fall back to the currently-active pane via tmux. The arg order
# below also matters: `-t` must precede the format string, or tmux
# treats `-t` and its value as positional args and errors with "too
# many arguments" (Invariant #10).
CC_PANE="${TMUX_PANE:-$($TMUX_BIN display-message -p '#{pane_id}')}"
WINDOW_ID=$($TMUX_BIN display-message -p -t "$CC_PANE" '#{window_id}')
SESSION_DIR="$REPO_ROOT/.context/codex-pair/$WINDOW_ID"
BFILE="$SESSION_DIR/bootstrap.json"

# $BOOTSTRAP_UUID and $CODEX_PANE_ID set in 3A.1.b
DEADLINE=$(( $(date +%s) + 90 ))
ACK_OK=0

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if [ -f "$BFILE" ]; then
    # Tolerate transient parse errors — Codex might still be writing,
    # though atomic rename in the preamble should prevent this. Belt
    # and suspenders.
    RESULT=$(python3 - "$BFILE" "$BOOTSTRAP_UUID" "$CODEX_PANE_ID" <<'PY'
import json, sys, datetime
path, want_uuid, want_pane = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f: d = json.load(f)
except (json.JSONDecodeError, IOError):
    print("RETRY"); sys.exit(0)

# Predicate 1: bootstrap_id matches what we sent
if d.get("bootstrap_id") != want_uuid:
    print(f"FAIL bootstrap_id_mismatch want={want_uuid} got={d.get('bootstrap_id')}")
    sys.exit(0)
# Predicate 2: codex_pane_id == the pane we spawned (proves tmux_id works)
if d.get("codex_pane_id") != want_pane:
    print(f"FAIL codex_pane_id_mismatch want={want_pane} got={d.get('codex_pane_id')}")
    sys.exit(0)
# Predicate 3: doctor_status contains "Status: OK" (proves tmux_doctor works)
if "Status: OK" not in d.get("doctor_status", ""):
    print(f"FAIL doctor_unhealthy: {d.get('doctor_status', '<missing>')[:200]}")
    sys.exit(0)
# Predicate 4: ts parses and is within last 5 min
try:
    ts = datetime.datetime.strptime(d["ts"], "%Y-%m-%dT%H:%M:%SZ")
    age = (datetime.datetime.utcnow() - ts).total_seconds()
    if age > 300 or age < -60:  # tolerate small clock skew
        print(f"FAIL ts_stale age={age:.0f}s")
        sys.exit(0)
except Exception as e:
    print(f"FAIL ts_unparseable: {e}")
    sys.exit(0)
print("OK")
PY
)
    case "$RESULT" in
      OK)         ACK_OK=1; break ;;
      RETRY)      ;;  # transient — keep polling
      FAIL*)      echo "ACK_INVALID: $RESULT"; break ;;
    esac
  fi
  sleep 3
done

[ "$ACK_OK" -eq 1 ] && echo "BOOTSTRAP_ACKED" || echo "BOOTSTRAP_TIMEOUT"
```

#### 3A.1.d — Outcome handling

- **`BOOTSTRAP_ACKED`** → proceed to 3A.2.
- **`ACK_INVALID: FAIL <reason>`** → bootstrap is broken in a known
  way. Surface the reason to the user verbatim, fail the turn cleanly.
  User can `/codex-pair --rebootstrap` to retry.
- **`BOOTSTRAP_TIMEOUT`** → no `bootstrap.json` (or no valid one) within
  90s. Codex didn't run the self-test, or the bridge isn't loaded on
  Codex's side, or Codex is in trust-prompt / approval-modal state.
  Surface to the user: "Codex bootstrap timed out. Open pane
  `$CODEX_PANE_ID` to check. Retry with `/codex-pair --rebootstrap`,
  or fall back with `/codex-pair --phase1 <prompt>`." Fail the turn.

**Never** silently fall back to Phase 1 mid-turn after the bootstrap
preamble has already been sent (per Codex review 2026-04-24 finding
#6 and v3 plan condition #2). The user's `/codex-pair --phase1`
opt-in is the correct path for forcing Phase 1.

After successful ACK, write a copy of `bootstrap.json` to itself with
`mtime` refreshed (effectively `touch`) so the 5-min skip-check in
3A.1.a sees it as recent on the next invocation. The atomic rename
already gave it the right ts — no further action needed; the timestamp
is what 3A.1.a uses.

### 3A.2 — Deliver the user's prompt via MCP

Now use the bridge tools directly. This is where Phase 5 pays off — no
sentinels, no polling, no scrollback parsing.

**All routing uses raw pane IDs (`%N`), not labels.** See Invariant #5.
Substitute `$CODEX_PANE_ID` below with the actual pane ID captured in
Step 1 (e.g. `%99`).

#### 3A.2.a — Generate req-id and persist pending state

Before any MCP call, write the pending-request record. This is what
the gate (Step 0.5) and reply handler (Step 3A.3) read.

```bash
set -euo pipefail
TMUX_BIN=/opt/homebrew/bin/tmux
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# $TMUX_PANE isn't always inherited by CC's bash subshells (see Invariant
# #9); fall back to the currently-active pane via tmux. The arg order
# below also matters: `-t` must precede the format string, or tmux
# treats `-t` and its value as positional args and errors with "too
# many arguments" (Invariant #10).
CC_PANE="${TMUX_PANE:-$($TMUX_BIN display-message -p '#{pane_id}')}"
WINDOW_ID=$($TMUX_BIN display-message -p -t "$CC_PANE" '#{window_id}')
SESSION_DIR="$REPO_ROOT/.context/codex-pair/$WINDOW_ID"
CODEX_PANE=$(cat "$SESSION_DIR/pane-id")

REQ_ID=$(uuidgen | tr -d '\n-' | tr '[:upper:]' '[:lower:]' | cut -c1-8)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# $PROMPT_TEXT is what you gathered in Step 2 (after stripping skill flags).
# Write a sanitized first 200 chars (no newlines that would break JSON).
PROMPT_PREVIEW=$(printf '%s' "$PROMPT_TEXT" | tr '\n\r\t' ' ' | cut -c1-200)

cat > "$SESSION_DIR/pending/${REQ_ID}.json" <<EOF
{
  "req_id": "${REQ_ID}",
  "started_at": "${TS}",
  "prompt_preview": $(printf '%s' "$PROMPT_PREVIEW" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))'),
  "codex_pane": "${CODEX_PANE}",
  "window_id": "${WINDOW_ID}",
  "cc_pane": "${CC_PANE}"
}
EOF

echo "REQ_ID=$REQ_ID"
```

#### 3A.2.b — Tag the prompt and deliver via bridge

Prefix `PROMPT_TEXT` with `[req:<REQ_ID>]` so the reply handler can
match. The bootstrap preamble (Step 3A.1) instructs Codex to echo
`[reply-to:<REQ_ID>]` in its response.

Construct `TAGGED_PROMPT`:
```
[req:<REQ_ID>] <original PROMPT_TEXT>
```

**Pending-file cleanup invariant (read first).** *Any* bridge
delivery call below that fails before the final `tmux_keys` submit
must:
1. Delete the just-created `$SESSION_DIR/pending/${REQ_ID}.json`.
2. Release the lock with `rm -rf "$SESSION_DIR/lock"`.
3. Fall through to the error path — surface the error to the user.

This applies to step 1 (`tmux_read`) AND step 2 (`tmux_message`)
equally. After dropping the `tmux_list` pre-check (M1), the first
`tmux_read` is the new target-validation point — if the Codex pane
is gone, `bridge.read()` raises before `tmux_message` runs, so don't
gate cleanup on a `tmux_message` failure alone (Codex review
2026-05-10 / HIGH).

Then call the bridge tools in order:

1. **Read to satisfy the bridge's read-before-act guard:**
   - `tmux_read(target=$CODEX_PANE_ID, lines=5)`. (M2 — was
     `lines=20`; the response isn't semantically used, the call only
     marks the read-guard so 5 lines is enough.)
   - If this fails (pane gone, bridge unhealthy), apply the cleanup
     invariant above and surface "Codex pane `$CODEX_PANE_ID` is no
     longer reachable; respawn with a fresh `/codex-pair`."
2. **Send the tagged prompt:**
   - `tmux_message(target=$CODEX_PANE_ID, text=TAGGED_PROMPT)`.
   - If the pane vanished between step 1 and step 2,
     `bridge.message`'s internal `validateTarget` raises a clear
     error. Apply the cleanup invariant. (M1 — replaces the prior
     `tmux_list()` pre-check, which cost ~800–1300 tok per turn at
     33–53 panes for redundant validation.)
3. **Re-read to verify text landed:**
   - `tmux_read(target=$CODEX_PANE_ID, lines=5)`.
   - If this fails, apply the cleanup invariant. The prompt may have
     been delivered (step 2 succeeded), so also surface "Prompt may
     have been delivered to a now-gone pane; check
     `$SESSION_DIR/pending/` for orphan state."
4. **Submit:**
   - `tmux_keys(target=$CODEX_PANE_ID, keys=["Enter"])`.
   - If this fails, the prompt is queued in Codex's TUI but
     unsubmitted. Apply the cleanup invariant and surface the
     ambiguity.
5. **Stop.** End CC's turn with:
   > "Delivered prompt (req-id `$REQ_ID`) to Codex pane
   > `$CODEX_PANE_ID`. Reply will arrive in a new turn — typically
   > 30s–3min."

**Never** poll `tmux_read(target=$CODEX_PANE_ID)` waiting for a reply.
Codex pushes via `tmux_message(target=<CC_PANE>, ...)`, which arrives
as fresh user input in a new CC turn.

### 3A.3 — Handle Codex's pushed reply (three-predicate validation)

When Codex finishes and pushes its response, CC will receive a new user
message that starts with a bridge header like:
```
[tmux-bridge from:codex pane:%83 id:b2c3d4e5]
```
The body should also contain a `[reply-to:<req-id>]` line that Codex
echoes from our 3A.2 tagged prompt.

CC must validate **three predicates** before treating this as the
answer to a pending request. Be strict — accepting on weaker evidence
is how concurrent pushes get misattributed.

#### 3A.3.a — Extract from the message

- `from_pane` — the `pane:%N` value from the header.
- `reply_to` — the `<uuid>` from a line matching
  `\[reply-to:[a-f0-9]+\]` in the body. Empty if absent.
- `body` — the message text with both the header line AND the
  `[reply-to:...]` line removed. This is what gets shown to the user.

#### 3A.3.b — Three-predicate check

Read pending state and validate:

```bash
set -euo pipefail
TMUX_BIN=/opt/homebrew/bin/tmux
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# $TMUX_PANE isn't always inherited by CC's bash subshells (see Invariant
# #9); fall back to the currently-active pane via tmux. The arg order
# below also matters: `-t` must precede the format string, or tmux
# treats `-t` and its value as positional args and errors with "too
# many arguments" (Invariant #10).
CC_PANE="${TMUX_PANE:-$($TMUX_BIN display-message -p '#{pane_id}')}"
WINDOW_ID=$($TMUX_BIN display-message -p -t "$CC_PANE" '#{window_id}')
SESSION_DIR="$REPO_ROOT/.context/codex-pair/$WINDOW_ID"

# $REPLY_TO and $FROM_PANE are extracted in 3A.3.a above
PENDING_FILE="$SESSION_DIR/pending/${REPLY_TO}.json"

OUTCOME=""
if [ -z "$REPLY_TO" ]; then
  OUTCOME="MISSING_TAG"      # (a)
elif [ ! -f "$PENDING_FILE" ]; then
  OUTCOME="LATE"              # (b) — request already cleared
else
  STORED_PANE=$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("codex_pane", ""))
except Exception:
    print("")
' "$PENDING_FILE")
  if [ "$STORED_PANE" = "$FROM_PANE" ]; then
    OUTCOME="ALL_PASS"
  elif [ -z "$STORED_PANE" ]; then
    OUTCOME="MALFORMED"       # pending file unparseable; refuse to delete
  else
    OUTCOME="PANE_MISMATCH"    # (c) — actively wrong
  fi
fi

echo "OUTCOME=$OUTCOME"
[ "$OUTCOME" = "ALL_PASS" ] && {
  PROMPT_PREVIEW=$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("prompt_preview", ""))
' "$PENDING_FILE")
  echo "PROMPT_PREVIEW=$PROMPT_PREVIEW"
  rm -f "$PENDING_FILE"      # clear pending entry on success
  rm -rf "$SESSION_DIR/lock"  # release the single-flight lock
}
```

#### 3A.3.c — Outcome handling

| OUTCOME | What to do |
|---|---|
| `ALL_PASS` | Present `body` verbatim in Step 5 as the answer to `prompt_preview`. Pending file already deleted. **Reset health counter.** |
| `MISSING_TAG` (a) | Show `body` with banner: "Codex sent unprompted (no `reply-to` tag). Showing verbatim; ignore if not useful." **Increment health counter.** |
| `LATE` (b) | Show `body` with banner: "Late reply from req-id `$REPLY_TO`, which was already cleared. Showing verbatim; not treated as an answer to anything pending." **Do NOT increment health counter** — late cleanup noise isn't a Codex misbehavior signal. |
| `PANE_MISMATCH` (c) | Show `body` with banner: "Protocol violation: reply claimed pane `$FROM_PANE` but pending request `$REPLY_TO` was for pane `$STORED_PANE`. Showing verbatim, NOT clearing pending — investigate." **Increment health counter.** Do NOT delete the pending file. |
| `MALFORMED` | Show `body` with banner: "Pending file `$REPLY_TO.json` was unparseable. Refusing to clear; manual cleanup required (`/codex-pair --reset-pending`)." Do NOT increment health counter — this is local state corruption, not Codex misbehavior. |

#### 3A.3.d — Update health counter

Track in `$SESSION_DIR/health.json`:

```json
{
  "phase5_consecutive_misses": 0,
  "last_outcome": "ALL_PASS",
  "last_outcome_ts": "2026-04-24T15:00:00Z"
}
```

```bash
# Update after determining OUTCOME
HEALTH_FILE="$SESSION_DIR/health.json"
# Initialize if missing
[ -f "$HEALTH_FILE" ] || echo '{"phase5_consecutive_misses": 0}' > "$HEALTH_FILE"

python3 - "$HEALTH_FILE" "$OUTCOME" <<'PY'
import json, sys, datetime
path, outcome = sys.argv[1], sys.argv[2]
with open(path) as f: h = json.load(f)
if outcome == "ALL_PASS":
    h["phase5_consecutive_misses"] = 0
elif outcome in ("MISSING_TAG", "PANE_MISMATCH"):
    h["phase5_consecutive_misses"] = h.get("phase5_consecutive_misses", 0) + 1
# LATE and MALFORMED do not increment.
h["last_outcome"] = outcome
h["last_outcome_ts"] = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "w") as f: json.dump(h, f, indent=2)
PY
```

If `phase5_consecutive_misses >= 3` after this update, **before
reporting the response to the user**, prepend the unhealthy banner:
> "Phase 5 has had 3+ consecutive protocol violations. Codex may not
> be following the contract. Use `/codex-pair --phase1 <prompt>` to
> fall back, or `/codex-pair --rebootstrap` to retry the handshake."

Health counter is checked at the **start** of Step 0.5's gate logic
on the next invocation too — if already unhealthy, surface the banner
proactively.

---

## Step 3B — Phase 1 fallback: sentinel-based pull

Use this path when MCP tools aren't available.

### 3B.1 — Send the prompt via bracketed paste

```bash
set -euo pipefail
TMUX_BIN=/opt/homebrew/bin/tmux
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# $TMUX_PANE isn't always inherited by CC's bash subshells (see Invariant
# #9); fall back to the currently-active pane via tmux. The arg order
# below also matters: `-t` must precede the format string, or tmux
# treats `-t` and its value as positional args and errors with "too
# many arguments" (Invariant #10).
CC_PANE="${TMUX_PANE:-$($TMUX_BIN display-message -p '#{pane_id}')}"
WINDOW_ID=$($TMUX_BIN display-message -p -t "$CC_PANE" '#{window_id}')
SESSION_DIR="$REPO_ROOT/.context/codex-pair/$WINDOW_ID"
CODEX_PANE=$(cat "$SESSION_DIR/pane-id")

# Short sentinels — must NOT wrap in a narrow Codex TUI. Full UUIDs wrap
# in panes under ~45 columns, breaking grep -F. An 8-hex slice keeps the
# token ≤20 chars, safe down to ~30-col panes.
UUID=$(uuidgen | tr -d '\n-' | tr '[:upper:]' '[:lower:]' | cut -c1-8)
START="§cx:${UUID}:S§"
END="§cx:${UUID}:E§"

# $PROMPT_TEXT is what you gathered in Step 2.
WRAPPED=$(cat <<EOF
${START}
${PROMPT_TEXT}

When your response is complete, output this exact line (and nothing after it):
${END}
EOF
)

# Delivery via tmux paste-buffer with bracketed-paste (-p). This is
# critical: send-keys -l types newlines as Enter keypresses, which would
# make Codex's TUI submit each line individually. Bracketed paste tells
# the TUI to treat the whole block as one paste event, preserving the
# multi-line structure. Our explicit Enter at the end is what submits.
BUF="codex-pair-$UUID"
TMPF=$(mktemp)
printf '%s' "$WRAPPED" > "$TMPF"
$TMUX_BIN load-buffer -b "$BUF" "$TMPF"
$TMUX_BIN paste-buffer -b "$BUF" -t "$CODEX_PANE" -p
$TMUX_BIN delete-buffer -b "$BUF"
rm -f "$TMPF"
sleep 1
$TMUX_BIN send-keys -t "$CODEX_PANE" Enter

echo "SENT: UUID=$UUID"
echo "END_SENTINEL=$END"
```

Remember the `$END` value — you need it for the poll loop.

### 3B.2 — Poll for Codex to finish, then extract

Codex's TUI echoes the typed prompt (including the END sentinel), and
then emits its OWN END at the tail of its response. Poll until we see
TWO END occurrences (my echo + Codex's emission), then extract between
them.

```bash
set -euo pipefail
TMUX_BIN=/opt/homebrew/bin/tmux
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# $TMUX_PANE isn't always inherited by CC's bash subshells (see Invariant
# #9); fall back to the currently-active pane via tmux. The arg order
# below also matters: `-t` must precede the format string, or tmux
# treats `-t` and its value as positional args and errors with "too
# many arguments" (Invariant #10).
CC_PANE="${TMUX_PANE:-$($TMUX_BIN display-message -p '#{pane_id}')}"
WINDOW_ID=$($TMUX_BIN display-message -p -t "$CC_PANE" '#{window_id}')
SESSION_DIR="$REPO_ROOT/.context/codex-pair/$WINDOW_ID"
CODEX_PANE=$(cat "$SESSION_DIR/pane-id")
# $END is the sentinel from 3B.1

DEADLINE=$(( $(date +%s) + 300 ))

# Wait for TWO END occurrences, not one. Breaking on the first means you
# abort while Codex is still thinking. Credit: Codex review 2026-04-24
# item 1/CRITICAL.
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  COUNT=$($TMUX_BIN capture-pane -t "$CODEX_PANE" -p -J -S -5000 2>/dev/null | grep -cF "$END")
  [ "$COUNT" -ge 2 ] && break
  sleep 2
done

CAPTURE=$($TMUX_BIN capture-pane -t "$CODEX_PANE" -p -J -S -5000)

if [ "$(printf '%s\n' "$CAPTURE" | grep -cF "$END")" -lt 2 ]; then
  echo "TIMEOUT: fewer than 2 END sentinels after 5min"
  exit 0
fi

# Extract between the last two ENDs. The LAST END = Codex's echoed END.
# The one just before it = the echo of my typed END. Codex's response
# body = lines strictly between those two. Pure bash — no $<digit> refs
# (Claude Code's slash-command dispatcher would substitute $0/$1/... at
# invocation time and break the skill).
END_LINES=()
while IFS= read -r n; do END_LINES+=("$n"); done \
  < <(printf '%s\n' "$CAPTURE" | grep -nF "$END" | cut -d: -f1)

if [ "${#END_LINES[@]}" -lt 2 ]; then
  echo "EXTRACT_FAIL: fewer than 2 END sentinels"
  RESPONSE=""
else
  if [ -n "${ZSH_VERSION:-}" ]; then
    LAST="${END_LINES[${#END_LINES[@]}]}"
    PREV="${END_LINES[$((${#END_LINES[@]}-1))]}"
  else
    LAST="${END_LINES[$((${#END_LINES[@]}-1))]}"
    PREV="${END_LINES[$((${#END_LINES[@]}-2))]}"
  fi
  RESPONSE=$(printf '%s\n' "$CAPTURE" | sed -n "$((PREV+1)),$((LAST-1))p")
fi

printf '%s\n' "$RESPONSE"
```

---

## Step 4: Persist the Codex session ID (best-effort)

**Not yet implemented cleanly.** The current Codex TUI doesn't expose a
session ID in a stable location we can parse, so cold-start resume via
`codex exec resume <id>` isn't wired up. Phase 5's push model reduces
the need for this — session memory lives in the long-running pane, and
the pane persists across CC restarts via `$SESSION_DIR/pane-id`.

Skip this step unless/until we implement it. Tracked in `TODO.md`.

---

## Step 5: Present the response to the user

Display the captured response verbatim, wrapped in a clearly-delimited
block. Do not summarize or editorialize inside the block.

```
CODEX SAYS:
════════════════════════════════════════════════════════════
<RESPONSE — verbatim, including Codex's `•` response marker if present>
════════════════════════════════════════════════════════════
Pane: <CODEX_PANE> (<REUSING|SPAWNED>)
Transport: <Phase 5 MCP push | Phase 1 sentinel pull>
<MODEL_WARNING_LINE if $SESSION_DIR/model-warning exists>
```

If `$SESSION_DIR/model-warning` exists, read it and append the contents
as a separate line **inside** the status block (between the bottom rule
and the closing fence, after `Transport:`). Don't reformat — emit the
file's content verbatim. This is how the `--model` reuse-path warning
reaches the user; do not bury it in stderr only. The warning file is
cleared at the gate of the next invocation, so it only surfaces on the
turn that earned it.

After the block, you may add your own synthesis as a separate paragraph
— e.g. "I agree with Codex on X but disagree on Y because Z." Never edit
Codex's words inside the block.

---

## Error handling

- **`MISSING: codex-binary`** — Codex not installed. Tell user to run
  `npm install -g @openai/codex` and `codex login`.
- **`MISSING: tmux-session`** — CC is not running in tmux. Tell user the
  skill requires tmux.
- **`STALE: <pane>`** — the saved pane is dead. The skill already handled
  it by respawning; just note "Codex pane was gone; started fresh."
- **`TIMEOUT: fewer than 2 END sentinels after 5min`** (Phase 1 only) —
  Codex didn't finish in 5 minutes, or didn't echo the sentinel.
  Possible causes: Codex is wedged, non-cooperative with the sentinel
  instruction, or waiting for permission approval. Tell the user:
  "Codex didn't respond within 5 minutes. Check pane `<CODEX_PANE>`
  for its current state."
- **MCP tool call fails (Phase 5)** — the bridge server might not be
  running or registered. Run `tmux_doctor()` to diagnose. **Fail the
  turn cleanly** — do NOT silently switch transports mid-flow (per
  Invariant: transport is selected once per turn). Tell the user to
  re-invoke with `/codex-pair --phase1 <prompt>` for an explicit
  fallback, or fix the bridge and retry.
- **Phase 5 reply never arrives** — Codex may have ignored the bootstrap
  contract, or its pane is waiting on approval. Open the pane
  (`tmux select-pane -t <codex_pane>`) and check visually.

---

## Bridge usage contract (reference, Phase 5 only)

Verbatim from
`repos/tmux-bridge-mcp/system-instruction/smux-skill.md`. Keep in sync
if the bridge updates upstream.

1. **Read before act.** Always call `tmux_read` before `tmux_type`,
   `tmux_message`, or `tmux_keys`. The bridge enforces this via a
   per-pane read guard in `/tmp/tmux-bridge-guards/`.
2. **Read-Act-Read cycle.** After typing, read again to verify the text
   landed, *then* send Enter via `tmux_keys`.
3. **Never poll for replies.** The peer pushes its response into *your*
   pane via `tmux_message`. Do not loop or sleep on `tmux_read` of the
   peer's pane waiting for a reply.
4. **Label panes early.** Use `tmux_name` at spawn to give panes
   human-readable labels so neither side has to pass raw `%N` IDs around.

### Tool quick reference

| Tool | Purpose |
|------|---------|
| `tmux_list` | List all panes with process, label, cwd |
| `tmux_read(target, lines)` | Read last N lines; satisfies the read-guard |
| `tmux_type(target, text)` | Type text without Enter; requires prior read |
| `tmux_message(target, text)` | Type w/ auto sender-ID prefix; requires prior read |
| `tmux_keys(target, [keys])` | Send special keys; requires prior read |
| `tmux_name(target, label)` | Label a pane for easy targeting |
| `tmux_resolve(label)` | Look up pane ID by label |
| `tmux_id()` | Print *your* pane's tmux ID |
| `tmux_doctor()` | Diagnose tmux connectivity issues |

---

## Important invariants

1. **Never modify files under `$SESSION_DIR/` outside this skill** —
   `pane-id`, `bootstrap.json`, `pending/<req-id>.json`, `lock/`,
   `health.json`, `flag-phase1`, `skill-args-rest`. Those files are
   the single source of truth for lifecycle, single-flight,
   correlation, and health state. Manual edits should only happen via
   the `--reset-pending` / `--rebootstrap` recovery flags.
2. **Never kill the Codex pane from the skill.** Only the user (via `q`
   or `exit` in Codex, or tmux pane-close) should close it. Respawn
   handles the case where it's already gone.
3. **Always use `$TMUX_BIN=/opt/homebrew/bin/tmux` and
   `$CODEX_BIN=$(command -v codex)`** as absolute paths in bash
   snippets. CC runs bash through zsh, and the oh-my-zsh `tmux` plugin
   replaces bare `tmux` with a function that isn't defined in
   subshells — bare `tmux` calls fail silently. Same rationale for
   `codex` in subshells where PATH differs.
4. **Always anchor state to `$SESSION_DIR`**, which is
   `$REPO_ROOT/.context/codex-pair/$WINDOW_ID/`. `REPO_ROOT` comes
   from `git rev-parse --show-toplevel` (falls back to `pwd`).
   `WINDOW_ID` is from `tmux display-message -p '#{window_id}'`.
   This per-window scoping prevents two `/codex-pair` sessions in
   different tmux windows of the same repo from stomping each
   other's pane-id, lock, and pending state. Relative `.context/`
   paths fragment when the skill is invoked from a subdirectory;
   the absolute resolution avoids that.

5. **Routing uses pane IDs (`%N`), not labels.** Every call to
   `tmux_message`, `tmux_read`, `tmux_keys`, etc. uses the raw pane
   ID captured in Step 1 as the `target=` argument. Labels are set
   by `tmux_name` (in Step 3A.1 / commit 4) but only for the
   human-visible tmux pane border — never for routing. Pane IDs
   are globally unique within a tmux server and always present in
   the bridge's `[tmux-bridge from:... pane:%N id:...]` header, so
   matching on them is robust against label collisions, missing
   labels, or labels Codex never set.
6. **Use bracketed paste (`load-buffer` + `paste-buffer -p`) for
   multi-line prompt delivery in Phase 1.** Plain `send-keys -l` types
   embedded newlines as Enter keypresses and submits partial prompts.
7. **In Phase 5, never poll.** Codex pushes responses to CC's pane via
   `tmux_message`. Your turn ends after delivering the prompt.
8. **5-minute ceiling** on the Phase 1 poll loop. A wedged Codex should
   fail cleanly, not hang CC's turn.
9. **Resolve CC's pane via `${TMUX_PANE:-fallback}`, not bare
   `$TMUX_PANE`.** tmux only exports `TMUX_PANE` to processes spawned
   directly into a pane; CC's bash subshells inherit it inconsistently
   (sometimes set, sometimes empty). Every block that needs the CC
   pane uses
   `CC_PANE="${TMUX_PANE:-$($TMUX_BIN display-message -p '#{pane_id}')}"`
   so it works either way. The fallback gets the currently-active
   pane, which in normal use is the CC pane the user is reading.
10. **`tmux display-message` requires `-t` BEFORE the format string.**
    Order matters: `display-message -p -t %2 '#{window_id}'` works,
    but `display-message -p '#{window_id}' -t %2` errors with
    "command display-message: too many arguments (need at most 1)"
    because `-t %2` after the format gets parsed as positional. Every
    bash block in this skill uses the correct order. If you add a new
    `display-message` call, put `-t` (and any other flag) before the
    format.

---

## What this skill does NOT do (yet)

- **Cold-start `codex exec resume`** on dead-pane respawn (Step 4 is a
  stub).
- **Readiness probe** after pane spawn — uses a blind `sleep 4` (Codex
  review item 9, open).
- **Serialization between concurrent `/codex-pair` invocations** — no
  lockfile (Codex review item 2, open).
- **Graceful handoff when CC is mid-turn during a Phase 5 push** — the
  bridge's `tmux_message` injects into CC's input box regardless of
  CC's state (Codex review item 12, open).
- **Review / challenge modes** as distinct sub-commands (like gstack's
  /codex). Phase 2 work.
- **Auth-error detection** in the Codex pane — the error-handling doc
  claims this but no step inspects for it (Codex review item 10, open).

See `TODO.md` in this skill's directory for the full open-issues list
with severity and line-number references.
