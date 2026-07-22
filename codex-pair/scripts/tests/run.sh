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
read_exec()  { cat "$SD/flag-exec" 2>/dev/null; }
read_model() { cat "$SD/flag-model" 2>/dev/null || echo "<none>"; }
read_effort(){ cat "$SD/flag-effort" 2>/dev/null || echo "<none>"; }

echo "== 3. gate.sh flag parser (A4 fix) =="
# Virgin state dir: gate.sh must not assume preflight ran. (The rest of this
# harness pre-creates $SD/pending, which masked this — found in live testing.)
VIRGIN="$(mktemp -d)"
out=$(env REPO_ROOT="$VIRGIN" bash "$SCRIPTS_DIR/gate.sh" "cold start" 2>&1)
contains "virgin dir → GATE clear"     "GATE: clear" "$out"
case "$out" in *STALE_LOCK*) fail "virgin dir → bogus STALE_LOCK" ;; *) pass "virgin dir → no bogus STALE_LOCK" ;; esac
case "$out" in *mkdir*)      fail "virgin dir → raw mkdir error" ;; *) pass "virgin dir → no mkdir error" ;; esac
rm -rf "$VIRGIN"

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
check   "plain → exec=0" "0" "$(read_exec)"

freshlock; out=$(g "--exec --model gpt-5.5 do this")
check   "exec+model → exec=1"  "1" "$(read_exec)"
check   "exec+model → model"   "gpt-5.5" "$(read_model)"
check   "exec+model → rest"    "do this" "$(read_rest)"

echo "== 3b. gate.sh model/effort validation (the invalid-model-string bug) =="
freshlock; out=$(g "--model gpt-5.6-sol --effort xhigh review this")
check   "model+effort → model"  "gpt-5.6-sol" "$(read_model)"
check   "model+effort → effort" "xhigh"       "$(read_effort)"
check   "model+effort → rest"   "review this" "$(read_rest)"

# The regression under test: effort smuggled into the model name, because the
# model was free text and effort had nowhere else to go.
freshlock; out=$(g "--model gpt-5.6-sol-high do it")
contains "smuggled effort → INVALID_MODEL" "INVALID_MODEL:" "$out"
contains "INVALID_MODEL names the valid set" "gpt-5.6-sol" "$out"
[ -d "$SD/lock" ] && fail "invalid model took the lock" || pass "invalid model took no lock"

freshlock; out=$(g "--model gpt5.6-sol do it")   # missing hyphen
contains "typo'd model → INVALID_MODEL" "INVALID_MODEL:" "$out"

freshlock; out=$(g "--effort ultrahigh do it")
contains "bogus effort → INVALID_EFFORT" "INVALID_EFFORT:" "$out"
contains "INVALID_EFFORT names the valid set" "xhigh" "$out"

freshlock; out=$(g "--model do it")
contains "valueless --model → INVALID_MODEL" "INVALID_MODEL:" "$out"
freshlock; out=$(g "--effort")
contains "bare --effort → INVALID_EFFORT" "INVALID_EFFORT:" "$out"

freshlock; out=$(CX_ALLOW_UNKNOWN=1 g "--model gpt-6-future do it")
contains "CX_ALLOW_UNKNOWN bypasses" "GATE: clear" "$out"
check   "bypass → model persisted" "gpt-6-future" "$(read_model)"

freshlock; out=$(g "no flags at all")
check   "no flags → model file cleared"  "<none>" "$(read_model)"
check   "no flags → effort file cleared" "<none>" "$(read_effort)"

# Sloppy spacing must not make a flag vanish into the prompt (the A4 failure
# class): " --effort max" matches no case arm unless leading spaces are eaten.
freshlock; out=$(g "--model  gpt-5.5   --effort  max   do it")
check   "extra spaces → model"  "gpt-5.5" "$(read_model)"
check   "extra spaces → effort" "max"     "$(read_effort)"
check   "extra spaces → prompt not polluted" "do it" "$(read_rest)"

echo "== 3c. pane.sh spawn args (defaults reach the codex CLI) =="
SPAWN_LOG="$WORK/spawn.log"
p() {  # run pane.sh with a dead pane cache → forces a spawn; returns stdout
  rm -f "$SD/pane-id" "$SD/pane-model"
  : > "$SPAWN_LOG"
  env CX_TEST_SPAWN_LOG="$SPAWN_LOG" CX_TEST_PANES="" CX_SPAWN_SLEEP=0 \
      CODEX_BIN=/bin/echo bash "$SCRIPTS_DIR/pane.sh"
}

