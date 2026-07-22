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
Each invocation delivers a prompt to that pane and gets Codex's response back.
State persists in the repo-local `.context/codex-pair/<window-id>/` directory,
so it survives across skill invocations and CC restarts.

**Three transports.** The two tmux transports are selected at Step 3 by whether
the `tmux-bridge` MCP tools are loaded; a third, `--exec`, needs no tmux at all:

- **Phase 5 (preferred, bidirectional push):** bridge MCP tools available →
  Codex replies by pushing back into CC's pane, so CC's turn ends cleanly after
  delivering the prompt.
- **Phase 1 (fallback, one-way pull):** no bridge tools → raw `tmux send-keys` /
  `capture-pane` with sentinel-based extraction.
- **Exec (tmux-free, synchronous):** `--exec`, or automatically when CC isn't
  inside tmux → run `codex exec` non-interactively, capture the reply directly,
  resume the session by thread id. No pane, no bootstrap, no sentinels. See
  Step 3C. This is the transport a caller like `forward-spec --reviewer
  codex-pair` wants when there's no tmux.

## Scripts

All bash lives in this skill's `scripts/` directory. It was extracted from
inline blocks so the shared environment logic (absolute `tmux`/`codex`
resolution, the `$TMUX_PANE` fallback, `display-message` arg order, per-window
state paths) lives exactly once in `scripts/lib.sh` — that duplication was the
root cause of the bug class in `TODO.md` #15/#16.

Set `CX` to the scripts path once (this skill's base directory is shown to you
at invocation):

```bash
CX="<this skill's dir>/scripts"    # e.g. ~/.claude/skills/codex-pair/scripts
```

Each step below runs one script and acts on its stdout contract. The scripts
resolve `TMUX_BIN`/`CODEX_BIN`/`REPO_ROOT`/`CC_PANE`/`WINDOW_ID`/`SESSION_DIR`
themselves — you never re-derive them. After editing any script, run
`bash "$CX/tests/run.sh"` (must exit 0).

## First-time setup

If `tmux-bridge-mcp` has never been built and registered, tell the user:

> First-time setup for the Phase 5 transport: run
> `~/.claude/skills/codex-pair/install.sh --dry-run` to preview, then drop
> `--dry-run` to apply. Add `--global` to make it available from any project.
> **Restart Claude Code afterward** so CC picks up the new MCP tools.

Until the user restarts CC with the MCP tools loaded, the skill runs Phase 1
(no error; graceful degrade). The installer is idempotent.

---

> **Exec mode short-circuit:** if CC is **not** inside tmux (`$TMUX` unset),
> skip Steps 0–3B entirely and go straight to **Step 3C** — the `codex exec`
> transport needs no tmux, pane, gate, or bootstrap.
>
> `--exec` **inside** tmux is different: still run Steps 0–0.5 (preflight and
> the gate), then jump from Step 3 to 3C. The gate is what validates and
> persists `--model`/`--effort`, and skipping it was how an unvalidated,
> hand-typed model string reached the API. Only skip the gate when tmux is
> absent and it *cannot* run.

## Step 0 — Preflight

```bash
bash "$CX/preflight.sh"
```

- `MISSING: codex-binary` → stop; relay `npm install -g @openai/codex` + `codex login`.
- `MISSING: tmux-session` → stop; the skill requires CC running inside tmux.
- `OK: … session_dir=<path>` → proceed. Remember `session_dir` as `$SESSION_DIR`.
- `exec_bin=<path>` on the `OK:` line names the codex that supports `codex exec`;
  `exec_bin=none` means **no** codex here has that subcommand, so Step 3C is
  unavailable. The pane transports (3A/3B) are unaffected — they only drive the
  interactive TUI, which every codex major has. If the user forced `--exec` and
  `exec_bin=none`, stop and relay the `NOTE:` lines rather than falling back
  silently: a machine with several codex majors installed needs a human decision,
  not a guess.

## Step 0.5 — Gate (single-flight + flags)

Only one outstanding `/codex-pair` request per window.

```bash
bash "$CX/gate.sh" "<raw args after /codex-pair>"
```

- `RESET: …` → `--reset-pending` handled; stop.
- `HOLD: …` or `UNHEALTHY: …` → surface verbatim; stop.
- `REBOOTSTRAP:` / `STALE_LOCK:` / `STALE_PENDING:` → informational; keep going.
- `GATE: clear` → proceed. The prompt text (flags stripped) is in
  `$SESSION_DIR/skill-args-rest`.

