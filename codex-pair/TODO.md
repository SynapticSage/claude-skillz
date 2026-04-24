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
| 13 | LOW | Phase 5 bootstrap hardcodes `/Users/ryoung/...` bridge path | **FIXED** — bootstrap preamble now references `~/.claude/skills/codex-pair/vendor/...` |
| 14 | LOW | Setup story contradicts itself (Phase 1 says no MCP needed; first-time setup says install bridge) | **FIXED** — First-time setup now explicitly scoped to Phase 5 transport; Phase 1 works without the bridge |
| 5b | — | Sentinel token too long — wraps in narrow Codex panes, defeating `grep -F` | **FIXED** — sentinel is now `§cx:<8hex>:E§` (≤20 chars) |

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

## Still true: Codex's assumption from the review

"I'm assuming this skill can be invoked from arbitrary cwd and
overlapping invocations are possible. If the host guarantees repo-root
execution and single-flight invocation, items 2 and 7 drop in severity."

Item 7 is now fixed (cwd-invariant via `$REPO_ROOT`). Item 2
(concurrent-invocation serialization) is still open — CC does not
serialize skill invocations.
