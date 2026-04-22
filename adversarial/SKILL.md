---
name: adversarial
description: This skill should be used when the user wants to stress-test a claim, plan, or analysis through parallel adversarial then counter-adversarial agents — surfacing what survives scrutiny vs. what's confirmation bias. Triggers include "stress-test", "find holes", "pressure-test", "devil's advocate", "red team", "challenge this", "check my reasoning", "is this right", "audit this analysis".
---

# Adversarial Stress-Test

A workflow for rigorously testing analyses by having Claude agents argue both sides in parallel across multiple rounds, with explicit convergence detection. Yields a synthesis that distinguishes "well-argued" from "robust."

## When to use

- High-stakes decisions where confirmation bias is dangerous
- Legal, financial, or technical analyses with multiple plausible interpretations or solutions
- Plans the user wants verified before committing
- Any time a "well-argued" conclusion needs to be distinguished from a "robust" one
- The user explicitly says "stress-test", "red team", "find holes", or similar

## When NOT to use

- Pure factual lookups (just answer)
- Personal/values questions disguised as factual ones (debate is theatrical)
- Topics with sparse training data (novel, private, or speculative)
- Quick clarifications

## Workflow

### Phase 0: Scope the input

Read the file, claim, or analysis being tested. Extract **3-5 testable claims** that:
- Are specific enough to attack with evidence
- Would materially change the conclusion if overturned
- Are actually disputed (skip settled facts)

Don't spawn 20 parallel agents — diminishing returns and high token cost. Group small claims into themes if needed.

### Phase 1: Adversarial round (parallel)

Spawn one agent per claim **in parallel** — single message, multiple Agent tool calls. Use `run_in_background: true` so the main thread doesn't block. Each agent gets a brief like:

> "You are reviewing a claim from an analysis. Find every hole, overstatement, and confirmation bias. Search for counterexamples, case law, contradicting evidence, real-world incidents. Be adversarial — I want what could go wrong, not reassurance. The claim is: [...]. Context: [...]."

Agents work in isolation. They don't see each other's outputs in this round.

### Phase 2: Identify significant findings

Read each adversarial output. A finding is **significant** if it:
- Cites specific evidence (statute, case law, documented incident)
- Identifies a real risk not in the original analysis
- Would materially change the recommendation if true

Discard findings that are:
- Pure theoretical maxima with no enforcement reality
- Already addressed in the original analysis
- Misapplied to the specific fact pattern

If no significant findings emerge, the analysis survives the adversarial round — skip to Phase 5.

### Phase 3: Counter-adversarial round (parallel)

For each significant finding, spawn a counter-agent in parallel:

> "Here is an adversarial claim against an analysis. Your job is to refute or narrow it for this specific situation. Apply the actual facts: [...]. Search for limiting principles, exceptions, real-world prevalence. Be honest — if the risk is real even after narrowing, say so."

Pass each counter-agent the specific finding plus the relevant facts of the situation.

### Phase 4: Convergence check

Has the analysis stabilized? Indicators of convergence:
- Counter-agents narrowed adversarial findings rather than fully refuting or fully accepting
- Remaining disputes are about probability or values, not facts
- The list of unresolved questions is shrinking round-over-round
- New arguments per round are diminishing

**If converged → Phase 5.**

**If not converged AND under round limit (default 3 total rounds):** spawn another adversarial round on the *remaining disputes only*. Don't re-test settled findings.

**If round limit hit:** stop, synthesize, flag unresolved disputes as "genuine uncertainty."

### Phase 5: Synthesis

Produce a final markdown document with this structure:

```markdown
# [Analysis name] — Adversarial Stress-Test Results

## What survived
- [Claim] — confirmed across N rounds. [Why it held up.]

## What was overstated
- [Claim] — adversarial round flagged X; counter-round narrowed to Y. [Net assessment.]

## What was refuted
- [Claim] — [Specific evidence that overturned it.]

## What remains uncertain
- [Question] — adversarial and counter rounds did not converge. [The disputed ground.]

## Final risk matrix
| Risk | Original rating | Post-adversarial | Post-counter | Notes |
|------|----------------|------------------|--------------|-------|

## Calibration note
[How well-represented is this topic in public discourse?
- Dense + self-correcting (law, established science, well-documented engineering) → high trust in convergence
- Sparse / one-sided / novel → lower trust; flag explicitly]

## Decision implication
[If the synthesis changes the recommendation, state how. If not, say so.]
```

## Default parameters

- **Parallel breadth:** 3-5 issues per round (one agent each)
- **Rounds:** 2 by default (adversarial → counter). Max 3 if convergence hasn't been reached.
- **Mode:** isolated agents (each sees prior round's outputs as static text). Team-message mode is more powerful but harder to coordinate — only use if explicitly requested.
- **Background execution:** yes. Spawn with `run_in_background: true` and synthesize on completion.

## Calibration warning (always include in synthesis)

This skill works best when the topic is densely represented in self-correcting public discourse — law, established science, well-documented engineering. The adversarial dynamic surfaces real disagreements only when the training corpus contains real disagreement.

For topics where the corpus is sparse or one-sided, "convergence" reflects training-data consensus, not truth. Always flag this in the synthesis. Examples of low-trust convergence:
- Predictions about specific human behavior
- Niche legal questions in unlitigated areas
- Novel technical situations
- Anything that depends on private information

## Anti-patterns

**Don't:**
- Spawn agents serially when they could go in parallel (waste of wall time)
- Run more than 3 rounds (diminishing returns; you're relitigating margins)
- Treat adversarial findings as automatically true — that's just substituting one agent's confidence for another's
- Skip the calibration warning — it's the most important part of the synthesis
- Use this for binary yes/no questions where one side is just "the same claim restated as a question"

**Do:**
- Accept that some questions don't converge. "Genuine uncertainty" is a valid output.
- Mark claims that survived as such — don't downgrade everything just to seem balanced
- Pass the actual specific facts to counter-agents; vague counter-prompts produce vague counter-arguments
- Run the calibration check honestly even when results are favorable to the original analysis

## Example invocation

```
/adversarial check tax/cost-benefit-analysis.md
```

Internal flow:
1. Read the file, extract 3-5 claims
2. Spawn 3-5 adversarial agents in parallel (single message, multiple Agent tool uses, run_in_background: true)
3. As each completes, read findings, identify significant ones
4. Spawn counter-agents in parallel for significant findings
5. Check convergence
6. Synthesize and write to `<original-name>-adversarial-results.md`