Flags — parsed as leading tokens in **any order and any number** (the rest is
the prompt):

| Flag | Effect |
|---|---|
| `--reset-pending` | clear pending files + lock, then exit |
| `--rebootstrap` | clear bootstrap.json + health.json; force a fresh Phase 5 handshake |
| `--phase1 <prompt>` | force the Phase 1 transport this turn |
| `--exec <prompt>` | force the tmux-free `codex exec` transport (Step 3C) this turn (persisted to `flag-exec`) |
| `--model <name>` | override the model (see below) |
| `--effort <level>` | override the reasoning effort (see below) |

`INVALID_MODEL:` / `INVALID_EFFORT:` → **stop** and relay the message verbatim;
it already names the valid set. No lock was taken and nothing was sent. Never
"fix" the value by guessing — ask the user.

The lock releases on reply-handler success (3A.3), `--reset-pending`, or a
60-min stale TTL.

## Model and effort

**Defaults: `gpt-5.6-sol` at `high` effort.** Both are always passed explicitly
to `codex` — the skill never lets the pane silently inherit `~/.codex/config.toml`,
because then "which model answered me?" has no answer at the call site.

| | Values |
|---|---|
| `--model` | `gpt-5.2` · `gpt-5.4` · `gpt-5.4-mini` · `gpt-5.5` · **`gpt-5.6-sol`** · `gpt-5.6-terra` · `gpt-5.6-luna` |
| `--effort` | `low` · `medium` · **`high`** · `xhigh` · `max` · `ultra` |

```
/codex-pair --model gpt-5.6-sol --effort xhigh  review this diff
/codex-pair --effort max                        why is this test flaky?
```

Both are validated in `lib.sh` (`CX_MODELS` / `CX_EFFORTS`) before they reach
the CLI. That list exists because a wrong string used to sail through to the API
and die there as an opaque `rc=1`. Three things to know:

- **Effort is not a CLI flag.** `codex` has no `--reasoning-effort`; effort only
  reaches it as `-c model_reasoning_effort="<level>"`. Because the skill had no
  effort channel at all, callers smuggled it into the model name
  (`gpt-5.6-sol-high`) — the bug this whole section exists to prevent. Never put
  an effort in a model string.
- **Both are fixed at pane spawn.** On a reused pane the flags are ignored and a
  `WARN` is written that Step 5 surfaces; kill the pane to switch. The `--exec`
  transport has no pane, so there they apply to every call.
- **A new model codex adds will be rejected** by our own list until it's added.
  `CX_ALLOW_UNKNOWN=1` bypasses; the refresh command is in `lib.sh`.

## Step 1 — Attach to or spawn the Codex pane

```bash
bash "$CX/pane.sh"
```

`REUSING: %N` (common path) / `STALE: %N …` (respawned) / `SPAWNED: %N`, then
`CODEX_PANE=%N FRESH_SPAWN=<0|1>` and `MODEL=<m> EFFORT=<e>`. Capture all three;
remember REUSING vs SPAWNED for the Step 5 status line. (Bootstrap in 3A.1 runs
regardless of `FRESH_SPAWN` — it's idempotent.)

`MODEL`/`EFFORT` are what the pane is **actually running** — on a reused pane
that's what it was spawned with, not what this turn asked for. Report them
verbatim in Step 5; don't substitute the requested values.

## Step 2 — Gather the prompt

The prompt is `$SESSION_DIR/skill-args-rest`. If empty, ask via
AskUserQuestion:

- **A)** Review the current diff vs. the base branch → prompt: `"Review the
  changes on this branch against the base branch. Run git diff to see them.
  Flag bugs, edge cases, and anything that looks wrong."`
- **B)** Free-form question (ask what it is).
- **C)** Cancel.

Write the final prompt to `$SESSION_DIR/prompt.txt` — the delivery scripts read
it from a file so multi-line text never has to survive shell quoting.

## Step 3 — Select transport

First: if `$SESSION_DIR/flag-exec` is `1` (the `--exec` flag) → **Step 3C**.
(Not-in-tmux was already routed to 3C by the Step 0 short-circuit.)

Otherwise inspect your loaded tools (or `ToolSearch` for `tmux_message
tmux_read bridge`):

- `mcp__tmux-bridge__tmux_read` / `tmux_message` present → **Step 3A (Phase 5)**.
- absent → **Step 3B (Phase 1)**.

If the user just ran `install.sh` but the tools aren't loaded yet: tell them
Phase 5 needs a CC restart; use 3B this turn.

