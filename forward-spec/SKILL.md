---
name: forward-spec
description: |
  Use this skill when the user asks for a forward-looking design spec, research
  plan, proposal, RFC, optimization plan, "what should we do about X", "audit
  the codebase for Y and propose a plan", or any artifact where the goal is
  evidence-led recommendations organized for implementation — not a recap of
  past work. Optionally spawns parallel research agents up front, optionally
  pressure-tests the draft through `/codex-pair` until GO, and emits a single
  markdown document with executive summary, audit sections, rollout-tiered
  opportunities, mermaid diagrams (portable subset), and a reviewer
  traceability table. Counterpart to `audit-trail` (backward-looking).
  Triggers: "design spec", "research plan", "forward spec", "RFC", "proposal",
  "investigate and propose", "audit X and recommend", "what should we change",
  "optimization plan", "rollout plan".
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - Agent
  - AskUserQuestion
---

# Forward Spec

Counterpart to `audit-trail`. Where `audit-trail` reports what already
happened, this skill produces a **forward-looking, evidence-led plan**:
audit findings, proposed changes organized by rollout tier, optional
diagrams, and (optionally) a reviewer-pressure-tested verdict.

The gold-standard output reference is
`~/.claude/skills/codex-pair/TOKEN_OPTIMIZATION_RESEARCH.md`. Match its
structure, citation discipline, and traceability when the inputs warrant
it.

This skill produces an artifact. It is not a chat-style answer.

## Why this and not `design` / `document` / `audit-trail`

- `audit-trail` is backward-looking. It reports observed activity.
- `design` (SuperClaude) is open-ended architecture work without an
  enforced doc shape, parallel-research step, or reviewer round-trip.
- `document` writes documentation, not decision documents.
- `forward-spec` is opinionated about *one* artifact shape: the
  exec-summary → audits → rollout-tiered opportunities → reviewer
  traceability stack, with optional parallel research and optional
  Codex pressure-test built into the workflow.

## When To Use

- The user asks for a design spec, research plan, RFC, proposal,
  optimization plan, or rollout plan.
- The user says "investigate X and tell me what to do" or "audit Y and
  propose changes".
- After a debugging or research session where the assistant has accreted
  findings and now needs to crystallize them into an actionable doc.
- The user explicitly invokes the skill, optionally with flags:

```text
forward-spec
forward-spec "Token cost in codex-pair skill"
forward-spec --research-agents 3 "Performance audit of save_session.sh"
forward-spec --review --reviewer codex-pair "Should we drop tmux_list?"
forward-spec --review --max-rounds 2 --output ./docs/plan.md "Topic"
forward-spec --no-mermaid "Topic"
```

## When Not To Use

- The user wants a one-paragraph answer or a quick verbal recommendation.
- The user wants a recap of what just happened — that's `audit-trail`.
- The task is pure documentation of an existing system without
  recommendations — use `document`.
- The user wants only a diagram — use a diagram-first skill.

## Argument Parsing

Treat text after the skill name as a CLI-style argument string. The
**topic** is the first positional argument (quoted or unquoted). Flags
may come before or after.

| Flag | Default | Meaning |
|---|---|---|
| `--research-agents N` | `2` | Spawn N parallel research subagents in step 2. `0` skips research. |
| `--review` | off | Pipe the consolidated draft through a reviewer for GO/no-go rounds. |
| `--reviewer <name>` | `codex-pair` | Reviewer to use when `--review` is set. Currently only `codex-pair` is supported as a built-in. Other values are passed verbatim and the workflow degrades to "ask the user to review manually." |
| `--max-rounds N` | `3` | Cap on review rounds. Step 5 stops at GO or at this cap. |
| `--mermaid` | on | Include mermaid diagrams (glossary, system overview, before/after sequences, rollout tier flowchart, bar chart). |
| `--no-mermaid` | — | Skip mermaid diagrams. Useful when the consumer's renderer is unknown. |
| `--output <path>` | `${REPO_ROOT}/docs/research/<topic-slug>.md` | Where the final doc lands. |
| `--draft-only` | off | Stop after step 3 (draft assembled). Skips review even if `--review` is set. Useful for "just give me the structure, I'll polish." |

If the user invokes the skill with no topic, ask once:

```
What's the topic / problem statement?
A) Use the most recent assistant turn(s) as the input
B) I'll provide a one-paragraph problem statement
C) Cancel
```

