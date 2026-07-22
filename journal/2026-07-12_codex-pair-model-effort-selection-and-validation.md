# codex-pair: model/effort selection + the invalid-model-string fix

**Run goal.** Make `/codex-pair` default to `gpt-5.6-sol` at `high` effort, give it
real model/effort selection, and fix the invalid model string a prior call produced.

## What was actually wrong

Not a typo — a design hole with three compounding parts:

1. **`codex` exposes no effort flag.** Reasoning effort reaches it *only* as
   `-c model_reasoning_effort="<level>"`. The skill never modeled this, so there
   was **no channel for effort at all**.
2. **The model string was never validated.** `gate.sh --model` took free text and
   passed it through to the CLI untouched.
3. **`--exec` short-circuited the gate entirely** (old SKILL.md line 76). On that
   path the model arrived at `exec.sh` as a *positional argument the calling LLM
   typed from memory*.

Give a model a `[model]` slot, no validation, and nowhere to put effort, and it
invents `gpt-5.6-sol-high`. The fix is not "spell it right" — it's give effort its
own channel and make a bad value impossible to pass downstream.

A fourth issue made this near-undiagnosable and is fixed too: **every `exec.sh`
failure printed `EXEC_FAIL: … rc=1 ()`** — empty. `codex` reports API errors as
`{"type":"error"}` events on **stdout** (the `--json` stream), not stderr, so
`tail -1 $ERRLOG` always read an empty file.

## Ground truth (established empirically, not from memory)

Extracted from the codex-cli 0.144.1 embedded catalog, then **verified against the
live API** — the two disagree, which is why the empirical pass mattered:

- **Models:** `gpt-5.2` `gpt-5.4` `gpt-5.4-mini` `gpt-5.5` `gpt-5.6-sol` `gpt-5.6-terra` `gpt-5.6-luna`
- **Efforts:** `low` `medium` `high` `xhigh` `max` `ultra`

The API's own error message *claims* to support `minimal`, but `minimal` is
**rejected** by `gpt-5.6-sol`; conversely `max`/`ultra` are absent from the API enum
but work (codex maps them client-side). Trusting either source alone would have
shipped a wrong allow-list — i.e. recreated the bug.

## What changed

| File | Change |
|---|---|
| `scripts/lib.sh` | **New model-policy block** — the single source of truth: `CX_DEFAULT_MODEL=gpt-5.6-sol`, `CX_DEFAULT_EFFORT=high`, `CX_MODELS`, `CX_EFFORTS`, `cx_validate`, `cx_effort_conf`, `cx_flag`. Carries the refresh command for the next codex upgrade. |
| `scripts/gate.sh` | `--effort` flag; valueless `--model`/`--effort` now an error (was silently ignored); **validates before taking the lock** so a rejected turn leaves no state; persists `flag-effort`. |
| `scripts/pane.sh` | Always spawns with explicit `--model` + `-c model_reasoning_effort=…`. Records the spawn values to `pane-model` and, on reuse, **reports what the pane is actually running** rather than what this turn requested. |
| `scripts/exec.sh` | Named `--model`/`--effort` flags (was a bare positional); reads the gate's validated flags when in tmux; validates as a backstop; `exec_err()` pulls the real error out of the JSONL stream. |
| `SKILL.md` | Model/effort section with valid values; `--exec` **no longer skips the gate** when tmux is present; Step 5 must now print `Model: <m> @ <e> effort`; new invariant pinning policy to `lib.sh`. |
| `scripts/tests/` | fake-tmux records `split-window` argv so spawn args are actually asserted; `CX_SPAWN_SLEEP` seam keeps the suite fast. **111 assertions, all passing** (was 61). |

The key design decision: the **defaults live at the consumption site**
(`pane.sh`/`exec.sh`), while the **flag files exist only when the user explicitly
asked**. That distinction is what lets a reused pane warn "you asked for a model I
can't give you" without nagging on every default turn.

`CX_ALLOW_UNKNOWN=1` bypasses the allow-list, so our own guardrail can never
permanently block a model codex ships after this list was written.

## Found by live testing (unit tests had missed both)

Asked "is it actually tested?", the honest answer was *partly* — the unit suite
stubbed tmux, and every live run had used `env -u TMUX`, so two paths had **zero**
real coverage. Running them found two things:

1. **The interactive TUI launch was never verified.** Only `codex exec` had been
   confirmed to accept `-c model_reasoning_effort=`. Spawned a real codex in an
   isolated tmux session with the exact argv `pane.sh` builds: its status line reads
   `model: gpt-5.6-sol high`. Confirmed, not assumed.
2. **`gate.sh` silently depended on `preflight.sh` having run** (only preflight did
   `mkdir -p $SESSION_DIR/pending`). On a virgin state dir the lock `mkdir` fails,
   `mtime_s` returns nothing, the age arithmetic reads as "ancient" → the gate
   announces a bogus `STALE_LOCK` and then dies on a raw `mkdir` error. The unit
   harness pre-created that dir, which is exactly why 102 green assertions missed it.
   Fixed by having the gate own its precondition (`mkdir -p`, idempotent); pinned by
   a virgin-dir test. **Newly relevant** because this run changed SKILL.md so `--exec`
   in tmux no longer skips Step 0 — the ordering assumption was about to matter more.

3. **The fix introduced a lock leak — caught only by running the real skill.**
   Routing `--exec` through the gate (so the model gets validated) means the gate
   now *acquires* the single-flight lock. But the lock is released in
   `reply-validate.sh` (Step 3A.3), and **exec has no reply handler** — it's
   synchronous. So every `--exec` turn left the lock held, and the next
   `/codex-pair` in that window got `HOLD:` for the full 60-min TTL. Previously
   `--exec` skipped the gate, so no lock was ever taken; the regression is a direct
   cost of the fix. Now released via `trap … EXIT` in `exec.sh`, so it clears on
   success, `EXEC_FAIL`, and `INVALID_*` alike — a failed turn must not hold it
   either. Pinned by gate→exec lock-lifetime tests.

Lessons for the next run: a stub that pre-creates state hides precondition bugs; a
unit suite that never runs two scripts *in sequence* cannot see a lock leak. Both
bugs needed the real thing. **When a change moves a step into a lock-holding path,
find the release.**

## State

**Tests pass (111/111)** and the full in-tmux flow is verified live against
codex-cli 0.144.1:

- `preflight → gate(--exec --model gpt-5.5 --effort xhigh) → exec.sh` with **no
  model/effort args passed** → `MODEL=gpt-5.5 EFFORT=xhigh` → `pong`. The gate's
  validated flags reach the API with no hand-typed string anywhere in the path.
- Real codex TUI spawned with `pane.sh`'s argv → status line `gpt-5.6-sol high`.
- The original bug replayed through the real gate: `--model gpt-5.6-sol-high` →
  `INVALID_MODEL` naming the valid set, **no lock taken, nothing sent**.
- Effort enum settled empirically (see above): `max`/`ultra` work, `minimal` doesn't.

Not committed (`~/.claude` is not a git repo).

## Open / risks

- The allow-list is **static** and will reject genuinely-new models until refreshed.
  Deliberate: a typo caught beats a new model auto-passed. Refresh command is in
  `lib.sh`; `CX_ALLOW_UNKNOWN=1` is the escape hatch.
- Pane transports still can't *change* model on a live pane — codex fixes it at
  spawn. The skill warns rather than pretending. Only `--exec` applies model/effort
  per-call.
- `max`/`ultra` pass because codex translates them; if a future codex drops that
  translation they'd 400. The empirical check above is the only thing that catches
  this — rerun it after a codex upgrade.
