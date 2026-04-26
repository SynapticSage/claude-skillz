# codex-pair — Known Issues / TODO

Catalogued from a Codex self-review on 2026-04-24 (the skill was used to
review its own `SKILL.md`). Status tracks what's landed vs. open after
subsequent Phase-5 dev work.

| # | Severity | Summary | Status |
|---|---|---|---|
| 1 | CRITICAL | Poll breaks on the first END (prompt echo), not the second (Codex's emission) — extractor then fails | **FIXED** — poll now requires `-ge 2` END occurrences |
| 2 | HIGH | No serialization on the shared long-lived pane — concurrent `/codex-pair` invocations race | OPEN — needs flock or busy-marker |
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
| 14 | HIGH | `tmux display-message -p '#{window_id}' -t "$TMUX_PANE"` arg order is wrong: `-t` after the format is parsed as a positional argument, erroring with "too many arguments". Affected ~9 bash blocks; failure was masked because errors in `$(...)` inside `set -euo pipefail` left `WINDOW_ID=""`, which then cascaded into wrong `SESSION_DIR` paths. Discovered live during /codex-pair test, 2026-04-26. | **FIXED** — every block now uses `display-message -p -t "$CC_PANE" '#{window_id}'` with the flag before the format. Documented as Invariant #10 |
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

## Still true: Codex's assumption from the review

"I'm assuming this skill can be invoked from arbitrary cwd and
overlapping invocations are possible. If the host guarantees repo-root
execution and single-flight invocation, items 2 and 7 drop in severity."

Item 7 is now fixed (cwd-invariant via `$REPO_ROOT`). Item 2
(concurrent-invocation serialization) is still open — CC does not
serialize skill invocations.