If A: synthesize the topic from the last 2-3 assistant turns and confirm
in one line before proceeding.

## Workflow

The skill is a 6-step pipeline. Steps 2 and 4-5 are optional; the
defaults run a 2-agent research pass and skip review.

### Step 1 — Gather problem statement and scope

Lock down inputs before doing any work:

- **Topic** (one sentence — what's being designed/researched/audited).
- **Scope** (file globs, directories, repos, or "user's transcript so
  far"). Ask if not obvious.
- **Output path** — resolve `--output` or compute the default:
  `REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)`,
  `OUT="${REPO_ROOT}/docs/research/<topic-slug>.md"`.
- **Constraints** — anything the user has already ruled in/out (e.g.
  "no upstream PRs", "must be ship-today", "budget under 1 day").
  These shape the rollout tiers in step 3.

If `--output`'s parent directory doesn't exist, create it. If the file
exists, suffix with `-2`, `-3`, etc. — never overwrite silently.

### Step 2 — Parallel research (optional, default 2 agents)

If `--research-agents 0`, skip to step 3.

Otherwise spawn N subagents in parallel via the `Agent` tool, each with a
distinct cost-surface / concern / facet to audit. Agents run in the
background by default; their findings arrive on completion. The workflow author
(you, Claude) chooses the partition based on the topic. Common
partitions:

- **By cost surface**: per-call hot path / always-on overhead /
  cold-start / storage.
- **By layer**: API surface / implementation / config / tests / docs.
- **By severity dimension**: correctness / performance / security /
  ergonomics.
- **By codebase region**: subsystem A / subsystem B / cross-cutting.

Use the [research agent prompt template](#research-agent-prompt-template)
below. Each agent returns structured findings; you consolidate.

After agents return, deduplicate findings, reconcile contradictions
(prefer the agent with file:line evidence), and produce a flat findings
list keyed by stable IDs (`A1`, `A2`, … per agent). These become
anchors for the reviewer traceability table later.

### Step 3 — Assemble the draft

Build a markdown document matching the [Output Structure](#output-structure)
below. Inputs: the problem statement (step 1), the consolidated findings
(step 2), and any prior context the skill caller provided.

Required sections (in order):

1. **Title + 1-paragraph framing** — what was audited, who reviewed,
   final verdict (initially "draft — not yet reviewed").
2. **Executive summary** — name the cost/quality surfaces being
   measured/changed, give a today vs. proposed table.
3. **Quick orientation** (optional but encouraged) — glossary,
   "what costs what / where" diagram, before/after sequence diagrams.
4. **Audit sections** — one per partition from step 2. File:line
   citations. Severity tags inline (LOW/MEDIUM/HIGH/CRITICAL).
5. **Reduction / proposed-change opportunities organized by rollout
   tier** — Tier 1 ship-today, Tier 2 surgery-no-API-change, Tier 3
   upstream-coordination. Severity is *inline metadata*, not the
   section header. (See [Severity vs. rollout tier](#severity-vs-rollout-tier).)
6. **Recommended rollout order** — numbered list of which tiers/items
   ship in what sequence.
7. **Open questions** — items that need future review or out-of-scope
   for this round.
8. **Files referenced** — every `path:line` cited above, with the
   "verify before acting" caveat.
9. **Reviewer traceability table** — empty placeholder if `--review`
   isn't set; populated from step 5 if it is.

Diagrams: only include if `--mermaid` (default on). See
[Mermaid portability rules](#mermaid-portability-rules).

If `--draft-only`, write the file and stop here.

### Step 4 — Reviewer round-trip (optional, off by default)

If `--review` is not set, skip to step 6.

Otherwise, for each round (1..`max_rounds`):

1. Send the current draft to the reviewer using the
   [review request template](#review-request-template).
2. Capture the verdict: **GO**, **GO-with-conditions**, or **NO-GO**.
3. If **GO**: stop the loop. Record the round number.
4. If **GO-with-conditions** or **NO-GO**: extract the findings, fold
   each into the doc body (don't just append — edit the relevant
   audit/opportunity section in-place), and append a row to the
   reviewer traceability table (round → finding → severity →
   resolution).
5. If round count == `max_rounds` and we still don't have GO, stop
   anyway and surface the residual conditions to the user as "blocking
   review found these unresolved items" in the doc and in the final
   chat output.

The reviewer is invoked through `/codex-pair` by default (see
[Codex-pair invocation](#codex-pair-invocation)). The correlation tag
protocol (`[req:<8hex>]` / `[reply-to:<8hex>]`) is handled by
`/codex-pair`'s own machinery; this skill just hands it a prompt and
reads the verbatim reply.

If `/codex-pair` isn't installed and `--reviewer codex-pair` was
requested, surface a clear error: "Reviewer `codex-pair` not installed.
Either install it (`~/.claude/skills/codex-pair/install.sh`) or rerun
without `--review`." Don't silently skip review.

### Step 5 — Consolidate review feedback

Each round's output produces:

- An updated draft body with reviewer findings folded into the
  relevant audit/opportunity sections.
- A new sub-section in the reviewer traceability table:

```markdown
### Round 1 (req `<8hex>`) — <verdict>

| Finding | Severity | Resolution |
|---|---|---|
| <one-line summary> | HIGH/MEDIUM/LOW/NEW | <what changed in the doc> |
```

Every reviewer finding ends up in exactly one table row. If the round
flagged purely doc-consistency items (numbers contradict, sections out
of order), still record them — they're the kind of thing rounds 2 and
3 in the gold-standard doc surfaced.

### Step 6 — Write the file and report

Write the final document to the resolved `--output` path. Then return
to the user a 5-line summary:

```text
Forward-spec written: <abs path>
Topic: <topic>
Research agents: <N> (skipped: <which>)
Review: <skipped | GO round R | NO-GO after max-rounds>
Open questions: <count>
```

Do NOT paste the doc body into chat — the file IS the deliverable.

---

## Output Structure

Canonical document shape. Reuse the gold-standard
`TOKEN_OPTIMIZATION_RESEARCH.md` as the implementation reference.

```markdown
# <Topic> — Forward Spec

<2-3 sentence framing: what was audited, who reviewed, verdict.>

**Read this when:** <one-line situation in which a future reader would
return to this doc.> Each finding cites file:line; verify before acting
— line numbers go stale.

---

## Executive summary

<2-4 paragraphs naming the cost/quality surfaces, today's baseline,
proposed change, expected delta. End with a today-vs-after table.>

| Surface | Today | After | Delta |
|---|---|---|---|
| ... | ... | ... | ... |

---

## Quick orientation (read this first)

### Glossary
| Term | Plain meaning |
|---|---|

### What costs / changes what, where
<mermaid flowchart — only if --mermaid>

### A typical <thing> today
<mermaid sequenceDiagram — only if --mermaid>

### The same <thing> after Tier 1 / proposed change
<mermaid sequenceDiagram — only if --mermaid>

### Rollout tier roadmap
<mermaid flowchart — only if --mermaid>

### Before vs after — quantitative
<mermaid xychart-beta or table>

---

## Audit A — <surface 1>
<file:line citations, evidence, severity tags inline.>

## Audit B — <surface 2>
...

---

## Proposed changes (organized by rollout tier)

Sections ordered by **rollout priority**, not severity. Severity tags
preserve audit grading for traceability but don't dictate order.

### Tier 1 — ship today, no contract change
#### <ID> — <one-line title>
- **Severity:** <LOW/MEDIUM/HIGH>. **Impact:** <quantified>.
- <evidence>. <risk>. <touch surface>.

### Tier 2 — surgery in this codebase, no API change
...

### Tier 3 — upstream coordination
...

---

## Recommended rollout order
1. <ID> — <Tier>.
2. ...

---

## Reviewer traceability
<populated from step 5; empty if --review skipped>

### Round 1 (req `<8hex>`) — <verdict>
| Finding | Severity | Resolution |
|---|---|---|

---

## Open questions
1. ...

---

## Files referenced
- `path:Lstart-Lend` — what it shows. Line numbers as of <date>; verify
  before acting.
```

---

## Severity vs. rollout tier

Codex flagged this in round 2 of the gold-standard doc as load-bearing
for implementation readers. **Severity** describes how bad a finding is.
**Rollout tier** describes when to ship it. They are independent axes:

- A LOW-severity finding can be Tier 1 if it's a one-line SKILL.md
  swap.
- A HIGH-severity finding can be Tier 3 if it requires upstream PR
  coordination.

Always organize the "proposed changes" section by **tier**. Carry
severity as inline metadata on each finding (`**Severity:** medium`).
Do not collapse the two — readers use tier to prioritize implementation
and severity to assess risk if deferred.

The three default tiers (override per-topic if appropriate):

| Tier | Definition |
|---|---|
| **Tier 1** | Ship today. No contract / API change. SKILL.md or local-config edits only. Pure wins. |
| **Tier 2** | In-codebase surgery. install.sh changes, schema migration, feature-flag rollout. No upstream change required. |
| **Tier 3** | Requires coordination outside this repo (upstream PRs, dependency releases, customer comms). Defer until Tier 1+2 land. |

If the topic doesn't fit this exact partition (e.g., it's a research
question, not a change plan), substitute a domain-appropriate tier
schema and document it in the doc's preface. The principle — order by
sequencing, not severity — stays.

---

## Mermaid portability rules

Codex flagged viewer-side fragility in round 2 of the gold-standard
doc. Render-everywhere subset:

- **No `autonumber`.** Some Mermaid viewers haven't shipped it.
- **No participant aliases with spaces.** Use
  `participant ClaudeCode`, not `participant CC as Claude Code`.
- **No multi-actor `Note over X,Y` directives.** Use
  `Note over X: text` (single actor) or move the note to a
  pre/post-block comment.
- **No semicolons (`;`) in message text.** Mermaid treats `;` as a
  statement terminator inside arrows.
- **No `#` in message text.** Mermaid treats it as a comment marker.
- **No commas (`,`) in message text** unless inside quotes — and
  quoted message text is itself fragile across renderers.
- **No literal newlines in message text.** Use `<br/>` inside quoted
  node labels only; in sequence-diagram messages, break into multiple
  arrows.
- **Node labels with `<br/>` must be quoted.** `A["line one<br/>line two"]`,
  not `A[line one<br/>line two]`.
- **Class definitions and styles go at the bottom.** Some renderers
  fail when `classDef` precedes its referent.
- **xychart-beta is supported in modern Mermaid only.** Provide a
  table fallback if portability matters.

When in doubt, render the doc through GitHub's Mermaid viewer — that's
the strictest common consumer.

---

## Research agent prompt template

When `--research-agents N` > 0, spawn each via the `Agent` tool with a
prompt of this shape. Substitute `<topic>`, `<scope>`, `<facet>`,
`<files>` from step 1.

```text
You are research agent <K> of <N>. Topic: <topic>.
Scope: <files / globs / directories>.
Your facet: <facet> — focus your audit here. Other agents are covering
other facets in parallel; do not try to cover the whole topic.

Return a flat markdown document with:

## Findings

### F<K>.1 — <one-line title>
- **Severity:** LOW | MEDIUM | HIGH | CRITICAL
- **Evidence:** file:line — quoted excerpt or paraphrase
- **Why it matters:** <one sentence>
- **Tier hint:** Tier 1 / 2 / 3 (your guess; the consolidator may move it)
- **Proposed change:** <one paragraph, concrete>

### F<K>.2 — ...

## Files inspected
- path:Lstart-Lend — what you read

## Open questions for the consolidator
- ...

Constraints:
- Cite file:line for every finding. No file:line, no finding.
- Quantify impact where possible (tokens, ms, bytes, calls/turn).
- Prefer measured numbers over guesses; mark guesses as ~estimate~.
- Do not propose changes outside your facet, but flag cross-facet
  concerns under "Open questions for the consolidator".
- Brevity: this is structured input for a consolidator, not a report.
```

The consolidator (you) merges all `F<K>.N` findings into the audit
sections and tier list. Keep the `F<K>.N` IDs intact in the final
doc as anchors so reviewer feedback can reference them.

---

## Review request template

When `--review` is set, send the reviewer this prompt (via
`/codex-pair` or whatever reviewer the user named). Substitute
`<draft-path>` and `<round-number>`.

```text
Pressure-test this forward spec for round <round-number>.

Doc: <draft-path> (read it in full).

Return:

## Verdict
GO | GO-with-conditions | NO-GO

## Findings (if any)
For each issue, structure as:

### <ID> — <one-line title>
- **Severity:** LOW | MEDIUM | HIGH | CRITICAL | NEW (a finding I'm
  raising for the first time, regardless of severity)
- **Evidence:** quote or file:line from the doc
- **Why it matters:** one sentence
- **Suggested resolution:** one sentence

## Round-specific focus (this round only)
- Round 1: cost-surface accuracy, missing audit angles, stale
  assumptions, severity calibration, tier placement.
- Round 2: doc-consistency — numbers that contradict between sections,
  severity vs. tier organization, citation freshness.
- Round 3: final read — anything blocking GO; nuance fixes acceptable.

Constraints:
- Cite the doc, not the underlying codebase, unless flagging a stale
  citation.
- Do not rewrite sections; describe the change required.
- "GO" means you'd ship the implementation order described, not that
  the doc is perfect.
```

The reply is parsed for the `## Verdict` line; folded into the
traceability table and (where actionable) into the audit/opportunity
sections.

---

## Codex-pair invocation

When `--reviewer codex-pair` (default), the skill calls the
`/codex-pair` skill from inside its own workflow. Mechanics:

- Write the [review request template](#review-request-template)
  populated with the current draft path to a temp file.
- Invoke `/codex-pair` with that prompt as the input. The skill's own
  correlation-tag protocol (`[req:<8hex>]` / `[reply-to:<8hex>]`) is
  invisible to us — we just see Codex's verbatim reply.
- Wait for Codex's response. `/codex-pair` ends CC's turn after
  delivery; the reply arrives as a fresh user message in a later
  turn. The skill workflow must therefore tolerate being suspended
  between rounds — write the current draft + round counter to
  `$FS_STATE_DIR/state.json`, where
  `FS_STATE_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.context/forward-spec/<topic-slug>"`
  (mirrors codex-pair's `.context/` convention, including its `.gitignore`
  handling), so a resumption can pick up.

State file shape:

```json
{
  "topic": "<topic>",
  "draft_path": "<abs path>",
  "round": 1,
  "max_rounds": 3,
  "verdicts": ["GO-with-conditions"],
  "last_req_id": "abcd1234",
  "status": "awaiting-reply"
}
```

When the user comes back with Codex's pushed reply, the skill picks up
the state file, parses the verdict, folds findings, increments `round`,
and either fires another review request or finalizes.

If the user is invoking this skill in a non-tmux context (no
`/codex-pair` available), `--review` requires `--reviewer <name>` to be
something the user can drive manually — the skill will pause at each
round and ask the user to paste the reviewer's verdict. Document this
clearly in the round-1 prompt to the user.

---

## Compression strategy

When the topic is small or the user hits a budget cap:

1. Keep executive summary, audits, tier-organized opportunities,
   files-referenced.
2. Collapse glossary into 5-7 critical terms.
3. Drop sequence diagrams; keep only the system overview + tier
   roadmap.
4. Merge low-severity Tier 3 items into a single "deferred" bullet.
5. Say what was omitted at the top of the doc:
   `Omitted for budget: per-section sequence diagrams, audit C
   secondary findings.`

---

## Anti-patterns

- Do not present the spec as a polished narrative that hides
  contradictions. If two audit findings disagree, surface the
  disagreement and resolve it explicitly.
- Do not claim a number is measured if it was estimated. Mark
  estimates with `~` or `est.`.
- Do not organize the proposed-change section by severity — that's the
  Codex-flagged anti-pattern. Tier first, severity inline.
- Do not silently skip review when `--review` is set and the reviewer
  isn't available. Surface the failure and ask.
- Do not regenerate the whole doc on each review round. Edit in place;
  the traceability table is what records the journey.
- Do not paste the full doc into chat at the end. The file is the
  deliverable.
- Do not invent file:line citations. If the agent didn't read the
  file, say `not verified — ${file} unread`.
- Do not generate diagrams when `--no-mermaid` is set, even "just a
  small one."

---

## Hidden-reasoning guardrail

Same rule as `audit-trail`. Do not dump scratchpad reasoning, false
starts, or token-level deliberation into the doc. Replace with
auditable rationale:

```text
Decision: Promoted M2 from Tier 2 to Tier 1.
Why: M2 is a single-line SKILL.md edit with no contract change.
Evidence: Codex round 1 finding F2.3.
```

The reviewer traceability table is the *only* place process notes
belong, and even there, each row is "what changed in the doc," not
"how the assistant felt about the change."

---

## Harness assumptions

Verified against Claude Code as of 2026-07-06. This skill assumes:
- Research subagents spawn via the `Agent` tool and run in the background by default; results arrive on completion.
- `--review --reviewer codex-pair` needs tmux + the `codex` CLI on PATH (driven through the codex-pair skill).

If a listed tool name or behavior no longer matches the live harness, fix this skill before trusting it.
