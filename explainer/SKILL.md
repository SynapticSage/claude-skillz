---
name: explainer
description: >
  Turn a technical decision, finding, bug, investigation, or design debate into a
  published HTML explainer artifact pitched at a named reading level. Use this whenever
  the user says "write this up", "write it up for the team", "explain this in detail",
  "make a document/page explaining X", "explainer", "brief the team on what we found",
  "document why we rejected Y", or names an audience — "at an undergraduate level", "for
  someone who doesn't know this area", "for the execs", "for a peer who knows this cold".
  Reach for it even when the user never says "artifact" or "HTML": if the ask is to
  explain something just figured out, to an audience, this is the skill. Not for API
  reference docs or a README — an explainer argues a case and ends in a decision.
---

# Explainer

Produce one self-contained page that walks a named reader from *what is this thing* to
*here is what you must now decide*. It is an argument, not a summary.

## 1. Reading level is a parameter

The invocation names the reader — undergraduate, peer, executive, newcomer. If it
doesn't, ask once, then proceed.

Reading level changes exactly two things: **vocabulary** and **the density of inline
definitions**. It never changes technical depth. Detail and accessibility are orthogonal — a
page can define "idempotent" in a six-word clause and still carry the whole proof. Define each
term of art *in the clause where it first appears*, not in a glossary the reader must leave the
argument to visit. Target: zero unexplained jargon, zero lost precision.

- **undergraduate / newcomer** — define terms inline; name the general concept behind
  each specific ("a byte offset — the index of a character counted from the file's start").
- **peer / expert** — assume the vocabulary; spend the words you saved on evidence and edge cases.
- **executive** — same facts, but lead each section with the consequence and put the mechanism second.

## 2. Verify the load-bearing facts before writing a line of the page

Re-derive every number, offset, line reference, and quoted claim from the source with a
tool: read the file, run the snippet, recompute the arithmetic. Never restate a figure
from a summary, a ticket, or your own earlier message — summaries are precisely where
errors get laundered into facts.

This is not polish. **An explainer inherits the standard of evidence it preaches.** If the
thesis is "a claim nobody executed is not trustworthy," shipping it with unchecked
arithmetic refutes it in its own voice. Budget real time here; this step is most of why the
document deserves to exist. If a fact resists verification, mark it unverified in the page
rather than smoothing it over — a visible hole is a contribution, a confident guess is a
liability.

## 3. Show the proof; don't assert it

Find the one claim the document rests on and build the thing that makes it self-evident:
run the proposed rule against the known-correct answer and let the reader watch it reject
it; lay the two intervals side by side; render the contradiction. A reader who *sees* the
failure doesn't have to take your word for it. Spend this effort on the crux only —
elsewhere, prose is fine.

## 4. Let the subject supply its own instrument

The highest-leverage design decision isn't a color or a layout, and it's yours rather than
`artifact-design`'s because it falls out of the content, not the aesthetics: **choose the
diagram the subject itself implies.**

Ask what geometry the argument actually lives in. Intervals over a string want a
character-offset ruler. A race condition wants a two-lane timeline. A protocol
disagreement wants a state machine. A regression wants the same call graph before and
after. A cost argument wants a ledger. Build that instrument once, to scale, from the real
data — then land every later point on it, so the reader learns one picture instead of five.

Reaching for a generic grid of summary cards is the tell that this step got skipped.

## 5. The spine

This order works because it earns the reader's trust before it spends it.

1. **What this is and why it exists** — one paragraph, assuming nothing.
2. **What's broken** — the specific defect, not a vague concern.
3. **Why being wrong is expensive** — and *asymmetric*: price the false positive and the
   false negative separately. They're rarely equal, and which one dominates is usually the
   real argument.
4. **The claim as its author meant it** — stated fairly, at its strongest, in terms its
   author would endorse. You're about to break it; break the real one.
5. **The test that was run** — what you actually executed, reproducibly.
6. **What broke** — enumerated, each with its evidence.
7. **What survived** — see §6.
8. **The fix** — concrete, and honest about what it doesn't fix.
9. **What the reader must now decide** — see §7.

## 6. Steelman, then say what you kept

"What survived" is the section that makes the document trustworthy, and the first one cut
for length. A demolition with no survivors reads as a hit piece — it signals the author went
hunting for a verdict, which invites the reader to discount all of it, including the parts
that are right. Name what you're keeping from the broken idea, and why. If nothing
survived, say so explicitly and show what you looked for; that's a claim, and it's a
different claim from silence.

## 7. End in a decision

Close with what the reader must choose, who chooses it, and what stays blocked until they
do. An explainer that ends in admiration of its own analysis has failed — the reader closes
the tab with nothing to do. If the decision is already made, say what it forecloses.

## Building and publishing

**Load the `artifact-design` skill before writing any markup.** It owns palette, type,
layout, theming, and how not to look machine-generated — it is better at that than anything
restated here, and a copy would silently drift out of sync with it. Write the page content
to a file, then publish with the `Artifact` tool; its own description covers its mechanics
(page skeleton, inlined assets, favicon, light/dark) — follow it there, not a stale echo here.

## Anti-patterns

- **Numbers copied from a summary** — the fastest route to a confidently published falsehood (§2).
- **A wall of prose where a diagram would settle it** — if three paragraphs are doing what one
  picture proves, build the picture (§3, §4).
- **A generic card grid** — what you produce when you never asked what shape the subject is (§4).
- **A demolition with no survivors** — reads as motivated reasoning; forfeits the trust the
  evidence earned (§6).
- **Ending without a decision** (§7).
- **Dumbing down instead of defining** — cutting the hard part isn't accessibility, it's just a
  shorter document that helps nobody (§1).
