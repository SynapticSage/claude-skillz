---
name: roadmap-digest
description: >
  Generate a self-contained, human-digestible HTML view of a project's roadmap and what has
  been completed — a companion that runs IN PARALLEL to the roadmap file: it never edits the
  roadmap, and it is regenerated to a stable path so `git diff` shows how the human-facing
  picture drifts as the plan evolves. Reads roadmap/plan files for intent and cross-references
  journal/ + git history for what actually shipped, then renders an at-a-glance dashboard
  (overall progress ring, status-colored phase cards, recently-shipped and next-up strips).
  Use this whenever the user wants to "see the roadmap", "show progress", "what's done vs
  what's left", a "status page or dashboard for the plan", a "roadmap summary for the team",
  or to turn a dense ROADMAP.md / plan/ folder into something scannable in fifteen seconds —
  even if they never say the word "HTML". This is deliberately distinct from three sibling
  skills: it is NOT explaining a single decision or finding to an audience (use `explainer`),
  NOT a backward-looking recap of what the assistant just did (use `audit-trail`), and NOT a
  forward design proposal or RFC (use `forward-spec`). Reach for roadmap-digest specifically
  when the subject is the whole roadmap plus its completion state, packaged for rapid human digestion.
---

# Roadmap Digest

Turn a project's roadmap and its progress into a single self-contained HTML page a human can
absorb in about fifteen seconds. The roadmap file is written for correctness and completeness;
this digest is written for the *eye* — progress at a glance, colour-coded status, minimal prose.

## The one idea that governs everything

**The digest is derived, never authoritative.** The roadmap file (and the journal, and git
history) are the sources of truth. This skill only *reads* them and emits a companion view.

- **Never edit the roadmap** or the journal to make them match the digest. If the roadmap is
  wrong or stale, say so in your summary to the user — don't silently "fix" the source.
- **Write to a stable path** (default `docs/roadmap-digest.html`) and overwrite it each run. A
  fixed path is the feature: committing it means `git diff` on the digest shows precisely how
  the human-facing story changed as the plan and the work evolved.
- Because it's regenerated, the digest is *disposable*. Optimise it for reading, not for being
  a second place that facts live.

## Invocation options

Read these from the user's request; fall back to the defaults.

| Option | Values | Default | Meaning |
|--------|--------|---------|---------|
| `style` | `dashboard` · `narrative` · `detailed` | `dashboard` | Layout — see below |
| `out` | any path | `docs/roadmap-digest.html` | Where to write the file |
| `sources` | paths | auto-detect | Force specific roadmap/plan files |

- **dashboard** (default) — overall progress ring, status-coloured phase cards, a "recently
  shipped" strip and a "next up" list. High signal, low prose. The right default for "show me the roadmap".
- **narrative** — an exec-update read: *Where we are · Shipped · In flight · Up next · Risks*,
  with a compact progress summary on top. Choose when the audience wants sentences, not cards.
- **detailed** — the dashboard, plus each item expands to reveal its *why* and the evidence
  (journal entry / commit) behind its status. Choose when people will drill in.

## Procedure

### 1 — Gather the raw signals

Run the bundled script to discover sources fast instead of hand-searching every time:

```bash
bash scripts/gather.sh [project_root]   # defaults to the current directory
```

It prints, with clear headers: roadmap/plan candidates (priority order), the `journal/` index
(newest first, with each entry's first heading), and recent git history. If it reports **no
roadmap candidates**, stop and ask the user where the roadmap lives — don't guess or invent one.

### 2 — Read the roadmap, then build the model

Read the top roadmap candidate(s) in full. Then read only the journal entries / commits you
need to decide what actually shipped. Assemble a normalized model — phases, each holding items,
each item carrying a **status** and a compressed **why**. The status taxonomy and the rules for
inferring status from mixed signals (checkboxes, journal entries, commits, prose) live in
`references/extraction.md` — read it; roadmaps are messy and that file is where the judgment calls are.

The model you produce is a JSON object shaped exactly like the `DATA` blob documented at the top
of `references/extraction.md`. Keep each item's `why` to one line — the digest's value is
compression. Don't compute percentages yourself; the template does that from your statuses (so
the arithmetic can't drift from the counts on screen).

For any `blocked` item, also fill `detail` (what's stalled) and `ask` (the specific approval or
decision that unblocks it). The template collects these into a **"Blockers — awaiting your
decision"** queue at the foot of the page, so this is where you make the roadmap *actionable*
for the human: name the decision they owe, not just the fact that something is stuck.

### 3 — Render

Copy `assets/template.html` to the `out` path and replace the token `__DATA__` with your JSON
model (minified is fine). The template is a complete, dependency-free app: it computes all
rollups, draws the progress ring, lays out all three styles from the `style` field, is
responsive, and adapts to light/dark. You supply data; it supplies chrome and math. Do not add
external scripts, fonts, or stylesheets — the page must open offline from a `file://` path.

When substituting, escape any `</` in the JSON as `<\/` so a stray `</script>` in a roadmap
line can't break out of the data block.

### 4 — Report, don't retouch

Write the file, then tell the user: the path, the headline numbers (e.g. "18 / 29 done, 62%"),
and — importantly — **any contradictions you noticed** between roadmap and reality (an item the
roadmap calls done that has no journal/commit trace, or shipped work absent from the roadmap).
Surfacing drift is the digest's most useful side effect. If the digest ends in a blockers queue,
point them there explicitly — those are the decisions the roadmap can't advance without. Offer to
open it or, if they want, publish it as a shareable artifact — but the file on disk is the deliverable.

## What "rapid human digestion" demands

These are the standards the output is judged against — hold to them over any instinct to be thorough:

- **Fifteen-second read.** Someone should learn the overall state before they finish the first
  breath: the ring and the "X of Y done" headline carry it; everything else is progressive detail.
- **Status is never colour alone.** Every status pairs its colour with an icon and a word
  (✓ done · ◐ in progress · ○ planned · ▲ blocked) — colourblind readers and grayscale prints
  must read the same story. The template already does this; don't defeat it.
- **Compress ruthlessly.** One line of *why* per item, not a paragraph. If the roadmap has 60
  items, group aggressively by phase/theme; a wall of 60 chips is not digestible. Prefer showing
  the shape (how much of each phase is done) over enumerating everything.
- **Truth over polish.** Half-done is `in progress`, not `done`. An item you can't corroborate
  is `planned`, not `done`. The digest earns trust by matching reality, including its ragged edges.
```
