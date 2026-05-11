#!/usr/bin/env bash
# install.sh — wire up the /codex skill's runtime dependencies.
#
# What this does:
#   1. Verify codex CLI, tmux, node, npm are present.
#   2. Build tmux-bridge-mcp (npm install + npm run build) — the MCP server
#      that lets CC and Codex read/write each other's panes.
#   3. Register the MCP server in Claude Code's settings (project-local by
#      default; pass --global to write ~/.claude/settings.json instead).
#   4. Register the MCP server in ~/.codex/config.toml.
#
# Flags:
#   --skip-build            skip npm install + build (use if already built)
#   --skip-register-cc      don't touch Claude Code settings
#   --skip-register-codex   don't touch Codex config
#   --skip-agents           don't inject the bridge contract into ~/.codex/AGENTS.md
#   --skip-patches          don't verify/re-apply local hardening to bridge src
#   --no-auto-clone         exit with instructions if bridge clone missing,
#                           instead of auto-cloning from GitHub
#   --global                write CC's mcpServers entry to ~/.claude/settings.json
#                           instead of the repo-local .claude/settings.local.json
#   --bridge-path PATH      explicit path to tmux-bridge-mcp clone
#                           (default: <script>/../../../repos/tmux-bridge-mcp)
#   --uninstall             remove MCP registrations (does not delete the bridge
#                           clone or npm artifacts)
#   --dry-run               print what would happen, make no changes
#
# Idempotent + self-healing:
#   - Re-running only adds missing pieces (noop if already wired).
#   - Verifies codex auth (~/.codex/auth.json) exists before building.
#   - Auto-clones the bridge if missing (disable with --no-auto-clone).
#   - Re-applies local hardening patches to the bridge src every run, so a
#     `git pull` on the bridge never leaves you running unpatched code.
#   - Neuters bridge.applyDefaults() so the bridge startup doesn't flip
#     your tmux server's global mouse/history/mode-keys options.
#   - Refuses to overwrite a malformed CC settings file (fails loud).

set -euo pipefail

# --- Parse flags ----------------------------------------------------------

SKIP_BUILD=0
SKIP_CC=0
SKIP_CODEX=0
SKIP_AGENTS=0
SKIP_PATCHES=0
GLOBAL_CC=0
UNINSTALL=0
DRY_RUN=0
AUTO_CLONE=1
BRIDGE_PATH=""
BRIDGE_REPO="https://github.com/howardpen9/tmux-bridge-mcp.git"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)          SKIP_BUILD=1; shift ;;
    --skip-register-cc)    SKIP_CC=1; shift ;;
    --skip-register-codex) SKIP_CODEX=1; shift ;;
    --skip-agents)         SKIP_AGENTS=1; shift ;;
    --skip-patches)        SKIP_PATCHES=1; shift ;;
    --no-auto-clone)       AUTO_CLONE=0; shift ;;
    --global)              GLOBAL_CC=1; shift ;;
    --bridge-path)         BRIDGE_PATH="$2"; shift 2 ;;
    --uninstall)           UNINSTALL=1; shift ;;
    --dry-run)             DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

# --- Resolve paths --------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the bridge location. The skill supports two canonical install
# layouts, checked in order:
#   1. <skill-dir>/vendor/tmux-bridge-mcp/   — vendored alongside the skill
#      (recommended once you've promoted the skill to ~/.claude/skills/).
#   2. <skill-dir>/../../../repos/tmux-bridge-mcp/  — dev layout for when
#      the skill still lives inside tmux-manage/.claude/skills/.
# If neither exists and --no-auto-clone wasn't set, auto-clone target is (1).
# Users can always override with --bridge-path.
if [[ -z "$BRIDGE_PATH" ]]; then
  CANDIDATE_VENDOR="$SCRIPT_DIR/vendor/tmux-bridge-mcp"
  CANDIDATE_DEV="$SCRIPT_DIR/../../../repos/tmux-bridge-mcp"
  if [[ -d "$CANDIDATE_VENDOR" ]]; then
    BRIDGE_PATH="$CANDIDATE_VENDOR"
  elif [[ -d "$CANDIDATE_DEV" ]]; then
    BRIDGE_PATH="$CANDIDATE_DEV"
  else
    # Neither exists — default to the vendor location so auto-clone lands
    # it inside the skill directory (portable across machines).
    BRIDGE_PATH="$CANDIDATE_VENDOR"
  fi
