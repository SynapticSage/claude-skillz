#!/usr/bin/env bash
# ack-wait.sh — Step 3A.1.c. Poll bootstrap.json for up to 90s and validate
# four predicates before treating the bootstrap as confirmed.
# Usage: ack-wait.sh <bootstrap_uuid> <codex_pane_id>
# Stdout contract:
#   BOOTSTRAP_ACKED
#   BOOTSTRAP_TIMEOUT
#   ACK_INVALID: FAIL <reason>
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cx_resolve_context
BFILE="$SESSION_DIR/bootstrap.json"
BOOTSTRAP_UUID="${1:-${BOOTSTRAP_UUID:-}}"
CODEX_PANE_ID="${2:-${CODEX_PANE_ID:-}}"

DEADLINE=$(( $(date +%s) + 90 ))
ACK_OK=0

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if [ -f "$BFILE" ]; then
    RESULT=$(python3 - "$BFILE" "$BOOTSTRAP_UUID" "$CODEX_PANE_ID" <<'PY'
import json, sys, datetime
path, want_uuid, want_pane = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f: d = json.load(f)
except (json.JSONDecodeError, IOError):
    print("RETRY"); sys.exit(0)

# Predicate 1: bootstrap_id matches what we sent
if d.get("bootstrap_id") != want_uuid:
    print(f"FAIL bootstrap_id_mismatch want={want_uuid} got={d.get('bootstrap_id')}")
    sys.exit(0)
# Predicate 2: codex_pane_id == the pane we spawned (proves tmux_id works)
if d.get("codex_pane_id") != want_pane:
    print(f"FAIL codex_pane_id_mismatch want={want_pane} got={d.get('codex_pane_id')}")
    sys.exit(0)
# Predicate 3: doctor_status contains "Status: OK" (proves tmux_doctor works)
if "Status: OK" not in d.get("doctor_status", ""):
    print(f"FAIL doctor_unhealthy: {d.get('doctor_status', '<missing>')[:200]}")
    sys.exit(0)
# Predicate 4: ts parses and is within last 5 min
try:
    ts = datetime.datetime.strptime(d["ts"], "%Y-%m-%dT%H:%M:%SZ")
    age = (datetime.datetime.utcnow() - ts).total_seconds()
    if age > 300 or age < -60:  # tolerate small clock skew
        print(f"FAIL ts_stale age={age:.0f}s")
        sys.exit(0)
except Exception as e:
    print(f"FAIL ts_unparseable: {e}")
    sys.exit(0)
print("OK")
PY
)
    case "$RESULT" in
      OK)     ACK_OK=1; break ;;
      RETRY)  ;;  # transient — keep polling
      FAIL*)  echo "ACK_INVALID: $RESULT"; break ;;
    esac
  fi
  sleep 3
done

[ "$ACK_OK" -eq 1 ] && echo "BOOTSTRAP_ACKED" || echo "BOOTSTRAP_TIMEOUT"
