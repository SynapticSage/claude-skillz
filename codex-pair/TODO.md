# codex-pair — Known Issues / TODO

Catalogued from a Codex self-review on 2026-04-24 (the skill was used to
review its own `SKILL.md`). Status tracks what's landed vs. open after
subsequent Phase-5 dev work.

| # | Severity | Summary | Status |
|---|---|---|---|
| 1 | CRITICAL | Poll breaks on the first END (prompt echo), not the second (Codex's emission) — extractor then fails | **FIXED** — poll now requires `-ge 2` END occurrences |
| 2 | HIGH | No serialization on the shared long-lived pane — concurrent `/codex-pair` invocations race | **PARTIAL** — Step 0.5 gate (`scripts/gate.sh`) provides per-window single-flight via an atomic `mkdir` lock with a 60-min stale TTL. Concurrent invocations in a window now serialize (HOLD) instead of racing. Not a cross-process kernel lock across unrelated CC processes; that remains open |
| 3 | HIGH | Reuse validation checks "pane exists" but not "this is still Codex and it's idle" | OPEN — add pane-command probe + idle check |
| 4 | HIGH | `set -u` instead of `set -euo pipefail`; most tmux return values not checked | **FIXED** — all bash blocks now use `set -euo pipefail` |
| 5 | HIGH | Cold-start `codex exec resume` documented but never implemented | OPEN — Step 4 is now explicitly marked a stub; Phase 5 push model reduces urgency |
| 6 | HIGH | Invariants say absolute `tmux` path, but every snippet uses bare `tmux`/`codex` | **FIXED** — snippets use `$TMUX_BIN` / `$CODEX_BIN` resolved at the top of each block |
| 7 | HIGH | `.context/` paths are cwd-relative; subdirectory invocation fragments state | **FIXED** — `$REPO_ROOT` resolved from `git rev-parse --show-toplevel` (falls back to `pwd`); all state anchored to it |
| 8 | MEDIUM | Extraction window is 5000 lines; long Codex runs can scroll the first marker out of range | OPEN — larger window, or Phase 5 obsoletes this entirely |
| 9 | MEDIUM | Spawn uses blind `sleep 4` instead of a readiness probe | OPEN — probe for TUI prompt glyph |
| 10 | MEDIUM | Error-handling section overpromises auth-error detection the steps never perform | PARTIAL — docs trimmed; auth-error probe still unimplemented |
| 11 | MEDIUM | Auto-edit of `.gitignore` during consult dirties the worktree without consent | **PARTIAL** — now only edits when we're in a git repo AND a `.gitignore` already exists (doesn't create one). Still auto-edits without opt-in flag |
| 12 | MEDIUM | Phase 5 push model assumes CC is idle; injected text can collide with mid-turn CC | OPEN — needs handoff/mailbox design thinking |
| 13 | LOW | Phase 5 bootstrap hardcodes `/Users/ryoung/...` bridge path | **PARTIAL** — machine-specific path removed; still hardcodes vendor/ layout while install.sh supports three (vendor/, dev-layout/, --bridge-path). Codex Part A flagged that prior "FIXED" status was overstated |
| 14 | LOW | Setup story contradicts itself (Phase 1 says no MCP needed; first-time setup says install bridge) | **FIXED** — First-time setup now explicitly scoped to Phase 5 transport; Phase 1 works without the bridge |
| 5b | — | Sentinel token too long — wraps in narrow Codex panes, defeating `grep -F` | **FIXED** — sentinel is now `§cx:<8hex>:E§` (≤20 chars) |
| 16 | HIGH | `tmux display-message -p '#{window_id}' -t "$TMUX_PANE"` arg order is wrong: `-t` after the format is parsed as a positional argument, erroring with "too many arguments". Affected ~9 bash blocks; failure was masked because errors in `$(...)` inside `set -euo pipefail` left `WINDOW_ID=""`, which then cascaded into wrong `SESSION_DIR` paths. Discovered live during /codex-pair test, 2026-04-26. | **FIXED** — every block now uses `display-message -p -t "$CC_PANE" '#{window_id}'` with the flag before the format. Documented as Invariant #10 |
| 15 | HIGH | Bare `$TMUX_PANE` is unreliable: tmux only exports it to processes spawned directly into a pane, and CC's bash subshells inherit it inconsistently. When empty, the buggy `display-message -t ""` errored silently and the skill cascaded. Discovered live, 2026-04-26. | **FIXED** — every block now resolves `CC_PANE="${TMUX_PANE:-$($TMUX_BIN display-message -p '#{pane_id}')}"` and uses `$CC_PANE` everywhere (incl. the `cc_pane` field of pending-request JSON). Documented as Invariant #9 |

