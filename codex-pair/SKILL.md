---
name: codex-pair
description: |
  Pair-program with OpenAI Codex as a teammate. Spawns and manages a persistent
  Codex CLI in a sibling tmux pane, hands it prompts, and captures responses
  verbatim — preserving session memory across turns. Uses ChatGPT subscription
  (via `codex login`), not OpenAI API. Transport is raw tmux today; swaps to
  tmux-bridge-mcp for bidirectional Codex↔CC calls once install.sh is run.
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
Each invocation routes a prompt to that pane and captures the response by
polling the pane's scrollback for a pair of unique sentinel tokens. Pane ID
and Codex session ID persist in `.context/` so they survive across skill
invocations and CC restarts.

**Phase 1 transport:** raw `tmux send-keys` + `capture-pane`. No MCP server.
**Phase 5 transport:** `tmux-bridge-mcp` tool calls. Swap-in only; the rest of
the skill is unchanged.

## First-time setup

If `tmux-bridge-mcp` has never been built and registered, tell the user:

> First-time setup needed. Run `.claude/skills/codex-pair/install.sh --dry-run`
> to preview, then drop `--dry-run` to apply. That builds the bridge, registers
> it with Claude Code (project-local), and registers it with Codex.

The install script is idempotent. Re-running it only adds missing pieces.

---

## Step 0: Preflight

Run this block first. Stop and tell the user what's missing if any check fails.

```bash
set -u

# Codex CLI must be on PATH
CODEX_BIN=$(command -v codex 2>/dev/null || true)
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

# State dir (pane ID, session ID, prompt/response scratch)
mkdir -p .context

# Add to .gitignore if not already there — .context/ holds scratch,
# session IDs, and other per-checkout state that should never be committed
if [ -f .gitignore ] && ! grep -qE '^\.context/?$' .gitignore; then
  echo "" >> .gitignore
  echo "# Codex skill state (pane ID, session ID, transient prompts)" >> .gitignore
  echo ".context/" >> .gitignore
fi

echo "OK: codex=$CODEX_BIN tmux=$TMUX"
```

If output starts with `MISSING:`, stop and relay the message to the user.
Do not proceed to Step 1.

---

## Step 1: Attach to or spawn the Codex pane

The Codex pane is the long-running resource. We cache its pane ID in
`.context/codex-pane-id`. On each invocation:

1. If the cache file exists, verify the pane is still alive.
2. If alive, reuse it (this is the common path).
3. If dead or missing, spawn a new sibling pane running `codex`.

```bash
set -u
PANE_FILE=".context/codex-pane-id"
CC_PANE="$TMUX_PANE"   # the pane CC is running in — needed for split-window target

CODEX_PANE=""

if [ -f "$PANE_FILE" ]; then
  SAVED=$(cat "$PANE_FILE")
  if tmux list-panes -a -F '#{pane_id}' | grep -qFx "$SAVED"; then
    CODEX_PANE="$SAVED"
    echo "REUSING: $CODEX_PANE"
  else
    echo "STALE: $SAVED (pane gone — respawning)"
    rm -f "$PANE_FILE"
  fi
fi

if [ -z "$CODEX_PANE" ]; then
  # Split the CC pane horizontally. -d keeps CC focused. -P prints the new
  # pane ID. -F formats it. Launches `codex` as the pane's initial command.
  CODEX_PANE=$(tmux split-window -h -d -P -F '#{pane_id}' -t "$CC_PANE" 'codex')
  echo "$CODEX_PANE" > "$PANE_FILE"
  echo "SPAWNED: $CODEX_PANE"
  # Codex takes a few seconds to boot its TUI. Give it time before sending.
  sleep 4
fi

echo "CODEX_PANE=$CODEX_PANE"
```

Remember whether this turn used `REUSING` or `SPAWNED` — include it in the
final status line so the user knows whether Codex is fresh or continuing.

---

## Step 2: Gather the user's prompt

For Phase 1 the skill supports one mode: **consult**. Everything after
`/codex-pair` is the prompt. If the user said just `/codex-pair` with no
args, ask them what they want to ask Codex.

If the prompt is empty, use AskUserQuestion:

```
What would you like to ask Codex?
A) Review the current diff against the base branch
B) Ask a free-form question (I'll provide the prompt)
C) Cancel
```

For A, construct the prompt: `"Review the changes on this branch against the
base branch. Run git diff to see them. Flag bugs, edge cases, and anything
that looks wrong."`

For B, ask what the question is.

---

## Step 3: Send the prompt + capture the response

The hard part. Codex's pane is an interactive TUI — output interleaves the
user's typed prompt, Codex's thinking, tool-use display, the agent message,
and the idle prompt glyph. We can't parse that reliably. Two sentinels
bracket the response so extraction is unambiguous:

