#!/usr/bin/env bash
# run.sh — test harness for codex-pair scripts.
#   1. bash -n (syntax) on every script + lib.sh
#   2. shellcheck if installed (non-fatal warnings)
#   3. unit tests of the pure-logic scripts with a stubbed tmux and temp state
# Exits non-zero if any syntax check or unit assertion fails.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FAKE_TMUX="$(dirname "$0")/fake-tmux.sh"
chmod +x "$FAKE_TMUX" "$SCRIPTS_DIR"/*.sh 2>/dev/null || true

FAILS=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS+1)); }

# check <label> <expected> <actual>
check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want [$2] got [$3])"; fi
}
# contains <label> <needle> <haystack>
contains() {
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (missing [$2] in [$3])" ;; esac
}

echo "== 1. syntax (bash -n) =="
for f in "$SCRIPTS_DIR"/*.sh "$FAKE_TMUX" "$0"; do
  if bash -n "$f" 2>/tmp/cxsyn.$$; then pass "$(basename "$f")"
  else fail "$(basename "$f"): $(cat /tmp/cxsyn.$$)"; fi
done
rm -f /tmp/cxsyn.$$

echo "== 2. shellcheck (if present) =="
if command -v shellcheck >/dev/null 2>&1; then
  # SC1090/SC1091: can't follow sourced lib.sh (dynamic path) — expected.
  for f in "$SCRIPTS_DIR"/*.sh; do
    shellcheck -e SC1090,SC1091 "$f" >/dev/null 2>&1 \
      && pass "shellcheck $(basename "$f")" \
      || fail "shellcheck $(basename "$f") (run: shellcheck $f)"
  done
else
  echo "  (shellcheck not installed — skipped)"
fi

# --- isolated environment for behavioural tests -------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export REPO_ROOT="$WORK"          # lib.sh honours this → SESSION_DIR under $WORK
export TMUX_BIN="$FAKE_TMUX"
unset TMUX_PANE 2>/dev/null || true
SD="$WORK/.context/codex-pair/@1" # SESSION_DIR the stub resolves to
mkdir -p "$SD/pending"

g() { bash "$SCRIPTS_DIR/gate.sh" "$1"; }         # run gate with args
freshlock() { rm -rf "$SD/lock"; }                # clear single-flight lock
read_rest()  { cat "$SD/skill-args-rest" 2>/dev/null; }
read_phase1(){ cat "$SD/flag-phase1" 2>/dev/null; }
read_model() { cat "$SD/flag-model" 2>/dev/null || echo "<none>"; }

echo "== 3. gate.sh flag parser (A4 fix) =="
freshlock; out=$(g "");
contains "no-args → GATE clear" "GATE: clear" "$out"
check   "no-args → phase1=0" "0" "$(read_phase1)"
check   "no-args → rest empty" "" "$(read_rest)"
check   "no-args → no model" "<none>" "$(read_model)"

freshlock; out=$(g "--phase1 fix the bug")
check   "single flag → phase1=1" "1" "$(read_phase1)"
check   "single flag → rest kept" "fix the bug" "$(read_rest)"

freshlock; out=$(g "--phase1 --model gpt-5.5 hello there")
check   "multi-flag → phase1=1"  "1" "$(read_phase1)"
check   "multi-flag → model set" "gpt-5.5" "$(read_model)"
check   "multi-flag → rest kept" "hello there" "$(read_rest)"

freshlock; out=$(g "--model gpt-5.5 just this")
check   "model-first → model set" "gpt-5.5" "$(read_model)"
check   "model-first → phase1=0"  "0" "$(read_phase1)"
check   "model-first → rest kept" "just this" "$(read_rest)"

freshlock; out=$(g "a plain prompt")
check   "plain → rest kept" "a plain prompt" "$(read_rest)"
check   "plain → model cleared" "<none>" "$(read_model)"

echo "== 4. gate.sh lock TTL + pending sweep =="
rm -rf "$SD/lock"; mkdir "$SD/lock"                   # fresh lock (now)
out=$(g ""); contains "fresh lock → HOLD" "HOLD:" "$out"

rm -rf "$SD/lock"; mkdir "$SD/lock"; touch -t 202001010000 "$SD/lock"
out=$(g ""); contains "old lock → STALE_LOCK" "STALE_LOCK:" "$out"
contains "old lock → then clear" "GATE: clear" "$out"

freshlock; : > "$SD/pending/old.json"; touch -t 202001010000 "$SD/pending/old.json"
out=$(g ""); contains "old pending → swept" "STALE_PENDING:" "$out"
[ -e "$SD/pending/old.json" ] && fail "old pending file still present" || pass "old pending removed"

echo "== 5. reply-validate.sh (five outcomes) =="
rv() { bash "$SCRIPTS_DIR/reply-validate.sh" "$1" "$2"; }
mk_pending() { printf '{"codex_pane":"%s","prompt_preview":"%s"}\n' "$1" "$2" > "$SD/pending/$3.json"; }

out=$(rv "" "%9");           contains "empty tag → MISSING_TAG" "OUTCOME=MISSING_TAG" "$out"
out=$(rv "nope1234" "%9");   contains "no pending → LATE" "OUTCOME=LATE" "$out"

mk_pending "%9" "hi there" "aaaa1111"
out=$(rv "aaaa1111" "%9")
contains "match → ALL_PASS" "OUTCOME=ALL_PASS" "$out"
contains "match → preview" "PROMPT_PREVIEW=hi there" "$out"
[ -e "$SD/pending/aaaa1111.json" ] && fail "ALL_PASS did not clear pending" || pass "ALL_PASS cleared pending"

mk_pending "%9" "x" "bbbb2222"
out=$(rv "bbbb2222" "%7")
contains "wrong pane → PANE_MISMATCH" "OUTCOME=PANE_MISMATCH" "$out"
[ -e "$SD/pending/bbbb2222.json" ] && pass "PANE_MISMATCH kept pending" || fail "PANE_MISMATCH wrongly cleared"

printf '{ this is not json ' > "$SD/pending/cccc3333.json"
out=$(rv "cccc3333" "%9")
contains "bad json → MALFORMED" "OUTCOME=MALFORMED" "$out"

echo "== 6. health-update.sh (increment / reset) =="
hu() { bash "$SCRIPTS_DIR/health-update.sh" "$1"; }
rm -f "$SD/health.json"
contains "miss 1"        "MISSES=1" "$(hu MISSING_TAG)"
contains "miss 2"        "MISSES=2" "$(hu MISSING_TAG)"
contains "miss 3 (pane)" "MISSES=3" "$(hu PANE_MISMATCH)"
contains "LATE no-incr"  "MISSES=3" "$(hu LATE)"
contains "MALFORMED no-incr" "MISSES=3" "$(hu MALFORMED)"
contains "ALL_PASS reset" "MISSES=0" "$(hu ALL_PASS)"

echo "== 7. bootstrap-check.sh + ack-wait.sh (predicates) =="
mk_bootstrap() {  # <pane> <bootstrap_id> <status> <age_seconds>
  python3 -W ignore - "$SD/bootstrap.json" "$1" "$2" "$3" "$4" <<'PY'
import json, sys, datetime
path, pane, bid, status, age = sys.argv[1:6]
ts = datetime.datetime.utcnow() - datetime.timedelta(seconds=int(age))
json.dump({"acked": True, "bootstrap_id": bid, "codex_pane_id": pane,
           "doctor_status": status,
           "ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ")}, open(path, "w"))
PY
}
bc() { bash "$SCRIPTS_DIR/bootstrap-check.sh" "$1"; }

mk_bootstrap "%9" "abcd1234" "Status: OK" 60
contains "valid+fresh → skip=1" "SKIP_BOOTSTRAP=1" "$(bc %9)"

mk_bootstrap "%7" "abcd1234" "Status: OK" 60
out=$(bc %9)
contains "pane mismatch → skip=0" "SKIP_BOOTSTRAP=0" "$out"
contains "pane mismatch → blocked" "SKIP_BLOCKED:" "$out"

mk_bootstrap "%9" "abcd1234" "Status: DEGRADED" 60
contains "doctor unhealthy → skip=0" "SKIP_BOOTSTRAP=0" "$(bc %9)"

mk_bootstrap "%9" "abcd1234" "Status: OK" 99999
contains "stale ts → skip=0" "SKIP_BOOTSTRAP=0" "$(bc %9)"

# ack-wait returns immediately on a valid or definitively-invalid file.
aw() { bash "$SCRIPTS_DIR/ack-wait.sh" "$1" "$2"; }
mk_bootstrap "%9" "uuuu5678" "Status: OK" 30
contains "ack valid → ACKED" "BOOTSTRAP_ACKED" "$(aw uuuu5678 %9)"
mk_bootstrap "%9" "WRONGID" "Status: OK" 30
contains "ack wrong id → INVALID" "ACK_INVALID: FAIL bootstrap_id_mismatch" "$(aw uuuu5678 %9)"

echo "== 8. preflight.sh (tmux-session branch) =="
# Force the codex check to pass (CODEX_BIN set) and clear TMUX in the
# SUBPROCESS env so the tmux branch fires regardless of the harness's own
# TMUX. env -u TMUX guarantees it's unset inside preflight.
out=$(env -u TMUX CODEX_BIN=/bin/echo bash "$SCRIPTS_DIR/preflight.sh" 2>&1 || true)
contains "no TMUX → MISSING tmux-session" "MISSING: tmux-session" "$out"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "$FAILS ASSERTION(S) FAILED"
  exit 1
fi