## Phase 5 additions landed in this iteration

- **Transport selection** at the top of Step 3 — detects MCP tool
  availability and branches to Phase 5 (3A) or Phase 1 (3B).
- **First-spawn bootstrap preamble** (Step 3A.1) — types the bridge
  contract + pane-ID handshake into Codex via bracketed paste so Codex
  knows how to use the MCP tools.
- **MCP push-model workflow** (Step 3A.2) — `tmux_list` →
  `tmux_read(codex)` → `tmux_message(codex, prompt)` → `tmux_read(codex)` →
  `tmux_keys(codex, [Enter])` → end CC's turn.
- **Pushed-reply handler** (Step 3A.3) — strips `[tmux-bridge from:...]`
  sender prefix and presents the payload verbatim.

## Install.sh fixes landed in this iteration

- **`applyDefaults()` neuter regex was broken** — `[^)]*` in
  `.catch([^)]*)` couldn't span the `() => {}` arg. The neuter had never
  actually landed in `src/index.ts` even though the script reported
  success. Regex changed to `[^\n]*;` which matches any non-newline up
  to the terminating semicolon. Self-healing now works.
- **`BRIDGE_PATH` default** — the old `$SCRIPT_DIR/../../../repos/…`
  default was wrong after the skill moved to `~/.claude/skills/`. Now
  tries `$SCRIPT_DIR/vendor/tmux-bridge-mcp` first, falls back to the
  dev-layout path, and if neither exists auto-clones into the vendor
  location (portable across machines).

## Design shifts that obsolete some of these

Most of 1, 5, 8 disappear when Phase 5 (MCP push model) is active — Codex
delivers responses via `tmux_message` directly into CC's pane, so no
sentinel extraction, no scrollback polling, no session-resume gymnastics.
Prioritize fixing the OPEN items that *aren't* made irrelevant by Phase 5:
**2 (serialization), 3 (readiness), 9 (readiness sleep), 12 (push
race)**.

## Phase 5 review findings (Codex, 2026-04-24, second pass)

Codex was asked to verify the iteration-2 fixes and find new Phase-5
issues. Fifteen total findings; status below.

### New Phase 5 issues (SKILL.md)