- **START sentinel** — embedded in the prompt. Codex will echo it when it
  reads our message.
- **END sentinel** — we ask Codex to emit it on its own line at the end of
  its response.

Both sentinels contain a UUID so old ones in scrollback don't collide.

```bash
set -u
# Short sentinels — must NOT wrap in a narrow Codex TUI. A full UUID
# makes the token 40+ chars and wraps in panes under ~45 columns, after
# which `grep -F "$END"` against the wrapped pane buffer returns zero
# matches. Use an 8-char UUID slice: token length ≤ 20 chars, safe down
# to ~30-col panes.
UUID=$(uuidgen | tr -d '\n-' | tr '[:upper:]' '[:lower:]' | cut -c1-8)
START="§cx:${UUID}:S§"
END="§cx:${UUID}:E§"

# The prompt CC types into the Codex pane. PROMPT_TEXT is the user's
# actual question (set by Step 2).
WRAPPED=$(cat <<EOF
${START}
${PROMPT_TEXT}

When your response is complete, output this exact line (and nothing after it):
${END}
EOF
)

# Delivery via tmux paste-buffer with bracketed-paste (-p). This is critical:
# send-keys -l types newlines as Enter keypresses, which would make Codex's
# TUI submit each line individually. Bracketed paste tells the TUI to treat
# the whole block as one paste event, preserving the multi-line structure,
# and our explicit Enter at the end is what actually submits.
BUF="codex-pair-$UUID"
TMPF=$(mktemp)
printf '%s' "$WRAPPED" > "$TMPF"
tmux load-buffer -b "$BUF" "$TMPF"
tmux paste-buffer -b "$BUF" -t "$CODEX_PANE" -p
tmux delete-buffer -b "$BUF"
rm -f "$TMPF"
tmux send-keys -t "$CODEX_PANE" Enter

echo "SENT: UUID=$UUID"
```

Then poll the pane for the END sentinel. Ceiling: 5 minutes. Long enough
for complex prompts; short enough to fail fast on a wedged Codex.

```bash
set -u
DEADLINE=$(( $(date +%s) + 300 ))

# Wait for TWO END occurrences, not one. The pane scrollback will
# contain the END from the echo of your typed prompt AND the END that
# Codex emits at the tail of its response. Breaking on the first means
# you abort while Codex is still thinking; extraction then fails because
# the last-two-ENDs extractor expects both to exist. Credit: Codex
# review item 1/CRITICAL.
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  COUNT=$(tmux capture-pane -t "$CODEX_PANE" -p -J -S -5000 2>/dev/null | grep -cF "$END")
  [ "$COUNT" -ge 2 ] && break
  sleep 2
done

# Capture the full scrollback after the sentinel appeared
CAPTURE=$(tmux capture-pane -t "$CODEX_PANE" -p -J -S -5000)

if ! echo "$CAPTURE" | grep -qF "$END"; then
  echo "TIMEOUT: no END sentinel after 5min"
  exit 0
fi

# Extract Codex's response. Tricky: the sentinels appear TWICE in the
# pane scrollback. Once when Codex's TUI echoes my typed prompt (both
# START and END present in that echo), once when Codex emits the END
# sentinel at the end of its own response. So:
#   - The LAST END in the capture = Codex's echoed END.
#   - The END just before it = the echo of my typed END.
#   - Codex's response body = lines strictly between those two ENDs.
# Naive "first START to first END" gets the instruction text, not the
# response. Pure bash only — no $<digit> refs that Claude Code's slash-
# command dispatcher would substitute at invocation time.
END_LINES=()
while IFS= read -r n; do END_LINES+=("$n"); done < <(printf '%s\n' "$CAPTURE" | grep -nF "$END" | cut -d: -f1)
if [ "${#END_LINES[@]}" -lt 2 ]; then
  echo "EXTRACT_FAIL: fewer than 2 END sentinels in capture (saw ${#END_LINES[@]})"
  RESPONSE=""
else
  # zsh arrays are 1-indexed. Use ${#END_LINES[@]} for last, and the
  # entry just before it for prev. In bash, 0-indexed → adjust to N-1 and N-2.
  if [ -n "${ZSH_VERSION:-}" ]; then
    LAST="${END_LINES[${#END_LINES[@]}]}"
    PREV="${END_LINES[$((${#END_LINES[@]}-1))]}"
  else
    LAST="${END_LINES[$((${#END_LINES[@]}-1))]}"
    PREV="${END_LINES[$((${#END_LINES[@]}-2))]}"
  fi
  RESPONSE=$(printf '%s\n' "$CAPTURE" | sed -n "$((PREV+1)),$((LAST-1))p")
fi

echo "RESPONSE_LENGTH=${#RESPONSE}"
# Print the response so CC can include it in its turn output
printf '%s\n' "$RESPONSE"
```