fi

# Canonicalize (if dir exists)
if [[ -d "$BRIDGE_PATH" ]]; then
  BRIDGE_PATH="$(cd "$BRIDGE_PATH" && pwd)"
fi

BRIDGE_ENTRY="$BRIDGE_PATH/dist/index.js"

# CC scope for `claude mcp add`. CC's MCP registry lives in
# ~/.claude.json (NOT settings.json — settings.json is for permissions
# and hooks; MCP servers are a separate concern). The `claude mcp`
# subcommand is the supported way to mutate it; we use it instead of
# editing the JSON directly because (a) the file also caches CLI state
# we shouldn't risk corrupting, and (b) the scoping rules (local vs
# user vs project) are enforced consistently by the CLI.
#   --global → "user" scope (~/.claude.json `mcpServers` global key)
#   default  → "local" scope (~/.claude.json `projects.<cwd>.mcpServers`)
# `local` is keyed on the current working directory at registration
# time, so it's important install.sh is run from inside the target
# project. Credit: discovered live 2026-04-26 — earlier install.sh
# wrote to .claude/settings.local.json's `mcpServers`, which CC
# silently ignores.
if [[ $GLOBAL_CC -eq 1 ]]; then
  CC_SCOPE="user"
else
  CC_SCOPE="local"
fi
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

CODEX_CONFIG="$HOME/.codex/config.toml"

# --- Helpers --------------------------------------------------------------

say() { printf '%s\n' "$*"; }
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

require_cmd() {
  local name="$1" install_hint="${2:-}"
  if ! command -v "$name" >/dev/null 2>&1; then
    say "MISSING: $name"
    [[ -n "$install_hint" ]] && say "  $install_hint"
    return 1
  fi
}

# --- Uninstall path (exits early) -----------------------------------------

if [[ $UNINSTALL -eq 1 ]]; then
  say "=== Uninstalling tmux-bridge from MCP configs ==="

  if [[ $SKIP_CC -eq 0 ]]; then
    say "Removing tmux-bridge from Claude Code (scope=$CC_SCOPE)"
    if command -v claude >/dev/null 2>&1; then
      run claude mcp remove -s "$CC_SCOPE" tmux-bridge || say "  (not present)"
    else
      say "  WARNING: 'claude' CLI not found; cannot uninstall MCP entry."
    fi
  fi

  if [[ $SKIP_CODEX -eq 0 && -f "$CODEX_CONFIG" ]]; then
    say "Removing from $CODEX_CONFIG"
    run python3 - "$CODEX_CONFIG" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as f: content = f.read()
# Match [mcp_servers.tmux-bridge] section up to next REAL section
# header or EOF. A real header starts with `[` followed by a letter or
# underscore (e.g. [projects."..."], [tui.foo], [plugins."..."]). The
# `[^\[]*` form was wrong: `args = ["..."]` contains `[`, which
# terminated the match early and left orphan array literals on
# subsequent lines for re-runs to compound.
pattern = re.compile(
    r"\n*^\[mcp_servers\.tmux-bridge\].*?(?=^\[[A-Za-z_]|\Z)",
    re.MULTILINE | re.DOTALL,
)
new_content, n = pattern.subn("\n", content, count=1)
if n:
    with open(path, "w") as f: f.write(new_content.rstrip() + "\n")
    print("  removed [mcp_servers.tmux-bridge] section")
else:
    print("  (not present)")
PY
  fi

  if [[ $SKIP_AGENTS -eq 0 ]]; then
    AGENTS_FILE="$HOME/.codex/AGENTS.md"
    if [[ -f "$AGENTS_FILE" ]]; then
      say "Removing managed section from $AGENTS_FILE"
      run python3 - "$AGENTS_FILE" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as f: content = f.read()
