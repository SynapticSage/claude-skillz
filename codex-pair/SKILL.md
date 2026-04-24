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
WINDOW_ID=$($TMUX_BIN display-message -p '#{window_id}' -t "$TMUX_PANE")
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
WINDOW_ID=$($TMUX_BIN display-message -p '#{window_id}' -t "$TMUX_PANE")
SESSION_DIR="$REPO_ROOT/.context/codex-pair/$WINDOW_ID"
PENDING_DIR="$SESSION_DIR/pending"

STALE_AFTER_MIN=60
NOW=$(date +%s)
HOLD=0
HELD_BY=""
HELD_AGE_S=0
STALE_FILES=()

if [ -d "$PENDING_DIR" ]; then
  for f in "$PENDING_DIR"/*.json; do
    [ -e "$f" ] || continue   # glob match nothing → no files
    AGE_S=$(( NOW - $(stat -f %m "$f") ))   # macOS stat -f %m = mtime
    AGE_MIN=$(( AGE_S / 60 ))
    if [ "$AGE_MIN" -lt "$STALE_AFTER_MIN" ]; then
      HOLD=1
      HELD_BY="$(basename "$f" .json)"
      HELD_AGE_S="$AGE_S"
      break
    else
      STALE_FILES+=("$f")
    fi
  done
fi

if [ $HOLD -eq 1 ]; then
  echo "HOLD: pending request $HELD_BY still active (${HELD_AGE_S}s old)"
  echo "  Use /codex-pair --reset-pending to clear, or wait for reply."
  exit 0
fi

# Clear stale, proceed.
for f in "${STALE_FILES[@]:-}"; do
  [ -e "$f" ] || continue
  echo "STALE: clearing $(basename "$f") (>${STALE_AFTER_MIN}min old)"
  rm -f "$f"
done

echo "GATE: clear"
```

If output starts with `HOLD:`, **stop** and surface the message to the
user verbatim. Do not proceed to Step 1.

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
WINDOW_ID=$($TMUX_BIN display-message -p '#{window_id}' -t "$TMUX_PANE")
SESSION_DIR="$REPO_ROOT/.context/codex-pair/$WINDOW_ID"

PANE_FILE="$SESSION_DIR/pane-id"
CC_PANE="$TMUX_PANE"   # the pane CC is running in — split-window targets this

CODEX_PANE=""
FRESH_SPAWN=0

if [ -f "$PANE_FILE" ]; then
  SAVED=$(cat "$PANE_FILE")
  if $TMUX_BIN list-panes -a -F '#{pane_id}' | grep -qFx "$SAVED"; then
    CODEX_PANE="$SAVED"
    echo "REUSING: $CODEX_PANE"
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
  CODEX_PANE=$($TMUX_BIN split-window -h -d -P -F '#{pane_id}' -t "$CC_PANE" "$CODEX_BIN")
  echo "$CODEX_PANE" > "$PANE_FILE"
  echo "SPAWNED: $CODEX_PANE"
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

### 3A.1 — Bootstrap Codex (always, on Phase 5 path)

**Run this block every time the Phase 5 path is taken, regardless of
`FRESH_SPAWN`.** A reused Codex pane may predate Codex's own MCP-loading
restart — it would have bridge tools unavailable even though CC has
them. Cheapest fix: always re-run the bootstrap and let it be a no-op
when Codex is already set up. Phrase the preamble so Codex skips
observable actions when already bootstrapped (the `tmux_name` calls are
idempotent; re-reading the contract costs ~1 Codex turn but is safe).
Credit: Codex review 2026-04-24 Part B #2 / HIGH.

The Codex pane needs to know:
- It has `tmux-bridge` MCP tools available (Codex loaded the same server).
- The CC pane's ID and label.
- The contract rules (read before act, don't poll, push replies via
  `tmux_message`).

Build a bootstrap message and send it via bracketed paste (same mechanism
as Phase 1 — see Step 3B.1), then Enter:

```
You are paired with Claude Code in tmux pane <CC_PANE>.
You have MCP tools from `tmux-bridge` for cross-pane messaging.

Contract:
  1. Read before write. Always call tmux_read(target) before tmux_type,
     tmux_message, or tmux_keys on that target.
  2. Read-Act-Read cycle. After typing, read again to verify text landed,
     then send Enter via tmux_keys.
  3. Never poll for replies. Claude will push new prompts into YOUR pane
     with a [tmux-bridge from:claude ...] header; you receive them as
     ordinary input.
  4. To reply to Claude, call:
        tmux_read(target="<CC_PANE>")
        tmux_message(target="<CC_PANE>", text=YOUR_RESPONSE)
        tmux_read(target="<CC_PANE>")
        tmux_keys(target="<CC_PANE>", keys=["Enter"])

CORRELATION (important):
  Every prompt Claude sends you will be tagged with a line like
  [req:<8-char-uuid>] at the start of the message body. When you reply,
  YOUR_RESPONSE must include the corresponding line:
        [reply-to:<8-char-uuid>]
  on its own line in your response (anywhere — header or footer is fine).
  Match the uuid exactly to the [req:...] tag on the prompt you are
  answering. Without this, Claude cannot match your reply to the right
  pending request and will treat your message as unsolicited or as a
  protocol violation.

Upstream full contract:
  cat ~/.claude/skills/codex-pair/vendor/tmux-bridge-mcp/system-instruction/smux-skill.md

Wait for the user's actual prompt in the next message.
```

Substitute `<CC_PANE>` with the value from Step 1. Deliver this block via
the bracketed-paste mechanism in Step 3B.1 below (yes, we use Phase 1
mechanics to bootstrap Phase 5 — this is the one thing we can't do via
MCP on first spawn because Codex hasn't been told about the bridge yet).
After sending, wait ~5s for Codex to register the labels, then proceed
to 3A.2.

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
WINDOW_ID=$($TMUX_BIN display-message -p '#{window_id}' -t "$TMUX_PANE")
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
  "cc_pane": "${TMUX_PANE}"
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

Then call the bridge tools in order:

1. **Verify the Codex pane is still present:**
   - `tmux_list()` → confirm an entry whose `target` matches
     `$CODEX_PANE_ID`. If absent, delete the just-created pending
     file and fall through to error handling.
2. **Read to satisfy the bridge's read-before-act guard:**
   - `tmux_read(target=$CODEX_PANE_ID, lines=20)`.
3. **Send the tagged prompt:**
   - `tmux_message(target=$CODEX_PANE_ID, text=TAGGED_PROMPT)`.
4. **Re-read to verify text landed:**
   - `tmux_read(target=$CODEX_PANE_ID, lines=5)`.
5. **Submit:**
   - `tmux_keys(target=$CODEX_PANE_ID, keys=["Enter"])`.
6. **Stop.** End CC's turn with:
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
WINDOW_ID=$($TMUX_BIN display-message -p '#{window_id}' -t "$TMUX_PANE")
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
  rm -f "$PENDING_FILE"   # clear the pending entry on success
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
WINDOW_ID=$($TMUX_BIN display-message -p '#{window_id}' -t "$TMUX_PANE")
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
WINDOW_ID=$($TMUX_BIN display-message -p '#{window_id}' -t "$TMUX_PANE")
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
the pane persists across CC restarts via `.context/codex-pane-id`.

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
```

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
  running or registered. Run `tmux_doctor()` to diagnose. If the bridge
  is broken, fall back to Phase 1 for this turn.
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

1. **Never modify `.context/codex-pane-id` or `codex-session-id` outside
   this skill.** Those are the single source of truth for lifecycle
   state.
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
