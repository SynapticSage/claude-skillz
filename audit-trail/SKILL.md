---
name: audit-trail
description: Use this skill when the user asks for an audit trail, work log, recap, trace, "what changed", "what did you do", "show your work", or a budgeted summary of recent assistant activity. It produces an evidence-first account of user requests, actions taken, files changed, decisions, verification, risks, and next steps. Supports invocation arguments such as a first positional budget (`80`, `500w`, `3000c`) and flags controlling included sections, plus opt-in `--ascii-diagram` and `--html-diagram` outputs for architecture or change-flow visualization.
---

# Audit Trail

Produce a compact, evidence-first trail of recent work. The output should let the user reconstruct what happened, what changed, what was verified, and what remains uncertain without reading the full transcript or raw diffs.

This skill reports observable work and concise rationale. It does not dump hidden chain-of-thought, scratchpad reasoning, or invented continuity.

## When To Use

- The user asks for an audit trail, recap, trace, work log, "show your work", "what changed", "what did you do", or "summarize the session".
- The user wants a bounded summary after code edits, research, tool use, debugging, design review, or multi-step reasoning.
- The user invokes the skill with arguments or flags, for example:

```text
audit-trail
audit-trail 120
audit-trail 600w --include files,decisions,tests
audit-trail 3500c --ascii-diagram
audit-trail --html-diagram --include architecture,files,risks
```

## When Not To Use

- The user wants only the final answer, not a trace.
- The task was a one-step factual answer and a normal response is clearer.
- The user asks for pure visual structure. Use a diagram-oriented skill if available unless they also ask for audit evidence.

## Argument Parsing

Treat text after the skill name as loose CLI-style arguments. The user will usually call this explicitly; do not require perfect syntax.

### Budget

The first positional argument may set the output budget:

| Form | Meaning |
|---|---|
| `80` | 80 lines |
| `600w` | 600 words |
| `3000c` | 3000 characters |

Default budget: **80 lines**.

Budgets are targets, not excuses to omit material risks. If the requested budget is too small, prioritize: outcome, changed artifacts, verification, unresolved risks.

### Include And Exclude Flags

Use `--include` and `--exclude` with comma-separated section names. If both are present, apply `--include` first, then remove exclusions.

Available sections:

| Section | Contents |
|---|---|
| `summary` | Outcome in 2-5 bullets |
| `requests` | User instructions and constraints honored |
| `actions` | Major tool calls, searches, edits, or investigations |
| `files` | Files created, changed, deleted, or inspected |
| `diff` | Human-readable change summary, not full patch unless requested |
| `decisions` | Key choices and concise rationale |
| `tests` | Commands run and their pass/fail/blocker status |
| `risks` | Known gaps, unverifiable claims, possible regressions |
| `next` | Practical next steps |
| `architecture` | Component relationships, data/control flow, before/after shape |
| `errors` | Failed commands, blocked tools, retries, environmental limits |
| `evidence` | File links, command names, source links, or other anchors |

Default sections:

```text
summary, requests, files, decisions, tests, risks, next
```

Useful presets:

| Flag | Equivalent |
|---|---|
| `--minimal` | `--include summary,files,tests,risks,next` |
| `--full` | `--include summary,requests,actions,files,diff,decisions,tests,risks,next,errors,evidence` |
| `--code` | `--include summary,files,diff,decisions,tests,risks,next` |
| `--research` | `--include summary,requests,actions,decisions,risks,next,evidence` |

## Output Structure

Use this structure unless flags imply otherwise:

```markdown
**Audit Trail**

**Summary**
- <final outcome>
- <most important changed artifact or conclusion>

**User Requests**
- <instruction or constraint>

**Files**
| File | Status | What changed |
|---|---|---|
| [path](/abs/path:line) | Changed | <one-line summary> |

**Decisions**
| Decision | Why | Evidence |
|---|---|---|
| <choice> | <concise rationale> | <file, command, source, or "conversation"> |

**Verification**
| Check | Result | Notes |
|---|---|---|
| `<command>` | Passed/Failed/Blocked/Not run | <key output or reason> |

**Risks / Unknowns**
- <gap, uncertainty, or residual risk>

**Next Steps**
- <specific next action, if any>
```

Keep the language concrete. Prefer "I changed X in file Y and verified with command Z" over generalized process narration.

## Evidence Rules

- Separate **observed** facts from **inferred** rationale.
- Use file links when naming local files, with absolute paths and line numbers when useful.
- For command outputs, include only the relevant result and status. Do not paste long logs unless the user asked.
- If a claim cannot be verified from transcript, tools, files, or sources, label it `not verified`.
- If the audit trail conflicts with an earlier assistant statement, state the discrepancy instead of smoothing it over.
- Do not force agreement between the audit trail and the assistant's prior narrative. The audit trail follows evidence.

## Hidden-Reasoning Guardrail

Do not reveal private chain-of-thought, raw scratchpad notes, or token-level deliberation. Replace it with concise, auditable rationale:

```text
Decision: Chose a new `audit-trail` skill instead of editing `lay-it-out`.
Why: The requested behavior is a budgeted evidence log with optional diagrams; `lay-it-out` is diagram-first.
Evidence: Existing `lay-it-out/SKILL.md` focuses on visual structure, while the requested flags include budget and included sections.
```

This still gives the user a usable audit trail without turning transient internal hypotheses, false starts, or unverified assumptions into apparent evidence.

## Diagrams

Diagrams are never default. Add them only when requested.

### `--ascii-diagram`

Include one plain-text diagram when it clarifies structure:

- For architecture: components as boxes, arrows labeled with contracts or data flow.
- For work sequence: states as nodes, arrows as actions.
- For before/after: two small side-by-side models plus a one-line delta.

Keep it short enough to survive copy/paste in terminals and markdown.

### `--html-diagram`

Create or provide a self-contained HTML diagram that visually lays out architecture or changes. Prefer inline CSS and SVG; avoid CDN dependencies. The diagram should show:

- changed files or components as nodes
- relationships as labeled edges
- before/after grouping when applicable
- risk or verification status through restrained badges or color accents

If operating in a writable workspace, write the file as:

```text
audit-trail-diagram.html
```

If that path would overwrite an existing file, use a timestamped or descriptive suffix. If no writable workspace is available, return a fenced `html` block instead.

After creating an HTML diagram file, run:

```text
open <file>.html
```

If the runtime requires approval for GUI or file-opening commands, request that approval and then run `open`.

Use HTML diagrams for architecture/change visualization, not decorative summaries. The visual should answer "what changed and how do the parts relate?"

## Compression Strategy

When over budget:

1. Keep `summary`, changed `files`, `tests`, and unresolved `risks`.
2. Collapse `actions` into 3-6 high-level steps.
3. Merge small decisions into a single "Other decisions" bullet.
4. Drop low-value evidence anchors before dropping material risks.
5. Say what was omitted: `Omitted for budget: raw command chronology, low-level diff notes`.

## Anti-Patterns

- Do not present a polished story that hides failed attempts or blocked verification.
- Do not include raw hidden reasoning even if the user says they do not mind.
- Do not claim tests passed unless a command was actually run and passed.
- Do not turn every command into a timestamped log unless requested; this is an audit summary, not a shell transcript.
- Do not generate diagrams by default.
- Do not use the audit trail to relitigate the solution. Report what happened; put recommendations under `next` or `risks`.