freshlock; g "just a prompt" >/dev/null      # no --model/--effort → defaults
out=$(p); log=$(cat "$SPAWN_LOG")
contains "default spawn → gpt-5.6-sol" "--model gpt-5.6-sol" "$log"
contains "default spawn → effort high"  'model_reasoning_effort="high"' "$log"
contains "default spawn → -c carries effort" "-c model_reasoning_effort" "$log"
contains "pane.sh reports model" "MODEL=gpt-5.6-sol EFFORT=high" "$out"

freshlock; g "--model gpt-5.5 --effort max go" >/dev/null
out=$(p); log=$(cat "$SPAWN_LOG")
contains "override spawn → gpt-5.5" "--model gpt-5.5" "$log"
contains "override spawn → effort max" 'model_reasoning_effort="max"' "$log"
contains "pane.sh reports override" "MODEL=gpt-5.5 EFFORT=max" "$out"

# Reused pane: report what it's RUNNING, not what this turn would have launched.
freshlock; g "--model gpt-5.5 --effort max go" >/dev/null
out=$(p)                                          # spawn %9, records pane-model
freshlock; g "--model gpt-5.2 second turn" >/dev/null
out=$(env CX_TEST_PANES="%9" CX_SPAWN_SLEEP=0 CODEX_BIN=/bin/echo \
      bash "$SCRIPTS_DIR/pane.sh" 2>/dev/null)
contains "reuse → REUSING" "REUSING: %9" "$out"
contains "reuse reports the SPAWNED model, not the requested one" "MODEL=gpt-5.5 EFFORT=max" "$out"
contains "reuse → warning written" "--model gpt-5.2" "$(cat "$SD/model-warning" 2>/dev/null)"

# ...but the defaults must NOT trip that warning, or every reuse turn nags.
freshlock; g "plain prompt, no flags" >/dev/null
out=$(env CX_TEST_PANES="%9" CX_SPAWN_SLEEP=0 CODEX_BIN=/bin/echo \
      bash "$SCRIPTS_DIR/pane.sh" 2>/dev/null)
[ -e "$SD/model-warning" ] && fail "default reuse wrongly warned" || pass "default reuse is silent"

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
ts = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) - datetime.timedelta(seconds=int(age))
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

echo "== 9. codex capability probe (TODO #171) =="
# Models the version split that broke this skill live: an old TUI-only codex
# FIRST on PATH (so `command -v` picks it) and a modern exec-capable codex
# behind it. Resolving by PATH order hands `exec.sh` a binary with no `exec`;
# resolving by capability must reach past it. PATH is stripped to the fakes +
# system utils so the host's real codex/npm can't leak into the assertions.
mkdir -p "$WORK/oldbin" "$WORK/newbin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/oldbin/codex"           # no subcommands
printf '#!/usr/bin/env bash\n[ "$1" = exec ] && exit 0\nexit 1\n' > "$WORK/newbin/codex"
chmod +x "$WORK/oldbin/codex" "$WORK/newbin/codex"

# probe <PATH> <expr> — evaluate an expr against lib.sh under a controlled PATH
probe() { env -u CODEX_BIN PATH="$1:/usr/bin:/bin" bash -c ". '$SCRIPTS_DIR/lib.sh'; $2" 2>/dev/null; }

check "supports_exec: modern → yes" "yes" \
  "$(probe "$WORK/newbin" 'cx_supports_exec "$(command -v codex)" && echo yes || echo no')"
check "supports_exec: old TUI → no" "no" \
  "$(probe "$WORK/oldbin" 'cx_supports_exec "$(command -v codex)" && echo yes || echo no')"

# The regression: old codex shadows the modern one on PATH.
check "exec_bin reaches past shadowing old codex" "$WORK/newbin/codex" \
  "$(probe "$WORK/oldbin:$WORK/newbin" 'cx_exec_bin')"
check "CODEX_BIN (pane transport) still binds the old one" "$WORK/oldbin/codex" \
  "$(probe "$WORK/oldbin:$WORK/newbin" 'echo "$CODEX_BIN"')"

