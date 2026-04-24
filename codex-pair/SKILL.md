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
mkdir -p "$REPO_ROOT/.context"

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

echo "OK: codex=$CODEX_BIN tmux=$TMUX_BIN repo_root=$REPO_ROOT"
```

If output starts with `MISSING:`, stop and relay the message to the user.
Do not proceed to Step 1.

The variables `TMUX_BIN`, `CODEX_BIN`, and `REPO_ROOT` are used in every
subsequent bash block — re-declare them at the top of each block (each
bash call is a separate subshell and does not inherit these).

---

## Step 1: Attach to or spawn the Codex pane

The Codex pane is the long-running resource. We cache its pane ID in
`$REPO_ROOT/.context/codex-pane-id`. On each invocation:

1. If the cache file exists, verify the pane is still alive.
2. If alive, reuse it (this is the common path).
3. If dead or missing, spawn a new sibling pane running `codex`.

```bash
set -euo pipefail
TMUX_BIN=/opt/homebrew/bin/tmux
CODEX_BIN=$(command -v codex)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

PANE_FILE="$REPO_ROOT/.context/codex-pane-id"
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

echo "$FRESH_SPAWN" > "$REPO_ROOT/.context/codex-fresh-spawn"
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

### 3A.1 — Bootstrap Codex on the first spawn

**Only run this block if `FRESH_SPAWN=1` from Step 1.** A reused pane has
already been bootstrapped; re-running it would waste a Codex turn.

The Codex pane needs to know:
- It has `tmux-bridge` MCP tools available (Codex loaded the same server).
- The CC pane's ID and label.
- The contract rules (read before act, don't poll, push replies via
  `tmux_message`).

Build a bootstrap message and send it via bracketed paste (same mechanism
as Phase 1 — see Step 3B.1), then Enter:

```
You are paired with Claude Code in tmux pane <CC_PANE> (label: "claude").
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
        tmux_read(target="claude")
        tmux_message(target="claude", text=YOUR_RESPONSE)
        tmux_read(target="claude")
        tmux_keys(target="claude", keys=["Enter"])

Upstream full contract (read if you want the long form):
  cat ~/.claude/skills/codex-pair/vendor/tmux-bridge-mcp/system-instruction/smux-skill.md
  (or from tmux_list: the bridge dist lives at the path in your codex config)

Before anything else, label yourself:
  tmux_name(target=tmux_id(), label="codex")

Also label Claude's pane:
  tmux_name(target="<CC_PANE>", label="claude")

Then wait for the user's actual prompt in the next message.
```

Substitute `<CC_PANE>` with the value from Step 1. Deliver this block via
the bracketed-paste mechanism in Step 3B.1 below (yes, we use Phase 1
mechanics to bootstrap Phase 5 — this is the one thing we can't do via
MCP on first spawn because Codex hasn't been told about the bridge yet).
After sending, wait ~5s for Codex to register the labels, then proceed
to 3A.2.

### 3A.2 — Deliver the user's prompt via MCP

Now use the bridge tools directly. This is where Phase 5 pays off — no
sentinels, no polling, no scrollback parsing:

1. **Verify the Codex pane by label:**
   - Call `tmux_list()` and confirm a pane labeled `codex` exists.
2. **Read Codex's pane to satisfy the bridge's read-before-act guard:**
   - Call `tmux_read(target="codex", lines=20)`.
3. **Send the prompt with sender-identity prefix auto-attached:**
   - Call `tmux_message(target="codex", text=PROMPT_TEXT)`.
4. **Re-read to verify the text landed in Codex's input buffer:**
   - Call `tmux_read(target="codex", lines=5)`.
5. **Submit:**
   - Call `tmux_keys(target="codex", keys=["Enter"])`.
6. **Stop.** End CC's turn with a short message to the user:
   > "Delivered your prompt to Codex (pane `<CODEX_PANE>`). Codex will
   > push its reply here when done — typically 30s–3min depending on the
   > prompt complexity."

Do **NOT** poll `tmux_read(target="codex")` in a loop waiting for the
response. That violates rule 3 of the bridge contract. Codex will
deliver its response by calling `tmux_message(target="claude", ...)`,
which arrives in a new CC turn as user input.

### 3A.3 — Handle Codex's pushed reply (on a future CC turn)

When Codex finishes and pushes its response, CC will receive a new user
message that starts with `[tmux-bridge from:codex pane:%<N> id:<uuid>]`.
That's Codex's reply. Treat it as the response to the prior prompt:

- Strip the `[tmux-bridge from:codex ...]` prefix for display.
- Present the remaining text verbatim in Step 5's format block.
- If the user has an outstanding `/codex-pair` follow-up in the same
  turn, loop back through 3A.2 with the new prompt.

---

## Step 3B — Phase 1 fallback: sentinel-based pull

Use this path when MCP tools aren't available.

### 3B.1 — Send the prompt via bracketed paste

```bash
set -euo pipefail
TMUX_BIN=/opt/homebrew/bin/tmux
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
CODEX_PANE=$(cat "$REPO_ROOT/.context/codex-pane-id")

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
CODEX_PANE=$(cat "$REPO_ROOT/.context/codex-pane-id")
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
4. **Always anchor state to `$REPO_ROOT`** (from
   `git rev-parse --show-toplevel`, falling back to `pwd`). Relative
   `.context/` paths fragment when the skill is invoked from a
   subdirectory.
5. **Use bracketed paste (`load-buffer` + `paste-buffer -p`) for
   multi-line prompt delivery in Phase 1.** Plain `send-keys -l` types
   embedded newlines as Enter keypresses and submits partial prompts.
6. **In Phase 5, never poll.** Codex pushes responses to CC's pane via
   `tmux_message`. Your turn ends after delivering the prompt.
7. **5-minute ceiling** on the Phase 1 poll loop. A wedged Codex should
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