| # | Severity | Summary | Status |
|---|---|---|---|
| P5-1 | HIGH | Transport selection keys off exact tool names via ToolSearch; namespace drift (`tmux-bridge` vs `tmux_bridge`) misroutes | OPEN — needs more tolerant detection |
| P5-2 | HIGH | Reused Codex pane can predate Codex's own MCP-load restart; skill takes Phase 5 path, skips bootstrap because `FRESH_SPAWN=0`, Codex then has no tools to reply with | **FIXED** (commit 1/4) — bootstrap now runs on every Phase 5 invocation; preamble is idempotent |
| P5-3 | HIGH | Bootstrap success assumed, not verified | **FIXED** (commit 3/4) — file-based ACK with 4-predicate validation: `bootstrap_id` matches sent UUID, `codex_pane_id` from `tmux_id()` matches spawned pane, `doctor_status` from `tmux_doctor()` contains `Status: OK`, `ts` parses as fresh ISO 8601. Atomic temp-file + rename prevents partial-read race. Failure modes split between ACK_INVALID (specific reason) and BOOTSTRAP_TIMEOUT |
| P5-4 | HIGH | Reply handling discards correlation; concurrent asks misattribute | **FIXED** (commit 2/4) — req-id round-tripping with `[req:<uuid>]` / `[reply-to:<uuid>]` tags; three-predicate validation (tag present, pending file exists, pane:%N matches stored codex_pane); health tracking with consecutive-misses counter. Pending state stored as `pending/<req-id>.json`, single-flight enforced as policy by Step 0.5 gate |
| P5-5 | MEDIUM | Labels global; multiple pair sessions cross-wire | **FIXED** (commits 1+4) — routing now uses pane IDs (`%N`), not labels. Labels are still set via `tmux_name` (commit 4 in 3A.1) but only for the human-visible tmux border, scoped as `codex-<WINDOW_ID>` / `claude-<WINDOW_ID>`. Cross-wiring impossible because labels aren't load-bearing |

### New install.sh issues

| # | Severity | Summary | Status |
|---|---|---|---|
| I-1 | HIGH | Non-global CC registration writes to the wrong settings file. `SCRIPT_DIR/../../..` from the installed-skill location resolves to `$HOME`, so "project-local" = `$HOME/.claude/settings.local.json`, not the caller's actual project | **FIXED** — `PROJECT_ROOT` now resolved from `git rev-parse --show-toplevel` of the user's cwd, falling back to `pwd` |
| I-2 | MEDIUM | `--dry-run --skip-build` emits false "MCP won't start" warning for a file that was intentionally not built | **FIXED** — warning now only fires when `DRY_RUN=0` |
| I-3 | MEDIUM | `applyDefaults()` regex still format-fragile (single-line, semicolon-terminated). Multi-line upstream reformat would silently disable self-heal | OPEN — lower priority; upstream bridge is unlikely to reformat |
| I-4 | LOW | Auto-clone suppressed git's stderr; bare "CLONE FAILED" gave no actionable diagnosis | **FIXED** — stderr now flows through; user sees the actual git error |
| I-5 | HIGH | Codex registration regex `[mcp_servers\.tmux-bridge\][^\[]*` terminates inside the section at the `[` of `args = ["..."]`, so re-runs replace only the prefix and leave the array literal as orphan `["..."]` lines on subsequent rows. After several re-runs `~/.codex/config.toml` becomes invalid TOML and Codex silently fails to load the bridge. Same bug class as the earlier `applyDefaults` regex (`[^)]*`). Discovered empirically 2026-04-26 during first end-to-end install on this machine. | **FIXED** — both registration (line 422) and uninstall (line 169–171) regexes now use line-anchored boundary `^\[[A-Za-z_]` (real TOML section headers begin with letter/underscore after `[`, never with `"`), with `re.MULTILINE \| re.DOTALL`. Verified via re-run: "(already registered, unchanged)" with zero file mutation |
| I-6 | CRITICAL | CC registration wrote `mcpServers.tmux-bridge` into `<project>/.claude/settings.local.json` (or `~/.claude/settings.json` for `--global`). **CC silently ignores `mcpServers` in those files** — they're for permissions and hooks only. CC's actual MCP registry is `~/.claude.json`, managed via the `claude mcp add/get/remove` CLI. Result: every prior "successful" install never actually registered the MCP server. Phase 5 was untestable, every CC restart left the bridge unloaded, and the only reason Phase 1 worked is that it doesn't use MCP. Discovered empirically 2026-04-26 after the user restarted CC and `claude mcp list` still showed no tmux-bridge. | **FIXED** — install.sh now uses `claude mcp add -s {local\|user} tmux-bridge node $BRIDGE_ENTRY` with idempotency check via `claude mcp get` (parses `Command:`/`Args:` lines). Uninstall switched to `claude mcp remove`. Stale entries cleaned from both `settings.local.json` and `~/.claude/settings.json`. Verified registration with `claude mcp list` showing `tmux-bridge: … ✓ Connected` |

