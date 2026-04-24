# codex-pair — Known Issues / TODO

Catalogued from a Codex self-review on 2026-04-24 (the skill was used to
review its own `SKILL.md`). Findings recorded verbatim in severity order;
status column tracks what's landed vs. open.

| # | Severity | Summary | Status |
|---|---|---|---|
| 1 | CRITICAL | Poll breaks on the first END (prompt echo), not the second (Codex's emission) — extractor then fails | **FIXED** — poll now requires `-ge 2` END occurrences |
| 2 | HIGH | No serialization on the shared long-lived pane — concurrent `/codex-pair` invocations race | OPEN — needs flock or busy-marker |
| 3 | HIGH | Reuse validation checks "pane exists" but not "this is still Codex and it's idle" | OPEN — add pane-command probe + idle check |
| 4 | HIGH | `set -u` instead of `set -euo pipefail`; most tmux return values not checked | OPEN — bash-wide pass |
| 5 | HIGH | Cold-start `codex exec resume` documented in Step 4 but never implemented | OPEN — either wire it up or remove the claim |
| 6 | HIGH | Invariants say absolute `tmux` path, but every snippet uses bare `tmux`/`codex` | OPEN — `$TMUX_BIN` / `$CODEX_BIN` everywhere |
| 7 | HIGH | `.context/` paths are cwd-relative; subdirectory invocation fragments state | OPEN — resolve via `git rev-parse --show-toplevel` once |
| 8 | MEDIUM | Extraction window is 5000 lines; long Codex runs can scroll the first marker out of range | OPEN — larger window, or pivot to file-based handoff |
| 9 | MEDIUM | Spawn uses blind `sleep 4` instead of a readiness probe | OPEN — probe for TUI prompt glyph |
| 10 | MEDIUM | Error-handling section overpromises auth-error detection the steps never perform | OPEN — either implement or trim docs |
| 11 | MEDIUM | Auto-edit of `.gitignore` during consult dirties the worktree without consent | OPEN — make opt-in or move state out of repo |
| 12 | MEDIUM | Phase 5 push model assumes CC is idle; injected text can collide with mid-turn CC | OPEN — needs handoff/mailbox design thinking |
| 13 | LOW | Phase 5 bootstrap hardcodes `/Users/ryoung/...` bridge path | OPEN — resolve dynamically from skill dir |
| 14 | LOW | Setup story contradicts itself (Phase 1 says no MCP needed; first-time setup says install bridge) | OPEN — reword first-time setup to be Phase-5-only |
| 5b | — | Sentinel token too long — wraps in narrow Codex panes, defeating `grep -F` | **FIXED** — sentinel is now `§cx:<8hex>:E§` (≤20 chars) |

## Design shifts that obsolete some of these

Most of 1, 5, 8 disappear when Phase 5 (MCP push model) lights up — Codex
delivers responses via `tmux_message` directly into CC's pane, so no
sentinel extraction, no scrollback polling, no session-resume gymnastics.
Prioritize fixing the OPEN items that *aren't* made irrelevant by Phase 5:
**2 (serialization), 3 (readiness), 6 (absolute paths), 7 (cwd
invariance), 11 (.gitignore), 12 (push race)**.

## Not a finding, worth noting

Codex's own assumption at the end of the review: "I'm assuming this skill
can be invoked from arbitrary cwd and overlapping invocations are
possible. If the host guarantees repo-root execution and single-flight
invocation, items 2 and 7 drop in severity."

In CC, `/codex-pair` is invoked at whatever cwd CC is running from (not
guaranteed repo root), and CC doesn't serialize skill invocations. So
Codex's worst-case assumption matches reality; items 2 and 7 stay HIGH.