check "exec_bin empty when nothing supports exec" "" \
  "$(probe "$WORK/oldbin" 'cx_exec_bin')"
check "cx_exec_bin returns 1 when none qualifies" "1" \
  "$(probe "$WORK/oldbin" 'cx_exec_bin >/dev/null; echo $?')"

# exec.sh must diagnose, not emit an opaque rc=1.
echo "hi" > "$WORK/p.txt"
out=$(env -u CODEX_BIN PATH="$WORK/oldbin:/usr/bin:/bin" REPO_ROOT="$WORK" \
      bash "$SCRIPTS_DIR/exec.sh" "$WORK/p.txt" 2>&1 || true)
contains "exec.sh → clear EXEC_FAIL" "no codex on this machine supports" "$out"
contains "exec.sh → names the fix" "npm install -g @openai/codex@latest" "$out"

# preflight REPORTS exec_bin but must not gate on it — panes need only the TUI.
out=$(env -u CODEX_BIN PATH="$WORK/oldbin:/usr/bin:/bin" TMUX=1 REPO_ROOT="$WORK" \
      TMUX_BIN="$FAKE_TMUX" bash "$SCRIPTS_DIR/preflight.sh" 2>&1 || true)
contains "preflight still OK without exec" "OK: codex=" "$out"
contains "preflight reports exec_bin=none" "exec_bin=none" "$out"
out=$(env -u CODEX_BIN PATH="$WORK/newbin:/usr/bin:/bin" TMUX=1 REPO_ROOT="$WORK" \
      TMUX_BIN="$FAKE_TMUX" bash "$SCRIPTS_DIR/preflight.sh" 2>&1 || true)
contains "preflight reports exec_bin=<path>" "exec_bin=$WORK/newbin/codex" "$out"

echo "== 10. exec.sh model/effort (the --exec path that bypassed the gate) =="
# newbin/codex accepts `exec` but does nothing, so exec.sh gets far enough to
# prove the guardrail fires BEFORE any codex is invoked.
ex() { env -u CODEX_BIN -u TMUX PATH="$WORK/newbin:/usr/bin:/bin" REPO_ROOT="$WORK" \
       bash "$SCRIPTS_DIR/exec.sh" "$WORK/p.txt" "$@" 2>&1; }

contains "exec: bad model rejected"  "INVALID_MODEL:"  "$(ex --model gpt-5.6-sol-high)"
contains "exec: bad effort rejected" "INVALID_EFFORT:" "$(ex --effort ultrahigh)"
contains "exec: unknown arg rejected" "EXEC_FAIL: unknown arg" "$(ex gpt-5.6-sol)"
contains "exec: defaults to sol/high" "MODEL=gpt-5.6-sol EFFORT=high" "$(ex)"
contains "exec: honours overrides"    "MODEL=gpt-5.5 EFFORT=xhigh" \
         "$(ex --model gpt-5.5 --effort xhigh)"

# Lock lifetime. The gate acquires; the pane path releases in reply-validate.sh
# (3A.3). exec has NO reply handler, so it must release itself or the next
# invocation HOLDs for 60 min. Found live — the unit suite never ran the gate
# and exec.sh in sequence, so an acquire with no release looked fine.
exl() { env -u CODEX_BIN PATH="$WORK/newbin:/usr/bin:/bin" TMUX=1 REPO_ROOT="$WORK" \
        TMUX_BIN="$FAKE_TMUX" bash "$SCRIPTS_DIR/exec.sh" "$WORK/p.txt" "$@" >/dev/null 2>&1; }

freshlock; g "--exec do a thing" >/dev/null      # gate takes the lock
[ -d "$SD/lock" ] && pass "gate holds the lock" || fail "gate did not take a lock"
exl
[ -d "$SD/lock" ] && fail "exec.sh leaked the gate lock (next turn would HOLD)" \
                  || pass "exec.sh released the gate lock"

freshlock; g "--exec do a thing" >/dev/null
exl --model bogus-model-name                     # rejected before any codex call
[ -d "$SD/lock" ] && fail "rejected exec turn still holds the lock" \
                  || pass "rejected exec turn releases the lock"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "$FAILS ASSERTION(S) FAILED"
  exit 1
fi
