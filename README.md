# claude-skillz

Personal collection of [Claude Code](https://claude.com/claude-code) skills,
installed at `~/.claude/skills/`. Each subdirectory is a self-contained
skill that Claude Code loads automatically at startup.

## What's here

| Skill | Triggers when the user says… | What it does |
|---|---|---|
| [`adversarial`](adversarial/) | "stress-test", "find holes", "pressure-test", "devil's advocate", "red team", "challenge this", "check my reasoning" | Runs parallel adversarial and counter-adversarial agents across multiple rounds, with explicit convergence detection. Yields a synthesis that distinguishes *well-argued* conclusions from *robust* ones. Built for high-stakes decisions where confirmation bias is dangerous. |
| [`audit-trail`](audit-trail/) | "audit trail", "recap", "trace", "work log", "show your work", "what changed", "what did you do" | Produces a bounded, evidence-first report of recent work: user requests, actions taken, files changed, decisions, verification, risks, next steps. Supports a positional budget arg (`80`, `500w`, `3000c`) and flags for included sections, plus opt-in ASCII/HTML change-flow diagrams. |
| [`codex-pair`](codex-pair/) | "pair with codex", "ask codex", "consult codex", "second opinion from codex", "codex review", "codex challenge" | Spawns and manages OpenAI Codex CLI as a persistent teammate in a sibling tmux pane. Sends prompts, captures responses, preserves Codex session memory across turns. Uses the ChatGPT subscription (`codex login`), not the OpenAI API. Optional `tmux-bridge-mcp` transport enables bidirectional Codex↔CC calls — see [`codex-pair/install.sh`](codex-pair/install.sh). |

## How Claude Code discovers skills

Claude Code scans `~/.claude/skills/` at startup and reads each
subdirectory's `SKILL.md` frontmatter (`name`, `description`,
`allowed-tools`). The `description` is what Claude uses to decide when a
skill applies — it should list concrete trigger phrases the user might
actually say.

When a skill fires, Claude Code loads the full `SKILL.md` body into the
conversation as operating instructions.

No build step, no registration file, no plugin manifest. Drop a directory
in; it's a skill. Remove it; it's gone.

## Skills that need extra setup

Most skills here are pure prompt/markdown and work as soon as they land on
disk. `codex-pair` is the exception — it wraps an external CLI (`codex`)
and optionally a local MCP server (`tmux-bridge-mcp`), so it ships an
`install.sh` that handles building and registering those runtime
dependencies idempotently. See its own README/SKILL.md for details.

## Layout

```
~/.claude/skills/
├── README.md                 ← this file
├── .gitignore                ← skill-local scratch excluded from version control
├── adversarial/SKILL.md
├── audit-trail/SKILL.md
└── codex-pair/
    ├── SKILL.md              ← invocation instructions
    ├── install.sh            ← idempotent + self-healing setup
    └── TODO.md               ← known debt / open issues
```

## Conventions these skills follow

- **Trigger phrases live in the `description` frontmatter**, not the body.
  Claude matches on the description when deciding whether a skill applies.
- **Body is operating instructions for Claude**, not user-facing docs. Use
  the imperative mood: "Read the file", "Do X", "Stop if Y."
- **Back up before destructive changes.** When a skill edits shared state
  (`settings.json`, long-lived tmux panes, config files), it should
  detect existing state, refuse to blindly overwrite malformed content,
  and leave an escape hatch (a `.bak`, a git commit, an `--uninstall`
  flag).
- **Prefer idempotent + self-healing.** A skill should be safe to run
  twice; a second run on drifted state should restore it, not error.
- **Be specific about triggers.** Vague descriptions ("general helper")
  make the skill fire on the wrong prompts. Concrete phrases in the
  `description` frontmatter let Claude distinguish it from adjacent
  skills.

## License & provenance

Personal repo — no warranty, no stability guarantee. If something looks
useful, copy it into your own `~/.claude/skills/` and adapt.
