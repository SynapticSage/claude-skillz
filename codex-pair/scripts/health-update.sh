#!/usr/bin/env bash
# health-update.sh — Step 3A.3.d. Update the Phase 5 consecutive-misses
# health counter after an outcome is determined.
# Usage: health-update.sh <outcome>
# Stdout contract: MISSES=<n>   (the counter AFTER this update; the skill
#   surfaces the unhealthy banner when it is >= 3)
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cx_resolve_context
HEALTH_FILE="$SESSION_DIR/health.json"
OUTCOME="${1:-${OUTCOME:-}}"

# Initialize if missing
[ -f "$HEALTH_FILE" ] || echo '{"phase5_consecutive_misses": 0}' > "$HEALTH_FILE"

NEW_MISSES=$(python3 - "$HEALTH_FILE" "$OUTCOME" <<'PY'
import json, sys, datetime
path, outcome = sys.argv[1], sys.argv[2]
with open(path) as f: h = json.load(f)
if outcome == "ALL_PASS":
    h["phase5_consecutive_misses"] = 0
elif outcome in ("MISSING_TAG", "PANE_MISMATCH"):
    h["phase5_consecutive_misses"] = h.get("phase5_consecutive_misses", 0) + 1
# LATE and MALFORMED do not increment.
h["last_outcome"] = outcome
h["last_outcome_ts"] = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "w") as f: json.dump(h, f, indent=2)
print(h["phase5_consecutive_misses"])
PY
)
echo "MISSES=$NEW_MISSES"