begin = "<!-- codex-pair:begin"
end = "<!-- codex-pair:end -->"
# Match from begin marker (anchored with the prefix above; user may have
# changed the trailing parenthetical in the marker line, so don't pin
# the whole opener) through the end marker. DOTALL so `.` matches newlines.
pat = re.compile(
    re.escape(begin) + r".*?" + re.escape(end) + r"\n?",
    re.DOTALL,
)
new, n = pat.subn("", content, count=1)
if n:
    new = new.rstrip() + "\n" if new.strip() else ""
    with open(path, "w") as f: f.write(new)
    print(f"  removed managed section from {path}")
else:
    print("  (no managed section present)")
PY
    fi
  fi

  say "Done. Bridge clone at $BRIDGE_PATH was NOT deleted."
  exit 0
fi

# --- Preflight ------------------------------------------------------------

say "=== Preflight ==="
FAIL=0
require_cmd codex "Install: npm install -g @openai/codex && codex login" || FAIL=1
require_cmd tmux "Install: brew install tmux" || FAIL=1
require_cmd node "Install: brew install node" || FAIL=1
require_cmd npm  "(comes with node)" || FAIL=1
require_cmd python3 "(preinstalled on macOS)" || FAIL=1
require_cmd git  "Install: brew install git" || FAIL=1

# Codex login state — the auth token lives at ~/.codex/auth.json.
# If it's missing, Codex is installed but not authenticated, and the pane
# will fail at first use. Catch it now instead of at runtime.
if ! [[ -s "$HOME/.codex/auth.json" ]]; then
  say "MISSING: codex auth (no $HOME/.codex/auth.json)"
  say "  Run: codex login"
  FAIL=1
fi

# Bridge clone — auto-clone by default (E: self-healing for missing clone).
if [[ ! -d "$BRIDGE_PATH" ]]; then
  if [[ $AUTO_CLONE -eq 1 ]]; then
    say "Bridge clone missing. Auto-cloning $BRIDGE_REPO"
    say "  → $BRIDGE_PATH"
    if [[ $DRY_RUN -eq 0 ]]; then
      mkdir -p "$(dirname "$BRIDGE_PATH")"
      # Don't suppress git's stderr — if the clone fails, the user needs
      # to see the actual error (auth, network, disk full, etc.). A bare
      # "CLONE FAILED" with no diagnosis is useless. Credit: Codex review
      # 2026-04-24 Part C #4 / LOW.
      if git clone --depth 1 "$BRIDGE_REPO" "$BRIDGE_PATH"; then
        BRIDGE_PATH="$(cd "$BRIDGE_PATH" && pwd)"
        BRIDGE_ENTRY="$BRIDGE_PATH/dist/index.js"
        say "  cloned"
      else
        say "  CLONE FAILED (see git error above)"
        FAIL=1
      fi
    else
      say "  [dry-run] would clone"
    fi
  else
    say "MISSING: tmux-bridge-mcp clone at $BRIDGE_PATH"
    say "  Re-run without --no-auto-clone, or clone manually:"
    say "    git clone --depth 1 $BRIDGE_REPO $BRIDGE_PATH"
    FAIL=1
  fi
fi

[[ $FAIL -eq 0 ]] || { say ""; say "Fix the above, then re-run."; exit 1; }
say "OK"; say ""

# --- Local patches (B + E: self-healing hardening) ------------------------
# These patches are our local hardening — if a future `git pull` on the
# bridge reverts them, this block restores them before the build.

if [[ $SKIP_PATCHES -eq 0 && -d "$BRIDGE_PATH" ]]; then
  say "=== Applying local hardening patches ==="

  if [[ $DRY_RUN -eq 1 ]]; then
    say "  [dry-run] would verify + re-apply Zod .max() hardening, B-trim tool descriptions (Tier 1 token-opt), and neuter applyDefaults()"
  else
    python3 - "$BRIDGE_PATH/src/index.ts" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
orig = content
applied = []

# Patch B1: tmux_type text .max(10000)
if 'text: z.string().describe("Text to type into the pane")' in content:
    content = content.replace(
        'text: z.string().describe("Text to type into the pane")',
        'text: z.string().max(10000).describe("Text to type into the pane (max 10000 chars)")',
    )
    applied.append("tmux_type text.max(10000)")