---

## Step 4: Persist the Codex session ID (for cold-start resume)

Codex prints a session ID when a new thread starts. Capture it from the
pane scrollback after the first exchange and cache it in
`.context/codex-session-id`. On a future run, if the pane is dead, we can
`codex exec resume <id>` to rehydrate memory even though the pane is new.

```bash
SESSION_FILE=".context/codex-session-id"
if [ ! -f "$SESSION_FILE" ]; then
  # Codex prints "session: <uuid>" or similar in its TUI header. Exact
  # format depends on Codex version — read scrollback from the top.
  SID=$(tmux capture-pane -t "$CODEX_PANE" -p -J -S -2000 \
        | grep -oE 'session[: ]+[a-f0-9-]{16,}' \
        | head -1 | grep -oE '[a-f0-9-]{16,}' || true)
  if [ -n "$SID" ]; then
    echo "$SID" > "$SESSION_FILE"
    echo "SESSION_CAPTURED: $SID"
  fi
fi
```

Do not fail the skill if the session ID can't be parsed — that's a
nice-to-have, not a must-have for Phase 1.

---

## Step 5: Present the response to the user

Display the captured `$RESPONSE` verbatim, wrapped in a clearly-delimited
block. Do not summarize or editorialize inside the block.

```
CODEX SAYS:
════════════════════════════════════════════════════════════
<RESPONSE>
════════════════════════════════════════════════════════════
Pane: <CODEX_PANE> (<REUSING|SPAWNED>)
Session: <SID or "uncaptured">
```

After the block, CC may add its own synthesis as a separate paragraph —
e.g. "I agree with Codex on X but disagree on Y because Z." Never edit
Codex's words inside the block.

---

## Error handling

- **`MISSING: codex-binary`** — Codex not installed. Tell user to run
  `npm install -g @openai/codex` and `codex login`.
- **`MISSING: tmux-session`** — CC is not running in tmux. Tell user the
  skill requires tmux.
- **`STALE: <pane>`** — the saved pane is dead. The skill already handled
  it by respawning; just note "Codex pane was gone; started fresh."
- **`TIMEOUT: no END sentinel`** — Codex didn't finish in 5 minutes, or
  didn't echo the sentinel. Possible causes: Codex is wedged,
  non-cooperative with the sentinel instruction, or waiting for
  permission approval. Tell the user: "Codex didn't respond within 5
  minutes. Check pane <CODEX_PANE> for its current state."
- **Codex auth error** — if Codex prints "auth required" in its pane,
  surface that and tell user to run `codex login`.

---

## Phase 5 — Bidirectional via tmux-bridge MCP

> This section activates **after** `install.sh` has built the bridge and
> registered it with both CC and Codex. Until then, ignore it and stick with
> Phase 1 (raw-tmux, pull model).

### Design shift: push, not pull

Phase 1 has CC *pull* from Codex's pane — CC sends a prompt, then polls
`capture-pane` for an END sentinel. That blocks CC's turn until Codex
finishes (or times out at 5 minutes). Phase 5 inverts this:

- CC calls `tmux_message` to deliver the prompt to Codex's pane, **then
  CC's turn ends cleanly**.
- Codex processes at its own pace.
- When Codex is done, **Codex** calls `tmux_message` to deliver the
  response back into CC's pane. That arrives as new user input, which
  triggers a fresh CC turn where CC presents the response to the user.

Consequence: the `/codex-pair` invocation no longer holds CC hostage while
Codex thinks. Each agent operates at its own pace and hands off
asynchronously. The user may see an intermediate "Asked Codex; awaiting
reply" message, then a later turn with the actual answer.

### Bridge usage contract

Both sides follow these rules (copied from
`repos/tmux-bridge-mcp/system-instruction/smux-skill.md`, which is the
upstream contract — keep in sync if the bridge updates):

1. **Read before act.** Always call `tmux_read` before `tmux_type`,
   `tmux_message`, or `tmux_keys`. The bridge enforces this via a
   per-pane read guard in `/tmp/tmux-bridge-guards/`; writes without
   a prior read throw.
2. **Read-Act-Read cycle.** After typing, read again to verify the text
   landed correctly, *then* send Enter via `tmux_keys`.
3. **Never poll for replies.** The peer pushes its response into *your*
   pane via `tmux_message`. Do not loop or sleep on `tmux_read` of the
   peer's pane waiting for a reply.
4. **Label panes early.** Use `tmux_name` on spawn to give panes
   human-readable labels (`claude`, `codex`) so neither side has to pass
   raw `%N` pane IDs around.

### Tool reference