---

## Step 3A — Phase 5 (MCP push)

### 3A.1 — Bootstrap (every Phase 5 turn; idempotent)

```bash
bash "$CX/bootstrap-check.sh" "$CODEX_PANE"
```

- `SKIP_BOOTSTRAP=1` → jump to 3A.2.
- `SKIP_BOOTSTRAP=0` (optionally with `SKIP_BLOCKED: <reason>`) → run the full
  bootstrap below.

Pick the preamble by whether `~/.codex/AGENTS.md` carries our managed marker
(the static contract is loaded there once by `install.sh`; the shrunk preamble
carries only per-turn bits and saves ~370 tok/cold turn):

```bash
AGENTS_FILE="$HOME/.codex/AGENTS.md"
if [ -f "$AGENTS_FILE" ] && grep -q '<!-- codex-pair:begin' "$AGENTS_FILE"; then
  echo shrunk; else echo legacy; fi
```

Generate an 8-hex `BOOTSTRAP_UUID`. Read the matching preamble file —
`scripts/preamble-shrunk.txt` (marker present) or `scripts/preamble-legacy.txt`
(marker absent; inlines the full contract, ~990 tok/cold turn but works without
`install.sh`) — substitute `<CC_PANE>`, `<BOOTSTRAP_UUID>`, `<SESSION_DIR>`,
`<WINDOW_ID>` throughout, and write the result to
`$SESSION_DIR/bootstrap-preamble.txt`. Then deliver it with a bare bracketed
paste (no sentinels — Codex doesn't know the bridge yet, so `send-p1.sh`'s
sentinel wrapper would be wrong here):

```bash
bash "$CX/paste-raw.sh" "$SESSION_DIR/bootstrap-preamble.txt"
```

Then verify the ACK (polls `bootstrap.json` up to 90s, 4-predicate check):

```bash
bash "$CX/ack-wait.sh" "$BOOTSTRAP_UUID" "$CODEX_PANE"
```

- `BOOTSTRAP_ACKED` → 3A.2.
- `ACK_INVALID: FAIL <reason>` → surface the reason verbatim; fail the turn
  cleanly (user can `--rebootstrap`).
- `BOOTSTRAP_TIMEOUT` → "Codex bootstrap timed out. Open pane `$CODEX_PANE`.
  Retry `/codex-pair --rebootstrap`, or fall back `/codex-pair --phase1
  <prompt>`." Fail the turn.

**Never** silently fall back to Phase 1 mid-turn after sending the preamble —
the `--phase1` opt-in is the correct path.

### 3A.2 — Deliver the prompt

```bash
bash "$CX/pending-write.sh" "$SESSION_DIR/prompt.txt"    # → REQ_ID=<8hex>
```