# Patch B2: tmux_message text .max(10000)
if 'text: z.string().describe("Message to send")' in content:
    content = content.replace(
        'text: z.string().describe("Message to send")',
        'text: z.string().max(10000).describe("Message to send (max 10000 chars)")',
    )
    applied.append("tmux_message text.max(10000)")

# Patch B3: tmux_read lines .int().positive().max(1000). Multi-line match
# of the UNPATCHED form — no match means already patched (or upstream
# changed shape), no-op either way.
read_pat = re.compile(
    r'lines: z\s*\n\s*\.number\(\)\s*\n\s*\.optional\(\)\s*\n\s*\.default\(50\)\s*\n\s*\.describe\("Number of lines to read \(default 50\)"\)',
)
if read_pat.search(content):
    content = read_pat.sub(
        'lines: z\n      .number()\n      .int()\n      .positive()\n      .max(1000)\n      .optional()\n      .default(50)\n      .describe("Number of lines to read (default 50, max 1000)")',
        content,
    )
    applied.append("tmux_read lines.max(1000)")

# Patch E: neuter bridge.applyDefaults(). Match uncommented form only so
# re-runs don't double-comment. Use [^\n]* instead of [^)]* because the
# catch body contains paren pairs (() => {}), which [^)]* can't span.
ap_pat = re.compile(
    r'^(\s+)(bridge\.applyDefaults\(\)[^\n]*;)\s*$',
    re.MULTILINE,
)
m = ap_pat.search(content)
if m:
    content = (content[:m.start()] + m.group(1) + "// " + m.group(2)
               + " // disabled by install.sh — user owns tmux config"
               + content[m.end():])
    applied.append("applyDefaults() neutered")

# --- Pass 2: B-trim (token-optimization Tier 1) ---
# Compresses tool descriptions and drops redundant param `.describe()`
# strings. Pass 1 (above) already added Zod constraints; Pass 2 strips
# the verbose .describe() text and shortens tool descriptions while
# keeping operational hints (Read first / no Enter / cannot target self).
# Source of truth: codex-pair/TOKEN_OPTIMIZATION_RESEARCH.md (Codex GO).
# Each replace pair: (post-pass-1 form) -> (B-trimmed final form).
btrim = [
    # tmux_read — tool desc + param describes (lines schema is Pass-1 hardened)
    (
        '"Read the last N lines from a tmux pane. Must be called before type/keys (read guard). Target can be a pane ID (%N), session:window.pane, or a label."',
        '"Read recent lines from a tmux pane. Required before type/keys/message (read guard)."',
    ),
    (
        '.describe("Number of lines to read (default 50, max 1000)")',
        '',
    ),
    # tmux_type — tool desc + drop param describes (text already has .max from Pass 1)
    (
        '"Type text into a tmux pane WITHOUT pressing Enter. You must tmux_read the pane first (read guard enforced). After typing, use tmux_read to verify, then tmux_keys to press Enter."',
        '"Type text into a pane WITHOUT pressing Enter. Read first (guard); verify with another read, then tmux_keys for Enter."',
    ),
    (
        '''    target: z.string().describe("Pane target: ID (%0), session:win.pane, or label"),
    text: z.string().max(10000).describe("Text to type into the pane (max 10000 chars)"),''',
        '''    target: z.string(),
    text: z.string().max(10000),''',
    ),
    # tmux_message — tool desc + drop param describes (text already has .max)
    (
        '"Send a message to another agent\'s pane with auto-prepended sender info, reply target, and correlation ID. Cannot message your own pane (loop prevention). Must tmux_read first."',
        '"Send a message to another pane (auto-adds sender + reply tag). Cannot target self (loop prevention). Read first."',
    ),
    (
        '''    target: z.string().describe("Pane target: ID (%0), session:win.pane, or label"),
    text: z.string().max(10000).describe("Message to send (max 10000 chars)"),''',
        '''    target: z.string(),
    text: z.string().max(10000),''',
    ),
    # tmux_keys — tool desc + drop param describes
    (
        '"Send special keys to a tmux pane (Enter, Escape, C-c, etc.). Must tmux_read first."',
        '"Send special keys to a pane (Enter, Escape, C-c). Read first."',
    ),
    (
        '''    target: z.string().describe("Pane target: ID (%0), session:win.pane, or label"),
    keys: z
      .array(z.string())
      .describe('Keys to send, e.g. ["Enter"], ["Escape"], ["C-c"]'),''',
        '''    target: z.string(),
    keys: z.array(z.string()),''',
    ),
    # tmux_name — tool desc + drop param describes
    (
        '"Label a tmux pane for easy addressing (e.g., \'gemini\', \'claude\'). The label appears in the tmux border."',
        '"Label a pane (e.g. \'gemini\', \'claude\'). Appears in pane border."',
    ),
    (
        '''    target: z.string().describe("Pane target: ID (%0) or session:win.pane"),
    label: z.string().describe("Label to assign"),''',
        '''    target: z.string(),
    label: z.string(),''',
    ),
    # tmux_resolve — drop param describe (tool desc is already short)
    (
        '    label: z.string().describe("Label to resolve"),',
        '    label: z.string(),',
    ),
    # tmux_id — tool desc only
    (
        '"Print the current pane\'s tmux ID ($TMUX_PANE). Useful for self-identification when labeling."',
        '"Return current pane\'s tmux ID."',
    ),
    # tmux_doctor — tool desc only
    (
        '"Diagnose tmux connectivity issues — checks socket, env vars, and pane visibility"',
        '"Diagnose tmux connectivity (socket, env, panes)."',
    ),
]

