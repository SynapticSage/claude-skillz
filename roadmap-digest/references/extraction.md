# Extraction reference

Read this while doing step 2 (build the model). It defines the exact JSON the template
consumes, the status taxonomy, and how to decide status when the signals disagree.

## The `DATA` object (what you inject for `__DATA__`)

```jsonc
{
  "project": "Acme Pipeline",          // short name for the header
  "generated": "2026-07-22",           // date you ran this (YYYY-MM-DD)
  "style": "dashboard",                // dashboard | narrative | detailed
  "summary": "Foundations shipped; ingestion is in flight, UI not started.",  // 1–2 sentences, present tense

  "phases": [
    {
      "name": "Phase 1 — Foundations",
      "items": [
        { "title": "Schema + migrations", "status": "done",
          "why": "unblocks every downstream service",
          "evidence": "journal 2026-07-03 · commit 6d489a1" },
        { "title": "Auth", "status": "in-progress",
          "why": "OAuth done, RBAC remaining", "evidence": "PR #142 open" }
      ]
    }
  ],

  // OPTIONAL — omit and the template derives sensible versions from the items above:
  "shipped": [ { "title": "Schema + migrations", "when": "2026-07-03", "ref": "6d489a1" } ],
  "next":    [ { "title": "RBAC", "why": "last blocker for Phase 1 signoff" } ],
  "risks":   [ "Vendor API rate limits may cap ingestion throughput" ]
}
```

Rules that keep the output honest and small:

- **Only `project`, `generated`, `style`, and `phases` are required.** If you omit `shipped`,
  the template lists your `done` items (newest first when they carry a date in `evidence`). If
  you omit `next`, it lists `planned`/`in-progress` items in the order you gave them. `risks`
  only renders in `narrative` and `detailed` styles.
- **`why` is one line.** It answers "why does this item matter / what's its state" in a phrase,
  not a paragraph. This is the single biggest lever on digestibility.
- **Do not include counts or percentages.** The template computes `done/total`, per-phase
  progress, and the ring from the statuses. Adding your own numbers only creates a second,
  driftable source of truth.
- **`evidence`** is a short, human-readable trail (a journal date, a commit sha, a PR number),
  not a URL dump. It's what lets a reader trust a "done".
### Blocked items get a full briefing

The template gathers every `blocked` item into an **"▲ Blockers — awaiting your decision"**
section at the **foot of the document** — a human decision queue, placed last on purpose so the
reader absorbs the progress story and then lands on exactly what's needed from them. This is the
one place the digest **trades brevity for depth**: write each blocker so a **programmer who has
never seen this roadmap can get up to speed on it from this section alone** — assume no tribal
knowledge. These fields (all optional; supply as many as apply) build that briefing:

- **`context`** — 1–3 sentences of background: what this feature/area *is*, why it exists, and what
  it connects to. The onboarding hook for someone who doesn't know the domain.
- **`detail`** — what specifically is stalled and the current state (what's built, what isn't).
  Falls back to `why` if omitted. Rendered as "Stalled on …".
- **`options`** — for a *decision* blocker, the paths being weighed. Array of
  `{ "name": "...", "tradeoff": "..." }` (or plain strings). Give the tradeoff, not just the name,
  so the decision-maker sees the shape of the call.
- **`ask`** — the one-line approval/decision that unblocks it ("approve flat vs. inherited roles").
  Rendered as a red **"Needs your call"** callout.
- **`touches`** — array of strings naming the files / modules / services / refs a coder would open
  to work this (`["auth/rbac.py", "migrations/", "PR #142"]`). Rendered as code chips — "where to look".
- **`evidence`** — the corroborating trail (PR, RFC, journal date).

Only `title` + `status` are required; the more briefing fields you fill, the more self-contained
the blocker. A worked example that a stranger to the project could act on:

  ```jsonc
  { "title": "Auth: RBAC roles", "status": "blocked",
    "why": "role model undecided",
    "context": "RBAC gates every API route by user role. It is the last piece before Phase 1 signoff, and downstream services already assume it exists.",
    "detail": "The enforcement middleware is coded behind a feature flag, but the role hierarchy itself is unsettled, so we can't seed real roles or write the migration.",
    "options": [
      { "name": "Flat roles", "tradeoff": "simple to ship and reason about; no inheritance means more per-route grants later" },
      { "name": "Inherited groups", "tradeoff": "models orgs cleanly and scales; more upfront schema and a thornier permission-resolution path" }
    ],
    "ask": "approve flat roles vs. inherited groups for RBAC",
    "touches": ["auth/rbac.py", "auth/middleware.py", "migrations/", "RFC #51", "PR #142"],
    "evidence": "PR #142 open · RFC #51" }
  ```

## Status taxonomy

Exactly four values. The template maps each to an icon + word + colour so status never rides on
colour alone.

| `status` | Icon · word | Use when |
|----------|-------------|----------|
| `done` | ✓ done | The work is complete AND corroborated (journal entry, merged commit, or a checked box you trust). |
| `in-progress` | ◐ in progress | Started but not complete — an open PR, a partial journal entry, "WIP", some sub-tasks checked. |
| `planned` | ○ planned | Intended, not started. This is the **default when you can't corroborate completion.** |
| `blocked` | ▲ blocked | Explicitly stalled on a dependency/decision. Only use when the source says so — don't infer. |

## Inferring status when signals disagree

Roadmaps mix checkboxes, prose, journal entries, and commits, and they contradict each other.
Resolve with this order of trust, and **prefer under-claiming**:

1. **Corroborated completion wins.** A journal entry or merged commit that clearly implements an
   item ⇒ `done`, even if the roadmap still shows `- [ ]`. (Then flag the stale box to the user.)
2. **A checked box with no trace ⇒ be skeptical.** If `- [x]` has no journal/commit backing,
   it's usually still `done` (people check boxes as they go) — but if the surrounding work is
   clearly unfinished, downgrade to `in-progress` and note the uncertainty.
3. **Partial signals ⇒ `in-progress`.** Some sub-items done, an open PR, "WIP"/"started" wording.
4. **Silence ⇒ `planned`.** No evidence of work is not evidence of completion. Default here.
5. **`blocked` is opt-in.** Only when the source explicitly names a blocker.

The guiding bias: **a digest that under-claims progress builds trust; one that over-claims
destroys it.** When torn between `done` and `in-progress`, pick `in-progress`.

## Handling roadmap shapes

- **Checkbox lists** (`- [x]` / `- [ ]`) — the common case. Map directly, then apply the trust
  order above. `- [~]`, `- [/]`, `🚧`, `WIP` conventionally mean in-progress.
- **Phase / milestone headings** — use the headings as `phases`. If the roadmap is a flat list,
  invent 2–4 sensible groupings by theme rather than emitting one giant phase.
- **Tiered / rollout plans** (Tier 1/2/3, Now/Next/Later) — treat tiers as phases; they usually
  already encode priority, so preserve their order for the "next up" derivation.
- **Prose roadmaps** — extract the implied items. Be conservative; don't manufacture items the
  text doesn't support.
- **Huge roadmaps (50+ items)** — don't enumerate everything. Keep every phase, but within a
  phase summarise: list the notable done/in-progress/blocked items and roll the long tail of
  `planned` items into a single "+N more planned" item (give it `status: planned` and put the
  count in its title). Digestibility beats completeness here.
```
