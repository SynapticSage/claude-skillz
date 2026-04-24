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

# CC settings destination
if [[ $GLOBAL_CC -eq 1 ]]; then
  CC_SETTINGS="$HOME/.claude/settings.json"
else
  # Project-local. Resolve from the user's cwd (where install.sh was
  # invoked), NOT from SCRIPT_DIR — once the skill is installed globally
  # at ~/.claude/skills/codex-pair/, SCRIPT_DIR/../../.. resolves to
  # $HOME, which would write to ~/.claude/settings.local.json (a real
  # file, but not the project the caller is in). Credit: Codex review
  # 2026-04-24 Part C #1 / HIGH.
  PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  CC_SETTINGS="$PROJECT_ROOT/.claude/settings.local.json"
fi

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

  if [[ $SKIP_CC -eq 0 && -f "$CC_SETTINGS" ]]; then
    say "Removing from $CC_SETTINGS"
    run python3 - "$CC_SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f: data = json.load(f)
if "mcpServers" in data and "tmux-bridge" in data["mcpServers"]:
    del data["mcpServers"]["tmux-bridge"]
    if not data["mcpServers"]: del data["mcpServers"]
    with open(path, "w") as f:
        json.dump(data, f, indent=2); f.write("\n")
    print("  removed tmux-bridge entry")
else:
    print("  (not present)")
PY
  fi

  if [[ $SKIP_CODEX -eq 0 && -f "$CODEX_CONFIG" ]]; then
    say "Removing from $CODEX_CONFIG"
    run python3 - "$CODEX_CONFIG" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as f: content = f.read()
# Match [mcp_servers.tmux-bridge] section up to next [ or EOF
pattern = re.compile(
    r"\n*\[mcp_servers\.tmux-bridge\][^\[]*", re.MULTILINE
)
new_content, n = pattern.subn("\n", content, count=1)
if n:
    with open(path, "w") as f: f.write(new_content.rstrip() + "\n")
    print("  removed [mcp_servers.tmux-bridge] section")
else:
    print("  (not present)")
PY
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
    say "  [dry-run] would verify + re-apply Zod .max() patches and neuter applyDefaults()"
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

if content != orig:
    with open(path, "w") as f: f.write(content)
    for name in applied:
        print(f"  applied: {name}")
else:
    # Report what's already present so re-runs are informative
    present = []
    if '.max(10000).describe("Text to type' in content: present.append("tmux_type")
    if '.max(10000).describe("Message to send' in content: present.append("tmux_message")
    if '.max(1000)' in content and 'Number of lines to read' in content: present.append("tmux_read")
    if '// bridge.applyDefaults()' in content: present.append("applyDefaults-neutered")
    print(f"  (no drift; hardening intact: {', '.join(present) if present else 'NONE'})")
PY
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
  say "Target: $CC_SETTINGS"

  if [[ $DRY_RUN -eq 1 ]]; then
    say "  [dry-run] would merge mcpServers.tmux-bridge entry"
  else
    mkdir -p "$(dirname "$CC_SETTINGS")"
    python3 - "$CC_SETTINGS" "$BRIDGE_ENTRY" <<'PY'
import json, os, sys
path, entry = sys.argv[1], sys.argv[2]
try:
    with open(path) as f: data = json.load(f)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError as e:
    sys.exit(
        f"ERROR: {path} is not valid JSON ({e}).\n"
        f"Refusing to overwrite — fix the file manually, then re-run install.sh."
    )
data.setdefault("mcpServers", {})
existing = data["mcpServers"].get("tmux-bridge")
new_cfg = {"command": "node", "args": [entry]}
if existing == new_cfg:
    print("  (already registered, unchanged)")
else:
    data["mcpServers"]["tmux-bridge"] = new_cfg
    with open(path, "w") as f:
        json.dump(data, f, indent=2); f.write("\n")
    print("  wrote mcpServers.tmux-bridge")
PY
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

# If section already present with correct entry, noop
pattern = re.compile(r"\[mcp_servers\.tmux-bridge\][^\[]*", re.MULTILINE)
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

# --- Done -----------------------------------------------------------------

say "=== Done ==="
say "Bridge entry:    $BRIDGE_ENTRY"
say "CC settings:     $CC_SETTINGS"
say "Codex config:    $CODEX_CONFIG"
say ""
say "Restart Claude Code and Codex for the MCP registration to take effect."
say "Then invoke /codex from CC to spawn a Codex pane and verify the link."