for old, new in btrim:
    if old in content:
        content = content.replace(old, new, 1)
        # Tag the applied change by what it shortened. Use a stable label.
        label = old[:40].replace('"', '').strip().split('.')[0][:30]
        applied.append(f"btrim: {label}...")

if content != orig:
    with open(path, "w") as f: f.write(content)
    for name in applied:
        print(f"  applied: {name}")
else:
    # Report what's already present so re-runs are informative
    present = []
    if '.max(10000).describe("Text to type' in content: present.append("tmux_type-hardened")
    if '.max(10000).describe("Message to send' in content: present.append("tmux_message-hardened")
    if '.max(1000)' in content and 'Number of lines to read' in content: present.append("tmux_read-hardened")
    if 'text: z.string().max(10000),\n' in content: present.append("tmux_type-btrimmed")
    if 'Read recent lines from a tmux pane' in content: present.append("tmux_read-btrimmed")
    if 'Type text into a pane WITHOUT pressing Enter' in content: present.append("tmux_type-btrimmed")
    if 'Send a message to another pane (auto-adds' in content: present.append("tmux_message-btrimmed")
    if 'Send special keys to a pane (Enter, Escape' in content: present.append("tmux_keys-btrimmed")
    if "Label a pane (e.g. 'gemini'" in content: present.append("tmux_name-btrimmed")
    if "Return current pane's tmux ID" in content: present.append("tmux_id-btrimmed")
    if 'Diagnose tmux connectivity (socket' in content: present.append("tmux_doctor-btrimmed")
    if '// bridge.applyDefaults()' in content: present.append("applyDefaults-neutered")
    print(f"  (no drift; hardening intact: {', '.join(present) if present else 'NONE'})")
