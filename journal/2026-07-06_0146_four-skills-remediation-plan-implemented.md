# Four-skills remediation plan — implemented end to end

**Run date:** 2026-07-06
**Scope:** `~/.claude/skills/` repo — `audit-trail`, `codex-pair`, `forward-spec`, `adversarial`
**Driver:** a `/loop` (dynamic mode) that worked the remediation list one item at a time.
**Model:** Opus 4.8 (plan was authored earlier by Fable 5 via `forward-spec`).

## What this run set out to do

Implement the remediation plan at
`~/.claude/docs/research/skills-remediation-plan.md` — 15 substantive items in
three rollout tiers across the four skills. The plan came out of an audit that
found: codex-pair's 1,411-line SKILL.md (inline bash, duplicated boilerplate,
a bug class fixed 9× in prose); the adversarial skill still a "debate format"
while an excellent unapplied critique (`gpt54crit.md`) sat next to it;
forward-spec referencing a renamed tool (`Task`) and an undefined variable; and
audit-trail missing a post-compaction evidence rule.

## What actually changed (8 commits, `402424f`..`6d489a1`)

- **Tier 1 (`402424f`)** — 8 text-only fixes. audit-trail: post-compaction
  verify-against-filesystem rule, preset/flag precedence, HTML diagram → scratchpad
  default. forward-spec: `Task`→`Agent`, own `FS_STATE_DIR` (was codex-pair's
  internal `$SESSION_DIR`). codex-pair: install.sh header now matches the
  `claude mcp add` reality (post the I-6 fix), TODO dup-id. Harness-assumptions
  footer on all four (makes the next drift audit mechanical).

- **T2-A1 (`3d9e2aa`)** — adversarial rewritten from debate → dispute-resolution
  format, folding in all of `gpt54crit.md`: dispute ledger, procedural
  stop/re-open rules (convergence is now a rule, not a vibe), burden-of-proof
  labels, four-bucket significance filter, Phase-4 targeted rebuttal (kills
  last-speaker bias), steelman pass, dual calibration (process convergence vs.
  domain reliability), five-category synthesis. 157→329 lines. Rationale + what
  was deliberately deferred recorded in DESIGN.md (gitignored).

- **T2-F1/F2/F3 (`46ad57f`)** — forward-spec: resume/hand-back convention for
  review rounds (marker + state.json lookup); vendored the gold-standard
  exemplar into `references/` (removes hard coupling to a file inside
  codex-pair); added `--reviewer adversarial` (tmux-free in-session pressure
  test) with a five-category→GO/NO-GO mapping. `--review` now works without
  tmux/codex.

- **T2-C1 (`5b90144` Phase A, `f9437a8` Phase B)** — the big one. Extracted
  codex-pair's ~10 inline bash blocks into `scripts/` (12 scripts + `lib.sh` +
  2 preamble `.txt` files + a `paste-raw.sh` helper). SKILL.md **1,411 → 351
  lines**. lib.sh centralizes the env logic (Invariants #9/#10, portability)
  that previously drifted across blocks — the #15/#16 bug class is now
  structurally impossible. gate.sh got a loop-based multi-flag parser (fixes
  A4). Portability fixed (A3): `command -v tmux` not hardcoded homebrew,
  portable `mtime_s`. `scripts/tests/run.sh` = 40+ unit assertions with a
  stubbed tmux (flag parser, lock/pending TTL, five reply outcomes, health
  counter, bootstrap predicates). Two-phase so each commit is non-breaking
  (Phase A dormant scripts, Phase B flips SKILL.md to them).

- **T3-A2 (`6bbcbd2`)** — adversarial: a runnable Workflow-mode ledger loop
  (the stop/re-open rules as literal `while` predicates). `node --check`
  verified in an async wrapper matching the harness.

- **T3-C1 (`6d489a1`)** — codex-pair: a third, tmux-free `codex exec` transport
  (`exec.sh`, `--exec` flag, Step 3C). **Live-verified** against codex-cli
  0.139.0: `-o` captures the final message; session id is the JSONL top-level
  `thread_id`; `exec resume <id>` carries context (two-call recall test). Removes
  the hard tmux requirement so `forward-spec --reviewer codex-pair` works with
  no pane.

## How it fits / alters the architecture

The four skills form a coherent quadrant — backward (audit-trail), forward
(forward-spec), pressure-test (adversarial), external reviewer (codex-pair).
This run wired the one missing edge (`forward-spec --reviewer adversarial`) and
made codex-pair usable outside tmux (exec transport), so the review loop no
longer hard-depends on a pane. codex-pair's SKILL.md is now a thin orchestration
doc over a tested `scripts/` library — the model no longer re-transcribes bash
(and its bugs) every invocation.

## Current state

- **All 15 substantive items done** (T1-9 intentionally skipped — superseded by
  T2-C1's gate rewrite). Working tree clean; every commit verified before
  landing (acceptance greps, `scripts/tests/run.sh` green, `node --check`,
  `install.sh` syntax, live codex round-trips).
- Checklist with per-item commit hashes lives in the plan doc's `## Progress`
  section.

## Open risks / what's next

- **codex-pair pane transports (Phase 1/5) were NOT live-smoke-tested** — the
  unit tests stub tmux; the exec transport was the only one exercised live. A
  real pane round-trip in a tmux+bridge environment is still owed (TODO.md).
- **`datetime.utcnow()` deprecation** carried over faithfully into 3 scripts
  (stderr warning, not a regression) — TODO'd for a naive-UTC-preserving swap.
- **exec thread-id parser** keys on `thread_id`; a codex-cli field rename would
  silently drop resume continuity (safe degrade). TODO'd.
- **37 unrelated untracked skills** in the repo were left as-is (I asked; the
  user was away — chose not to sweep WIP into a commit). The four target skills
  were already tracked, so rollback safety was never at risk.
- `~/.claude/skills` is a git repo but `~/.claude` itself is not; DESIGN.md and
  gpt54crit.md are intentionally gitignored, so the adversarial rationale note
  is not committed (by design).
