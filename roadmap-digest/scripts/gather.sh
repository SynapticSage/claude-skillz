#!/usr/bin/env bash
# roadmap-digest: discover the raw signals needed to build the roadmap model.
#
# Prints, with clear section headers so the reading model can navigate fast:
#   - roadmap / plan candidates in priority order (path + size)
#   - the journal index, newest first, each with its first heading (what shipped)
#   - recent git history (to corroborate completion)
#
# It intentionally does NOT dump full roadmap bodies — read those directly once you
# know which candidate to trust. Usage: gather.sh [project_root]
set -euo pipefail
ROOT="${1:-.}"
cd "$ROOT" 2>/dev/null || { echo "cannot cd into '$ROOT'"; exit 1; }

echo "# roadmap-digest signals — $(pwd)"
echo

echo "## roadmap candidates (priority order — read the top one(s) in full)"
found=0
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
  echo "- $f  (${lines} lines)"
  found=1
done < <(
  {
    ls ROADMAP.md roadmap.md ROADMAP.markdown Roadmap.md 2>/dev/null
    ls plan/*.md plans/*.md 2>/dev/null | sort
    ls docs/roadmap*.md docs/ROADMAP*.md docs/plan*.md 2>/dev/null
    ls TODO.md TODO ROADMAP 2>/dev/null
    find . -maxdepth 3 -type f \( -iname '*roadmap*.md' -o -iname 'plan.md' \) 2>/dev/null | sed 's#^\./##'
  } | while IFS= read -r f; do
        [ -f "$f" ] || continue
        ino=$(ls -di "$f" 2>/dev/null | awk '{print $1}')   # dedup by file identity, not spelling
        printf '%s\t%s\n' "$ino" "$f"
      done | awk -F'\t' 'NF==2 && !seen[$1]++ {print $2}'
)
[ "$found" = 1 ] || echo "(none found — STOP and ask the user where the roadmap lives)"
echo

echo "## journal index (newest first — evidence of what shipped)"
if [ -d journal ]; then
  # Their convention prefixes entries with a sortable datetime, so reverse-sort by name.
  ls -1 journal/*.md 2>/dev/null | sort -r | head -50 | while IFS= read -r j; do
    h=$(grep -m1 '^#' "$j" 2>/dev/null | sed 's/^#\{1,\} *//')
    echo "- ${j}  —  ${h:-（no heading）}"
  done
  [ -n "$(ls -1 journal/*.md 2>/dev/null)" ] || echo "(journal/ exists but is empty)"
else
  echo "(no journal/ directory — rely on git history + inline roadmap markers)"
fi
echo

echo "## recent git history (corroborate completion)"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git log --date=short --pretty='- %ad  %s' -n 50 2>/dev/null || echo "(git log unavailable)"
else
  echo "(not a git repository)"
fi