## Still true: Codex's assumption from the review

"I'm assuming this skill can be invoked from arbitrary cwd and
overlapping invocations are possible. If the host guarantees repo-root
execution and single-flight invocation, items 2 and 7 drop in severity."

Item 7 is now fixed (cwd-invariant via `$REPO_ROOT`). Item 2
(concurrent-invocation serialization) is still open — CC does not
serialize skill invocations.

## Bridge upstream fixes — patch-on-install path

Discovered live during Phase 5 testing on 2026-04-26. Two bugs in
`tmux-bridge-mcp` that surface when the bridge is spawned by an MCP
client that doesn't propagate `$TMUX_PANE` (Codex CLI's MCP launcher,
and any other launcher with a clean subprocess env):

| Tag | Severity | Summary | Status |
|---|---|---|---|
| Bridge-A | HIGH | `tmux_id()` throws `"Not running inside a tmux pane ($TMUX_PANE is unset)"` instead of recovering | **FIXED-LOCALLY** via `patches/0001-fix-self-context.patch` (parent-process-tree env walk + `tmux list-panes` PID match). Upstream PR open: [howardpen9/tmux-bridge-mcp#2](https://github.com/howardpen9/tmux-bridge-mcp/pull/2) |
| Bridge-B | HIGH | `tmux_message()` emits headers like `[tmux-bridge from:unknown pane:unknown id:<8hex>]` because of the same env-unset failure | **FIXED-LOCALLY** by the same patch — `message()` resolves `getSelfContext()` once at the top and uses recovered context for the `from:`/`pane:` header. Upstream PR open: [#2](https://github.com/howardpen9/tmux-bridge-mcp/pull/2) |
| skill-16 | MEDIUM | `BRIDGE_NO_TMUX_PANE` soft-pass carve-out in Step 3A.3.b/c (added 2026-04-26 as a skill-side workaround for Bridge-B's "unknown" header) | OPEN — keep until upstream PR #2 merges and we re-vendor; then this carve-out should be deleted entirely (Codex round-2 review concurred) |

### Patch-on-install distribution: cleanup triggers

The current path applies `patches/0001-fix-self-context.patch` to a
fresh `tmux-bridge-mcp` clone during `install.sh`. This is **kludgy
on purpose** — a deliberate hotfix path until upstream lands. Trigger
conditions to revisit:

1. **Upstream PR merges** (or maintainer indicates merge timeline)
   → delete `patches/0001-fix-self-context.patch`, drop the `patch -p1`
   block from `install.sh`, replace with a one-line comment naming
   the upstream version that absorbs the fix. Bump the auto-clone
   ref to that tag/commit so re-installs pull the fixed code directly.
2. **Patch hunk fails to apply** (upstream rebased / edited the
   touched region underneath us) → install.sh exits loud. Regenerate
   the patch from the fork's `fix-self-context` branch against new
   upstream HEAD with `git format-patch -1 HEAD --stdout -- src/
   package.json` and commit the refreshed artifact.
3. **Second unrelated patch accumulates** → don't keep stacking
   format-patches. Pivot to a fork-pinned `BRIDGE_REPO` (install.sh
   clones `SynapticSage/tmux-bridge-mcp` instead of upstream) or a
   git submodule. Carrying two patches is the inflection point where
   the kludge stops being cheaper than a clean fork.
4. **Upstream goes silent >4 weeks after PR opens** → same pivot as
   (3). At that point we're effectively running our own bridge; we
   should own the distribution path explicitly, not pretend we're
   just patching upstream's.

User note (2026-05-02): "very kludgy to apply this patch, but I'm
okay with doing that for now. We should take a note that later we
should clean this up and perhaps be more professional about our
release path for this feature." Logging that here so the next pass
through this skill remembers the trigger conditions.

## Script extraction (2026-07-06, T2-C1)

The ~10 inline bash blocks in `SKILL.md` were extracted into `scripts/`
(shared env logic in `scripts/lib.sh`), shrinking `SKILL.md` from 1,411
to 351 lines and centralizing the Invariant #9/#10/portability logic that
previously had to be fixed in every block (the #15/#16 bug class).

- Scripts: `preflight`, `gate`, `pane`, `bootstrap-check`, `ack-wait`,
  `pending-write`, `reply-validate`, `health-update`, `send-p1`,
  `poll-extract`, `paste-raw` + `lib.sh`. Each preserves its original
  stdout contract. Two Codex-facing preambles moved to
  `preamble-shrunk.txt` / `preamble-legacy.txt`.
- Tests: `scripts/tests/run.sh` (bash -n, optional shellcheck, 40+ unit
  assertions with a stubbed tmux). Run it after any script edit.
- A3 (hardcoded `/opt/homebrew` tmux, BSD-only `stat -f %m`) fixed in
  `lib.sh` (`command -v` + portable `mtime_s`). A4 (single-flag parser)
  fixed in `gate.sh` (loop-based, multi-flag). `poll-extract.sh` got a
  `|| true` on its count-grep to avoid a latent `set -e` abort on zero
  matches.

### Follow-ups from the extraction

| Sev | Item | Note |
|---|---|---|
| LOW | `datetime.datetime.utcnow()` in `bootstrap-check.sh` / `ack-wait.sh` / `health-update.sh` is deprecated (Py 3.12+) and emits a stderr DeprecationWarning | Carried over faithfully from the inline code — NOT a regression. Replace with `datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)` (stays naive-UTC, so the `strptime` comparisons keep working) when convenient |
| — | **Phase 1 pane transport: LIVE-VERIFIED PASS 2026-07-08** | Full round-trip through the extracted scripts (preflight → gate → pane spawn → bracketed-paste delivery → 2-sentinel poll/extract) confirmed against the real codex TUI: prompt "what is 2+2" → extracted "4" with the completion sentinel emitted. The extraction is sound. |
| LOW | **Phase 5 pane transport still un-live-tested** | The `tmux-bridge` MCP tools weren't loaded in the test session, so the MCP push path (3A) couldn't be exercised end to end. Run once in a session with the bridge loaded. |
| MEDIUM | **No transport verifies the resolved `codex` supports the subcommand it needs** | Surfaced live 2026-07-08: this machine has a codex version split — `command -v codex` → `/usr/local/bin/codex` is the old 0.1.x research-preview TUI (interactive only, **no `exec`**), while the newer `@openai/codex@0.143.0` (which has `exec`) is the Homebrew npm install. So the **pane** transports work (old TUI codex), but the **exec** transport (T3-C1) would fail here because `exec.sh` calls the PATH-default codex, which lacks `exec`. Fix options: probe `codex exec --help` in preflight and pick a codex that supports it, or let the user pin `CODEX_BIN`. (T3-C1 exec was originally verified 2026-07-06 against codex 0.139.0, before this machine's install drifted.) |

## Exec transport (2026-07-06, T3-C1)

Added a third, tmux-free transport (`scripts/exec.sh`, `--exec` flag, SKILL.md
Step 3C) built on `codex exec`. Removes the hard tmux requirement — a caller
like `forward-spec --reviewer codex-pair` can now get a Codex reply with no
pane. **Live-verified** against codex-cli 0.139.0: `-o` captures the final
message; the session id is the JSONL top-level `thread_id`; `codex exec resume
<thread_id>` carries prior context (confirmed with a two-call recall test);
`exec.sh` round-trips end to end. Selected automatically when not in tmux, or
forced with `--exec`. State in `.context/codex-pair/exec/`.

Open: the thread-id parser keys on `thread_id` — if a future codex-cli renames
that JSONL field, resume silently starts fresh (safe degrade, but continuity
breaks until the parser is updated).
