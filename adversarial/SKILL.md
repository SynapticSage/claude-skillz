---
name: adversarial
description: This skill should be used when the user wants to stress-test a claim, plan, or analysis through parallel adversarial then counter-adversarial agents — surfacing what survives scrutiny vs. what's confirmation bias. Triggers include "stress-test", "find holes", "pressure-test", "devil's advocate", "red team", "challenge this", "check my reasoning", "is this right", "audit this analysis".
---

# Adversarial Stress-Test

A workflow for rigorously testing analyses by having Claude agents argue both
sides in parallel across multiple rounds, then resolving each disagreement to a
tracked verdict. The goal is a **dispute-resolution** process, not a debate
format: every challenge lands in a ledger and stays there until it is resolved
for the claim, resolved against it, or declared irreducibly uncertain. The
synthesis distinguishes "well-argued" from "robust" because convergence is a
rule the ledger enforces, not a vibe the orchestrator notices.

## When to use

- High-stakes decisions where confirmation bias is dangerous
- Legal, financial, or technical analyses with multiple plausible interpretations or solutions
- Plans the user wants verified before committing
- Any time a "well-argued" conclusion needs to be distinguished from a "robust" one
- The user explicitly says "stress-test", "red team", "find holes", or similar

## When NOT to use

- Pure factual lookups (just answer)
- Personal/values questions disguised as factual ones (debate is theatrical)
- Quick clarifications
- Topics where evidence is **not retrievable** — private facts, genuinely novel
  situations, or speculation no search or source can settle. (Sparse *training*
  data alone is not disqualifying: agents can `WebSearch`/`WebFetch` for
  evidence. Calibrate on whether evidence can be *found*, not on corpus density.
  See [Calibration](#calibration-process-convergence-vs-domain-reliability).)

## Core concept: the dispute is the unit of iteration

The old failure mode was iterating on *claims* — one attack round, one defense
round, maybe one more. That privileges whoever speaks last and lets a satisfying
rebuttal end the process prematurely. Instead, iterate on **disputes**: a claim
may survive intact except for one narrow unresolved point, and that point is what
deserves another round. Every adversarial challenge becomes a row in a
[dispute ledger](#the-dispute-ledger) with an explicit status, and the loop only
continues while high-materiality disputes remain genuinely unresolved and each
round is still producing new evidence or new arguments.

## Workflow

### Phase 0: Extract claims, assumptions, and burden of proof

Read the file, claim, or analysis being tested. Extract **3-5 testable claims**
that are specific enough to attack with evidence, would materially change the
conclusion if overturned, and are actually disputed (skip settled facts). Group
small claims into themes rather than spawning 20 agents.

For **each** claim also record, before any attack:

- **Hidden assumptions** it rests on.
- **What evidence would overturn it** — define what failure looks like up front.
- **Burden of proof** — one of the [three labels](#burden-of-proof-labels). This
  decides who has to establish what, so the synthesis can't just split the
  difference later.

### Phase 1: Red-team round (parallel)

Spawn one agent per claim/theme **in parallel** — single message, multiple Agent
tool calls (agents run in the background by default). Brief each like:

> "You are reviewing a claim from an analysis. Find every hole, overstatement,
> and confirmation bias. Search for counterexamples, case law, contradicting
> evidence, real-world incidents. Be adversarial — I want what could go wrong,
> not reassurance. The claim is: [...]. Context: [...]."

Agents work in isolation; they don't see each other's outputs this round.

### Phase 2: Distill into a dispute ledger

Convert the red-team outputs into the structured [ledger](#the-dispute-ledger).
This is the layer that turns narration into procedure — without it you are just
debating.

Two rules govern what enters the ledger:

- **Assumption extraction (highest-value step).** After the attack, ask: what
  hidden assumptions did the adversarial outputs expose, and which are
  decision-critical? Add those to the ledger **even if they were not in the
  original 3-5 claims.** The most important fault lines usually emerge only under
  attack.
- **Four-bucket significance filtering.** Classify every finding as
  `substantiated-material`, `plausible-material`, `theoretical`, or
  `out-of-scope`. Discard **only** `theoretical` and `out-of-scope`. Keep
  `plausible-material` in the ledger at lower confidence — do not silently
  down-rank an inconvenient-but-under-evidenced risk to "theoretical." This is
  the guard against the orchestrator quietly suppressing what's uncomfortable.

If nothing survives filtering, the analysis survives the adversarial round — skip
to [Phase 7](#phase-7-synthesis).

### Phase 3: Counter round (targets disputes, not claims)

For each surviving dispute, spawn a counter-agent in parallel. Counter-agents
answer **specific disputes**, not broad claims:

> "Here is an adversarial claim against an analysis. Refute or narrow it for this
> specific situation. Apply the actual facts: [...]. Search for limiting
> principles, exceptions, real-world prevalence. Be honest — if the risk is real
> even after narrowing, say so."

Pass each counter-agent the specific dispute plus the relevant facts. Vague
counter-prompts produce vague counter-arguments.

### Phase 4: Targeted rebuttal on surviving disputes

This phase is what prevents last-speaker bias. Do **not** run another full
red-team. For each dispute the counter-round only *narrowed* (did not resolve),
run one targeted question:

> "Given the narrowing argument, does the original adversarial concern still
> materially survive for this decision?"

Neither side gets the final word by default. Any dispute that survives the
counter-round earns exactly one targeted rebuttal before synthesis, subject to
the round cap.

### Phase 5: Convergence check (by rule)

Update each dispute's `status` and `novelty_this_round`, then apply the
[convergence rules](#convergence-rules). Convergence is a ledger condition, not a
feeling.

- **If the stop conditions are met → Phase 6.**
- **If any [re-open trigger](#convergence-rules) fires AND you are under the round
  cap (default 3 total rounds):** run another round on the **unresolved disputes
  only**. Never re-test settled ones.
- **If the round cap is hit:** stop, and flag remaining unresolved disputes as
  "genuine uncertainty" in the synthesis.

### Phase 6: Steelman before synthesis

Before writing the synthesis, run one compression pass (no new searching) that
states, side by side and at the same stage:

- the strongest surviving case **for** the original analysis, and
- the strongest surviving case **against** it.

Re-articulating both at once is the second guard against whoever happened to
speak last.

### Phase 7: Synthesis

Produce a final markdown document:

```markdown
# [Analysis name] — Adversarial Stress-Test Results

## Steelman (both sides, post-resolution)
- **Strongest surviving case FOR:** [...]
- **Strongest surviving case AGAINST:** [...]

## Verdict by category
### Survived unchanged
- [Claim] — held across N rounds. [Why it held.]

### Survived only under narrower conditions
- [Claim] — adversarial round flagged X; resolved to Y only when [condition]. [Net assessment.]

### Failed
- [Claim] — [specific evidence that overturned it.]

### Depends on unknown facts
- [Question] — resolvable only with [the missing fact]. [What it would take.]

### Judgment call, not a factual dispute
- [Question] — this is a values/threshold choice, not something evidence settles.

## Dispute ledger (final state)
| ID | Challenge | Materiality | Evidence | Burden | Status |
|----|-----------|-------------|----------|--------|--------|

## Final risk matrix
| Risk | Original rating | Post-adversarial | Post-counter | Notes |
|------|-----------------|------------------|--------------|-------|

## Calibration
- **Process convergence:** High / Medium / Low — did the agents stop generating substantively new disputes?
- **Domain reliability:** High / Medium / Low — is the evidence retrievable and self-correcting, or sparse/one-sided?
- [A topic can have high process convergence and low domain reliability — that is the "training-data consensus, not truth" trap. Say so explicitly when it applies.]

## Decision implication
[If the synthesis changes the recommendation, state how. If not, say so.]
```

The five verdict categories matter: many "unresolved uncertainties" are really
*depends-on-unknown-facts* or *judgment-call*, and lumping them with factual
failures misreads the result.

## The dispute ledger

The ledger is the skill's spine. Maintain one row per surviving challenge:

| Field | Values | Meaning |
|-------|--------|---------|
| `claim_id` | e.g. `C2` | Which claim (or extracted assumption) this attacks |
| `challenge` | text | The adversarial objection, one line |
| `type` | factual / definitional / causal / legal / probabilistic / scope | Nature of the disagreement |
| `materiality` | high / medium / low | How much it moves the recommendation if true |
| `evidence_quality` | direct / indirect / speculative | Strength of what backs the challenge |
| `burden` | see below | Who must establish what |
| `status` | unresolved / resolved-for / resolved-against / irreducibly-uncertain | Current disposition |
| `novelty_this_round` | new-evidence / new-argument / reframing / repetition | What the latest round added |

`status` definitions:
- **resolved-for** — the objection was rebutted with claim-specific evidence or a valid limiting principle. Original claim stands on this point.
- **resolved-against** — the objection materially survives and overturns or weakens the claim.
- **irreducibly-uncertain** — further rounds produce reframings, not new evidence; the disagreement is now about priors, unknown facts, or values.
- **unresolved** — still live; eligible for another round if the rules allow.

## Burden-of-proof labels

Assign one to every claim in Phase 0. Without this, synthesis becomes rhetorical
rather than epistemic.

- **Defend-by-default** — the analysis must *positively establish* this claim
  (e.g. "this plan is legally compliant"). Absent support, it does not stand.
- **Attack-by-exception** — the claim stands *unless* a material exception is
  shown (e.g. "a rare edge case exists" only needs plausible material exposure).
- **Decision-threshold** — the issue is probabilistic; enough risk can matter
  even without proof (e.g. "this is the best engineering choice").

## Convergence rules

**A dispute is eligible for another round only if ALL hold:**
1. it is high or medium materiality, and
2. its status is still `unresolved`, and
3. the latest response introduced **new evidence, a new argument, or a narrowing
   that still leaves decision-relevant risk** (i.e. `novelty_this_round` is
   `new-evidence` or `new-argument`, not `reframing` or `repetition`).

**Re-open triggers** — any one of these means a dispute earns another round:
- the counter-agent narrowed but did not resolve the objection;
- the counter-agent introduced a new assumption;
- the counter-agent relied on prevalence or practical rarity **without evidence**;
- the adversarial claim attacks a different scope than the original claim, and scope must be reconciled;
- the disagreement is now about probability (not possibility) and probability matters to the recommendation.

**Stop when any of these hold:**
- all high-materiality disputes are no longer `unresolved`, or
- the remaining unresolved disputes are `irreducibly-uncertain` or purely
  probabilistic/value-based, or
- no surviving dispute produced new evidence or a new argument in the latest round.

**Hard cap: 3 rounds.** At the cap, stop and label residuals genuine uncertainty.

## Default parameters

- **Parallel breadth:** 3-5 disputes per round (one agent each).
- **Rounds:** red-team → counter → targeted rebuttal, governed by the convergence
  rules. Max 3.
- **Mode:** isolated agents (each sees prior rounds as static text). Team-message
  mode is more powerful but harder to coordinate — only use if explicitly requested.
- **Background execution:** yes. Agents run in the background by default;
  synthesize on completion.

## Calibration: process convergence vs. domain reliability

Report these as **two separate ratings** in the synthesis — conflating them is
the skill's most dangerous failure mode:

- **Process convergence (High/Medium/Low):** are the agents still generating
  substantively new disputes, or has the ledger stabilized?
- **Domain reliability (High/Medium/Low):** is the underlying question actually
  well-settled — dense, self-correcting, evidence-retrievable — or sparse,
  one-sided, or dependent on private/forward-looking facts?

High process convergence with low domain reliability means the agents agreed, but
their agreement reflects training-data or search consensus, not truth. Always
flag this. Low-reliability regimes include predictions about specific human
behavior, niche legal questions in unlitigated areas, novel technical situations,
and anything depending on private information.

## Anti-patterns

**Don't:**
- Spawn agents serially when they could go in parallel (waste of wall time).
- Run more than 3 rounds (diminishing returns; relitigating margins).
- Treat adversarial findings as automatically true — that's just substituting one agent's confidence for another's. The counter and rebuttal phases exist to force every challenge to be defended.
- Let convergence be a judgment call — apply the [rules](#convergence-rules). Motivated stopping ("the rebuttal felt satisfying") is exactly where confirmation bias re-enters.
- Down-rank an inconvenient finding to `theoretical` to drop it. If it's `plausible-material`, it stays in the ledger.
- Let either side have the last word by default — Phase 4 exists for this.
- Skip the dual calibration rating — it's the most important part of the synthesis.
- Use this for binary yes/no questions where one side is just "the same claim restated as a question."

**Do:**
- Accept that some disputes end `irreducibly-uncertain`. That is a valid, honest output.
- Mark what survived as survived — don't downgrade everything just to seem balanced.
- Pass counter-agents the actual specific facts.
- Run the dual calibration check honestly even when results favor the original analysis.

## Example invocation

```
/adversarial check tax/cost-benefit-analysis.md
```

Internal flow:
1. **Phase 0** — read the file; extract 3-5 claims with hidden assumptions, overturning evidence, and burden-of-proof labels.
2. **Phase 1** — spawn 3-5 adversarial agents in parallel (single message, multiple Agent calls).
3. **Phase 2** — distill outputs into the dispute ledger; extract exposed assumptions; four-bucket filter.
4. **Phase 3** — spawn counter-agents per surviving dispute in parallel.
5. **Phase 4** — targeted rebuttal on disputes the counter-round only narrowed.
6. **Phase 5** — update ledger; apply convergence rules; loop on unresolved disputes only if a re-open trigger fires and under the cap.
7. **Phase 6** — steelman both sides.
8. **Phase 7** — synthesize (five verdict categories + final ledger + dual calibration) and write to `<original-name>-adversarial-results.md`.

## Optional: enforce the loop in code

When the `Workflow` tool is available, the convergence loop can be run as a
deterministic script instead of by orchestrator judgment — the ledger becomes a
data structure and the stop/re-open rules become literal loop predicates. See the
Workflow-mode section (added by T3-A2) when present; otherwise use the plain Agent
orchestration above.

## Harness assumptions

Verified against Claude Code as of 2026-07-06. This skill assumes:
- Adversarial and counter agents spawn via the `Agent` tool and run in the background by default.
- Agents can use `WebSearch`/`WebFetch` to retrieve evidence, so calibrate on evidence retrievability, not training-corpus density alone.
- Optional: the `Workflow` tool, if available, can enforce the convergence loop in code.

If a listed tool name or behavior no longer matches the live harness, fix this skill before trusting it.