| Tool | Purpose |
|------|---------|
| `tmux_list` | List all panes with process, label, cwd |
| `tmux_read(target, lines)` | Read last N lines from a pane (satisfies guard) |
| `tmux_type(target, text)` | Type text without Enter (requires prior read) |
| `tmux_message(target, text)` | Type message with auto sender-ID prefix (requires prior read) |
| `tmux_keys(target, [keys])` | Send special keys: Enter, Escape, C-c, etc. (requires prior read) |
| `tmux_name(target, label)` | Label a pane for easy targeting |
| `tmux_resolve(label)` | Look up pane ID by label |
| `tmux_id()` | Print *your* pane's tmux ID |
| `tmux_doctor()` | Diagnose tmux connection issues |

### Phase 5 workflow: CC → Codex

```
1. tmux_list()                          → verify codex pane exists
2. tmux_name(codex_pane, "codex")       → (once, on first-ever spawn)
3. tmux_read(codex_pane, 20)            → satisfy guard, see idle state
4. tmux_message(codex_pane, prompt)     → deliver with auto [from:claude] header
5. tmux_read(codex_pane, 5)             → verify prompt landed
6. tmux_keys(codex_pane, ["Enter"])     → submit
   STOP. Do not read codex_pane again. Codex will push its reply.
```

CC's turn ends here. When Codex's response arrives as pasted input into
CC's pane, CC starts a new turn and presents the response to the user
(stripping the `[tmux-bridge from:codex ...]` sender prefix from display).

### Phase 5 workflow: Codex bootstrap (one-time, on spawn)

The first time we spawn Codex's pane in Phase 5, type a bootstrap
message before the user's actual prompt:

```
You are paired with Claude Code in tmux pane %<CC_PANE_ID> (label: "claude").
You have MCP tools from `tmux-bridge` for cross-pane messaging. Before using
them, read the contract:

  cat /Users/ryoung/Code/repos/tmux-manage/repos/tmux-bridge-mcp/system-instruction/smux-skill.md

Key rules:
  - Read a pane (tmux_read) before writing to it — the bridge enforces this.
  - To reply to Claude Code, use tmux_message(target="claude", text=...) then
    tmux_read then tmux_keys(target="claude", keys=["Enter"]).
  - Do NOT poll the claude pane for new prompts; you'll receive them as
    ordinary input into your pane, with a [tmux-bridge from:claude ...] header.

Call tmux_name(target=tmux_id(), label="codex") now to label yourself so
Claude can target you by name instead of by raw pane ID.
```

That primer runs once per Codex lifetime; Codex's session memory retains
it for subsequent turns.

### Phase 5 extraction — no sentinels needed

Under Phase 5, CC doesn't need to extract Codex's response from pane
scrollback. Codex's `tmux_message` call types the response directly
into CC's input, where it arrives as ordinary user input (prefixed with
the bridge's `[tmux-bridge from:codex ...]` header). CC reads it the
same way it reads any other user message — just strip the header for
display.

The sentinel-extraction logic (Step 3 above) is Phase 1 only.

---

## Important invariants

1. **Never modify `.context/codex-pane-id` or `codex-session-id` outside
   this skill.** Those are the single source of truth for lifecycle state.
2. **Never kill the Codex pane from the skill.** Only the user (via `q` or
   `exit` in Codex, or tmux pane-close) should close it. Respawn handles
   the case where it's already gone.
3. **Always use `/opt/homebrew/bin/tmux` as the absolute path** for tmux
   invocations. When CC runs bash through zsh, the oh-my-zsh `tmux` plugin
   replaces the `tmux` command with a function (`_zsh_tmux_plugin_run`)
   that isn't defined in subshells, so plain `tmux ...` calls fail
   silently. This matches the repo-wide convention noted in `CLAUDE.md`.
4. **Use bracketed paste (`load-buffer` + `paste-buffer -p`) to deliver
   multi-line prompts.** Plain `send-keys -l` types embedded newlines as
   Enter keypresses, which makes Codex's TUI submit partial prompts. The
   `-p` flag on `paste-buffer` enables bracketed paste mode so the TUI
   treats the whole block as one paste event.
5. **5-minute ceiling** on the capture loop. Never poll forever; a wedged
   Codex should fail the skill cleanly, not hang CC's turn.

---

## What this skill does NOT do (yet)

- Review / challenge modes (Phase 2 — add as alternate prompts in Step 2)
- Codex-initiated callbacks to CC (Phase 5 — needs `tmux-bridge-mcp`)
- One-shot mode via `codex exec` (Phase 2 — add as `--one-shot` flag)
- Cross-model agreement analysis with CC's `/review` (Phase 2)
- Automatic pane-close on CC shutdown (pane persists across CC restarts
  by design; user closes it manually when done)