Build `TAGGED_PROMPT` = `[req:<REQ_ID>] ` + the prompt. Then call the bridge
tools in order, using the raw pane ID (Invariant #5):

1. `tmux_read(target=$CODEX_PANE, lines=5)` — satisfies the read-guard.
2. `tmux_message(target=$CODEX_PANE, text=TAGGED_PROMPT)`.
3. `tmux_read(target=$CODEX_PANE, lines=5)` — verify the text landed.
4. `tmux_keys(target=$CODEX_PANE, keys=["Enter"])` — submit.

**Cleanup invariant:** if any call fails, delete
`$SESSION_DIR/pending/$REQ_ID.json`, `rm -rf "$SESSION_DIR/lock"`, and surface
the error. Otherwise **end the turn**: "Delivered prompt (req-id `$REQ_ID`) to
Codex pane `$CODEX_PANE`. Reply arrives in a new turn — typically 30s–3min."
Never poll for the reply.

### 3A.3 — Handle the pushed reply

The reply arrives as a new user message with a header like
`[tmux-bridge from:codex pane:%N id:…]` plus a `[reply-to:<req-id>]` line.
Extract `from_pane` (the `pane:%N`), `reply_to` (the uuid), and `body` (the
message minus the header and the reply-to line).

```bash
bash "$CX/reply-validate.sh" "<reply_to>" "<from_pane>"
```

`OUTCOME=<…>` (plus `PROMPT_PREVIEW=` on ALL_PASS). Then:

| OUTCOME | Action |
|---|---|
| `ALL_PASS` | Present `body` verbatim (Step 5) as the answer to `PROMPT_PREVIEW`. The script already cleared the pending file and released the lock. |
| `MISSING_TAG` | Show `body`; banner "Codex sent unprompted (no reply-to tag). Showing verbatim." |
| `LATE` | Show `body`; banner "Late reply for already-cleared req `<reply_to>`; not treated as an answer." |
| `PANE_MISMATCH` | Show `body`; banner "Protocol violation: reply pane vs. pending pane mismatch. NOT clearing pending — investigate." |
| `MALFORMED` | Show `body`; banner "Pending file unparseable; run `/codex-pair --reset-pending`." |

Then update the health counter:

```bash
bash "$CX/health-update.sh" "<OUTCOME>"                  # → MISSES=<n>
```

If `MISSES >= 3`, prepend the unhealthy banner before showing the reply (offer
`/codex-pair --phase1 <prompt>` or `--rebootstrap`).

---

## Step 3B — Phase 1 (sentinel pull)

```bash
bash "$CX/send-p1.sh" "$SESSION_DIR/prompt.txt"   # → SENT: UUID=…  /  END_SENTINEL=§cx:…:E§
bash "$CX/poll-extract.sh" "<END_SENTINEL>"       # → response body (or TIMEOUT: …)
```

`poll-extract.sh` waits for **two** END sentinels (my echo + Codex's emission),
extracts the body between them, and prints it. `TIMEOUT: …` → "Codex didn't
respond within 5 min. Check pane `$CODEX_PANE`."

## Step 3C — Exec transport (tmux-free)

No pane, gate, bootstrap, or sentinels — a synchronous `codex exec` call that
captures the reply directly and resumes the session by thread id across turns.
Write the prompt to a file and run:

```bash
bash "$CX/exec.sh" "$SESSION_DIR/prompt.txt"
```

(Outside tmux there is no `$SESSION_DIR`; use any temp file for the prompt.)

**Do not pass `--model`/`--effort` here yourself.** Inside tmux the gate already
validated and persisted them and `exec.sh` reads them; outside tmux the defaults
apply. Typing them in by hand at this call site is exactly what produced the
invalid model string. The flags exist (`exec.sh <file> [--model m] [--effort e]`)
only for a caller with no gate, and they are validated either way.

- Prints the agent's final message on stdout → present it verbatim in Step 5
  with `Transport: codex exec`. `MODEL=… EFFORT=…` goes to stderr — use it for
  the Step 5 status line.
- `EXEC_FAIL: <reason>` → surface the reason; it now carries codex's actual
  error (pulled from the JSONL event stream, where codex puts API errors — not
  stderr). Suggest checking `codex login` if it's an auth failure.
- `INVALID_MODEL:` / `INVALID_EFFORT:` → relay verbatim; nothing was sent.

State lives in `$REPO_ROOT/.context/codex-pair/exec/` (`thread-id`,
`last-message.txt`, `events.jsonl`). The first call starts a Codex session;
later calls resume it by `thread-id`, so continuity works without a live pane.
To start fresh, delete `.context/codex-pair/exec/thread-id`. The optional 2nd
arg sets the model — unlike `--model` on a pane, it applies to every call.

Verified against codex-cli 0.139.0 (2026-07-06): `-o` captures the final
message, the session id is the JSONL top-level `thread_id`, and `resume <id>`
carries prior context.

## Step 4 — Session resume

For the **exec** transport this is implemented — Step 3C resumes by `thread-id`.
For the **pane** transports it remains a stub: the pane itself persists across
CC restarts via `$SESSION_DIR/pane-id`, which reduces the need for
`codex exec resume` there. Tracked in `TODO.md`.

## Step 5 — Present the response

Show the captured response verbatim in a delimited block:

```
CODEX SAYS:
════════════════════════════════════════════════════════════
<RESPONSE — verbatim, including Codex's `•` marker if present>
════════════════════════════════════════════════════════════
Pane: <CODEX_PANE> (<REUSING|SPAWNED>)
Model: <MODEL> @ <EFFORT> effort
Transport: <Phase 5 MCP push | Phase 1 sentinel pull | codex exec>
<contents of $SESSION_DIR/model-warning, if it exists>
```

`Model:` is non-negotiable — a second opinion is worth nothing if the reader
can't tell which model gave it. Use the `MODEL=`/`EFFORT=` values Step 1 (pane)
or Step 3C (exec, on stderr) reported. On the exec transport there is no pane,
so drop the `Pane:` line.

If `$SESSION_DIR/model-warning` exists, append its contents verbatim as a line
inside the block (this is how the `--model` reuse-path warning reaches the
user; the gate clears it next turn). You may add your own synthesis as a
separate paragraph **after** the block — never edit Codex's words inside it.

---

## Error handling

- `MISSING: codex-binary` / `MISSING: tmux-session` → see Step 0.
- `STALE: <pane>` → already handled by respawn; note "Codex pane was gone;
  started fresh."
- `TIMEOUT:` (Phase 1) → Codex wedged, didn't echo the sentinel, or is awaiting
  approval; point the user at pane `$CODEX_PANE`.
- MCP call fails (Phase 5) → run `tmux_doctor()`; **fail the turn cleanly**
  (transport is selected once per turn); suggest `/codex-pair --phase1`.
- Phase 5 reply never arrives → Codex may have ignored the contract or is on an
  approval modal; open the pane and check.

## Bridge usage contract (Phase 5 reference)

1. **Read before act** — `tmux_read` before `tmux_type`/`tmux_message`/`tmux_keys`.
2. **Read-Act-Read** — read, act, read again, then send Enter.
3. **Never poll** — the peer pushes its reply into your pane.
4. **Label panes at spawn** — cosmetic only.

| Tool | Purpose |
|------|---------|
| `tmux_read(target, lines)` | read last N lines; satisfies the read-guard |
| `tmux_message(target, text)` | type with sender-ID prefix |
| `tmux_keys(target, [keys])` | send special keys (e.g. Enter) |
| `tmux_id()` / `tmux_doctor()` | own pane id / connectivity diagnostics |
| `tmux_name` / `tmux_resolve` | label a pane / resolve a label |

## Invariants

1. **Only this skill's scripts modify `$SESSION_DIR/`** (`pane-id`,
   `bootstrap.json`, `pending/`, `lock/`, `health.json`, `flag-*`,
   `prompt.txt`). Manual changes only via `--reset-pending` / `--rebootstrap`.
2. **Never kill the Codex pane from the skill** — only the user closes it;
   respawn handles a gone pane.
3. **Env resolution lives once in `scripts/lib.sh`** — absolute
   `TMUX_BIN`/`CODEX_BIN`, the `$TMUX_PANE` fallback (old Invariant #9), the
   `display-message -t`-before-format order (old #10), and per-window
   `REPO_ROOT`/`WINDOW_ID` scoping. Never re-inline it into a step.
4. **State anchors to `$REPO_ROOT/.context/codex-pair/$WINDOW_ID/`** —
   per-window scoping prevents two sessions in different tmux windows of the
   same repo from stomping each other.
5. **Routing uses pane IDs (`%N`), not labels.** Labels (`tmux_name`) are
   cosmetic; the bridge header always carries `pane:%N`.
6. **Phase 1 multi-line delivery uses bracketed paste** (in `send-p1.sh`) —
   `send-keys -l` would submit each line as a separate Enter.
7. **Phase 5 never polls** — CC's turn ends after delivery; Codex pushes back.
8. **5-minute ceiling on the Phase 1 poll** (in `poll-extract.sh`) — a wedged
   Codex fails cleanly, not hangs CC.
9. **Model/effort policy lives once in `lib.sh`** (`CX_DEFAULT_MODEL`,
   `CX_DEFAULT_EFFORT`, `CX_MODELS`, `CX_EFFORTS`, `cx_validate`,
   `cx_effort_conf`) and **no value reaches `codex` unvalidated.** Never inline
   a model string, an effort, or a `model_reasoning_effort=` config into a step
   or a script — that duplication is how `gpt-5.6-sol-high` was born.

## What this skill does NOT do (yet)

- **`codex exec resume` for the pane transports** on dead-pane respawn — the
  exec transport (3C) resumes by thread id, but the pane transports don't.
- **Readiness probe** after spawn — blind `sleep 4` in `pane.sh`.
- **Kernel-level serialization** — single-flight is policy-enforced by the gate
  lock, not an OS lock across CC processes.
- **Graceful handoff when CC is mid-turn** during a Phase 5 push.
- **Auth-error detection** in the Codex pane.

See `TODO.md` for the full open-issues list with severity and line references.

## Harness assumptions

Verified against Claude Code as of 2026-07-06. This skill assumes:
- The `codex` CLI is on PATH (always).
- The pane transports (Phase 1/5) require CC to run inside a tmux pane with `tmux` on PATH; Phase 5 additionally needs the `tmux-bridge` MCP tools loaded (see First-time setup).
- The `--exec` transport (Step 3C) needs neither tmux nor the bridge — just `codex`.

If a listed tool name or behavior no longer matches the live harness, fix this skill before trusting it.
