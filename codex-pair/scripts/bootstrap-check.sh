#!/usr/bin/env bash
# bootstrap-check.sh — Step 3A.1.a. Decide whether the Phase 5 bootstrap can
# be skipped (recent AND fully validated) or must be re-run.
# Usage: bootstrap-check.sh <codex_pane_id>
# Stdout contract:
#   SKIP_BOOTSTRAP=<0|1>
#   SKIP_BLOCKED: FAIL <reason> (forcing rebootstrap)   [when a predicate fails]
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cx_resolve_context
BFILE="$SESSION_DIR/bootstrap.json"
CODEX_PANE_ID="${1:-${CODEX_PANE_ID:-}}"

# H2: bootstrap-skip TTL. Both freshness gates (outer bash mtime + inner
# python ts) read this one value so they can't drift. 30 min amortizes the
# ~990-tok cold bootstrap across the idle-resume case.
TTL_S=1800

SKIP_BOOTSTRAP=0
if [ -f "$BFILE" ]; then
  AGE_S=$(( $(date +%s) - $(mtime_s "$BFILE") ))
  if [ "$AGE_S" -lt "$TTL_S" ]; then
    # Run the same 4 predicates as the ACK check (3A.1.c). No $BOOTSTRAP_UUID
    # to check on the skip-path, so accept any non-empty bootstrap_id but
    # require codex_pane_id + doctor_status + fresh ts.
    RESULT=$(python3 - "$BFILE" "$CODEX_PANE_ID" "$TTL_S" <<'PY'
import json, sys, datetime
path, want_pane, ttl_s = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    with open(path) as f: d = json.load(f)
except Exception as e:
    print(f"FAIL parse: {e}"); sys.exit(0)
if not d.get("bootstrap_id"):
    print("FAIL no_bootstrap_id"); sys.exit(0)
if d.get("codex_pane_id") != want_pane:
    print(f"FAIL pane_mismatch want={want_pane} got={d.get('codex_pane_id')}")
    sys.exit(0)
if "Status: OK" not in d.get("doctor_status", ""):
    print("FAIL doctor_unhealthy"); sys.exit(0)
try:
    ts = datetime.datetime.strptime(d["ts"], "%Y-%m-%dT%H:%M:%SZ")
    age = (datetime.datetime.utcnow() - ts).total_seconds()
    # -60s tolerates clock skew.
    if age > ttl_s or age < -60:
        print(f"FAIL ts_stale age={age:.0f} ttl={ttl_s}"); sys.exit(0)
except Exception as e:
    print(f"FAIL ts_unparseable: {e}"); sys.exit(0)
print("OK")
PY
)
    [ "$RESULT" = "OK" ] && SKIP_BOOTSTRAP=1 || echo "SKIP_BLOCKED: $RESULT (forcing rebootstrap)"
  fi
fi
echo "SKIP_BOOTSTRAP=$SKIP_BOOTSTRAP"