PY
  fi

  # --- format-patch: getSelfContext recovery (Bridge-A + Bridge-B) ---
  # This is a real git commit on a fork branch (fix-self-context),
  # exported as a unified diff and applied here. Lives until the
  # upstream PR merges; cleanup trigger documented in TODO.md.
  # See plan: ~/.claude/plans/refactored-discovering-unicorn.md
  PATCH_FILE="$SCRIPT_DIR/patches/0001-fix-self-context.patch"
  if [[ -f "$PATCH_FILE" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      say "  [dry-run] would dry-run + apply $PATCH_FILE to $BRIDGE_PATH"
    else
      # Three outcomes from `patch -p1 --dry-run`:
      #   exit 0:        all hunks apply cleanly; do it for real.
      #   "Reversed (or previously applied) patch detected":
      #                  patch already in (re-run, or upstream merged).
      #                  Skip — don't fail, don't double-apply.
      #   any other failure: hunks don't match → upstream moved underneath us.
      #                  Fail loud so we can revisit the patch, never partially apply.
      DRY_LOG=$(mktemp)
      if (cd "$BRIDGE_PATH" && patch -p1 --dry-run --check < "$PATCH_FILE") >"$DRY_LOG" 2>&1; then
        DRY_RC=0
      else
        DRY_RC=$?
      fi
      DRY_OUT=$(cat "$DRY_LOG")
      rm -f "$DRY_LOG"
      if printf '%s' "$DRY_OUT" | grep -q 'Reversed.*previously applied'; then
        say "  format-patch already applied (skipping)"
      elif [[ $DRY_RC -eq 0 ]]; then
        if (cd "$BRIDGE_PATH" && patch -p1 < "$PATCH_FILE" >/dev/null 2>&1); then
          say "  applied: 0001-fix-self-context.patch (Bridge-A + Bridge-B)"
        else
          say "  ERROR: format-patch dry-run passed but apply failed."
          say "  Inspect: cd $BRIDGE_PATH && patch -p1 < $PATCH_FILE"
          exit 1
        fi
      else
        say "  ERROR: format-patch does not apply cleanly to current bridge tree."
        say "  Upstream likely moved. Revisit $PATCH_FILE."
        say "  patch dry-run output (rc=$DRY_RC):"
        printf '%s\n' "$DRY_OUT" | sed 's/^/    /'
        exit 1
      fi
    fi
  fi
  say ""
else
  say "=== Skipping local patches (--skip-patches) ==="; say ""
fi

# --- Build the bridge -----------------------------------------------------

if [[ $SKIP_BUILD -eq 0 ]]; then
  say "=== Building tmux-bridge-mcp ==="
  say "Path: $BRIDGE_PATH"

  if [[ ! -d "$BRIDGE_PATH" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      say "  [dry-run] would build at $BRIDGE_PATH (after clone completes)"
    else
      say "ERROR: bridge directory $BRIDGE_PATH missing; cannot build"
      exit 1
    fi
  else
    (
      cd "$BRIDGE_PATH"
      # --ignore-scripts blocks postinstall hooks from transitive deps
      run npm install --no-audit --no-fund --ignore-scripts
      run npm run build
    )
    if [[ $DRY_RUN -eq 0 && ! -f "$BRIDGE_ENTRY" ]]; then
      say "BUILD FAILED: expected $BRIDGE_ENTRY but it doesn't exist"
      exit 1
    fi
    say "Built: $BRIDGE_ENTRY"
  fi
  say ""
else
  say "=== Skipping build (--skip-build) ==="
  # Suppress the "doesn't exist" warning in --dry-run, since dry-run may
  # have skipped the clone step too. Only warn when we expected the file
  # to be there. Credit: Codex review 2026-04-24 Part C #2 / MEDIUM.
  if [[ $DRY_RUN -eq 0 && ! -f "$BRIDGE_ENTRY" ]]; then
    say "WARNING: $BRIDGE_ENTRY does not exist. MCP won't start."
  fi
  say ""
fi

# --- Register with Claude Code --------------------------------------------

if [[ $SKIP_CC -eq 0 ]]; then
  say "=== Registering MCP with Claude Code ==="
  say "Scope: $CC_SCOPE  ($([[ $CC_SCOPE == user ]] && echo 'global, ~/.claude.json mcpServers' || echo "project-local for $PROJECT_ROOT"))"

  if ! command -v claude >/dev/null 2>&1; then
    say "ERROR: 'claude' CLI not on PATH; cannot register MCP."
    say "  Install Claude Code first: https://docs.claude.com/claude-code"
    exit 1
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    say "  [dry-run] claude mcp add -s $CC_SCOPE tmux-bridge node $BRIDGE_ENTRY"
  else
    # Idempotency: check current registration. `claude mcp get` prints
    # `Command:` and `Args:` on separate lines (as of Claude Code's
    # current CLI). We extract both and compare to the desired pair to
    # detect drift (e.g. BRIDGE_PATH changed because the user moved
    # the skill, or the format itself changed).
    GET_OUT=$(claude mcp get tmux-bridge 2>/dev/null || true)
    EXIST_CMD=$(printf '%s\n' "$GET_OUT" | sed -n 's/^[[:space:]]*Command:[[:space:]]*//p')
    EXIST_ARGS=$(printf '%s\n' "$GET_OUT" | sed -n 's/^[[:space:]]*Args:[[:space:]]*//p')
    if [[ "$EXIST_CMD" == "node" && "$EXIST_ARGS" == "$BRIDGE_ENTRY" ]]; then
      say "  (already registered, unchanged)"
    else
      # Remove first if present (silent if not), then add. This handles
      # both first-time install and BRIDGE_PATH drift in one path.
      claude mcp remove -s "$CC_SCOPE" tmux-bridge 2>/dev/null || true
      claude mcp add -s "$CC_SCOPE" tmux-bridge node "$BRIDGE_ENTRY"
    fi
  fi
  say ""
else
  say "=== Skipping CC registration (--skip-register-cc) ==="; say ""
fi

# --- Register with Codex --------------------------------------------------

if [[ $SKIP_CODEX -eq 0 ]]; then
  say "=== Registering MCP with Codex ==="
  say "Target: $CODEX_CONFIG"

  if [[ ! -f "$CODEX_CONFIG" ]]; then
    say "  $CODEX_CONFIG does not exist — creating"
    run mkdir -p "$(dirname "$CODEX_CONFIG")"
    [[ $DRY_RUN -eq 0 ]] && : > "$CODEX_CONFIG"
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    say "  [dry-run] would append [mcp_servers.tmux-bridge] section"
  else
    python3 - "$CODEX_CONFIG" "$BRIDGE_ENTRY" <<'PY'
import sys, re
path, entry = sys.argv[1], sys.argv[2]
with open(path) as f: content = f.read()

desired = (
    '[mcp_servers.tmux-bridge]\n'
    'command = "node"\n'
    f'args = ["{entry}"]\n'
)

# If section already present with correct entry, noop. Boundary is the
# next REAL TOML section header — `[` followed by a letter/underscore.
# Naive `[^\[]*` is wrong because `args = ["..."]` contains `[` and
# would terminate the match inside the section, leaving the array tail
# orphaned. Re-runs would then accumulate stale `["..."]` lines after
# each `args = ` rewrite, producing invalid TOML that Codex silently
# fails to load.
pattern = re.compile(
    r"^\[mcp_servers\.tmux-bridge\].*?(?=^\[[A-Za-z_]|\Z)",
    re.MULTILINE | re.DOTALL,
)
m = pattern.search(content)
if m and m.group(0).strip() == desired.strip():
    print("  (already registered, unchanged)")
elif m:
    new_content = content[:m.start()] + desired + content[m.end():]
    with open(path, "w") as f: f.write(new_content)
    print("  updated [mcp_servers.tmux-bridge]")
else:
    # Append, separating from prior content with a blank line
    if content and not content.endswith("\n"): content += "\n"
    if content and not content.endswith("\n\n"): content += "\n"
    with open(path, "w") as f: f.write(content + desired)
    print("  appended [mcp_servers.tmux-bridge]")
PY
  fi
  say ""
else
  say "=== Skipping Codex registration (--skip-register-codex) ==="; say ""
fi

# --- Inject bridge contract into ~/.codex/AGENTS.md (H1) -----------------
# H1 from TOKEN_OPTIMIZATION_RESEARCH.md (Codex round-3 GO). Codex CLI
# loads ~/.codex/AGENTS.md as model-visible system-instruction context
# at TUI startup. Putting the static bridge contract there shrinks the
# per-turn bootstrap preamble (sent on every cold-path /codex-pair turn)
# from ~3,967 chars / ~990 tok down to just the dynamic handshake.
#
# Tradeoff (Codex round-3 wording): the injected section adds ~580
# model-visible tokens to **every Codex turn** that loads the managed
# AGENTS.md section, not just /codex-pair turns. Net positive only if
# /codex-pair cold turns happen >1.6x per Codex non-pair session.
#
# Idempotency: markered injection. <!-- codex-pair:begin --> ... end -->.
# - File missing: create it with just our section.
# - Markers absent: append our section, preserve any pre-existing content.
# - Markers present: replace section content between them, leave user's
#   surrounding edits intact.
#
# Source of truth: $BRIDGE_PATH/system-instruction/smux-skill.md (52
# lines, ~580 tok). Generic bridge contract; pair-specific bits stay
# in the per-turn preamble.

if [[ $SKIP_AGENTS -eq 0 ]]; then
  say "=== Injecting bridge contract into ~/.codex/AGENTS.md ==="

  AGENTS_FILE="$HOME/.codex/AGENTS.md"
  CONTRACT_SOURCE="$BRIDGE_PATH/system-instruction/smux-skill.md"

  if [[ ! -f "$CONTRACT_SOURCE" ]]; then
    say "  WARN: $CONTRACT_SOURCE missing — bridge tree may be incomplete."
    say "  Skipping AGENTS.md injection. Run after the bridge build lands."
  elif [[ $DRY_RUN -eq 1 ]]; then
    say "  [dry-run] would inject ~580 tok bridge contract into $AGENTS_FILE"
    say "  [dry-run] markered: <!-- codex-pair:begin --> ... <!-- codex-pair:end -->"
  else
    run mkdir -p "$(dirname "$AGENTS_FILE")"
    python3 - "$AGENTS_FILE" "$CONTRACT_SOURCE" <<'PY'
import sys, re, os
agents_path, source_path = sys.argv[1], sys.argv[2]

with open(source_path) as f:
    contract = f.read().rstrip() + "\n"

begin = "<!-- codex-pair:begin (managed by ~/.claude/skills/codex-pair/install.sh — do not edit between markers) -->"
end = "<!-- codex-pair:end -->"
section = f"{begin}\n\n{contract}\n{end}\n"

existing = ""
if os.path.exists(agents_path):
    with open(agents_path) as f:
        existing = f.read()

# Match our managed section. Anchor on the STABLE prefix of the begin
# marker, not the full canonical text — that way if a user edits the
# parenthetical (or we change it across versions), we still recognize
# the section and replace in place instead of appending a duplicate.
# Codex round-6 review MEDIUM, 2026-05-10.
managed_re = re.compile(
    r"<!-- codex-pair:begin.*?" + re.escape(end),
    re.DOTALL,
)
m = managed_re.search(existing)

if m:
    # Markers present — replace section content between them.
    if m.group(0).strip() == section.strip():
        print("  (already injected, unchanged)")
    else:
        new_content = existing[:m.start()] + section.rstrip() + existing[m.end():]
        with open(agents_path, "w") as f: f.write(new_content)
        print(f"  updated managed section in {agents_path}")
else:
    # Markers absent — append. Preserve user's preceding content.
    if existing and not existing.endswith("\n"):
        existing += "\n"
    if existing and not existing.endswith("\n\n"):
        existing += "\n"
    with open(agents_path, "w") as f: f.write(existing + section)
    if existing.strip():
        print(f"  appended managed section to {agents_path} (existing user content preserved)")
    else:
        print(f"  created {agents_path} with managed section")
PY
    say ""
    say "  Cost note: this section adds ~580 model-visible tokens to every"
    say "  Codex turn that loads the managed AGENTS.md section, not just"
    say "  /codex-pair turns. Net positive only if codex-pair cold turns"
    say "  happen >1.6x per Codex non-pair session."
    say ""
    say "  IMPORTANT: running Codex sessions don't see edits until TUI"
    say "  restart. If you have an active codex pane, exit it ('codex /exit'"
    say "  or kill the pane) and re-spawn for changes to apply."
  fi
  say ""
else
  say "=== Skipping AGENTS.md injection (--skip-agents) ==="; say ""
fi

# --- Done -----------------------------------------------------------------

say "=== Done ==="
say "Bridge entry:    $BRIDGE_ENTRY"
say "CC MCP scope:    $CC_SCOPE  (verify with: claude mcp get tmux-bridge)"
say "Codex config:    $CODEX_CONFIG"
say ""
say "Restart Claude Code and Codex for the MCP registration to take effect."
say "Then invoke /codex from CC to spawn a Codex pane and verify the link."
