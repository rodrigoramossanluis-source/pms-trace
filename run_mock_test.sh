#!/usr/bin/env bash
# run_mock_test.sh - formal fixture test for pms_trace.sh (open-source build)
# SPDX-License-Identifier: MIT  -  Copyright (c) 2026 Rodrigo Ramos
#
# HOW TO RUN (macOS iTerm, from your home folder):
#   one-time:  brew install bash coreutils python
#   files:     keep the repo layout (pms_trace.sh, connector_kb.json, backends/ next to this script)
#   run:       cd ~/pms-trace && /opt/homebrew/bin/bash ./run_mock_test.sh   # Apple Silicon
#              (Intel Homebrew: /usr/local/bin/bash; MacPorts: /opt/local/bin/bash)
# HOW TO RUN (Linux):  bash ./run_mock_test.sh
#
# What it does: builds a throw-away sandbox with a fixture log archive (one booking
# travelling channel -> CM -> PMS, a failing booking and a co-tenant decoy), points the
# REAL reference backends (backends/s3search.py, s3grep.py) at it, runs the real
# pms_trace.sh and ASSERTS on the results (lit verdict gates, harvested join keys,
# follow-up hits, failure classification, KB write-back/self-learning, backend contract,
# ssh:// and s3:// transports via local shims - no network needed). Exit 0 = PASS.
#
# OPTIONS (flags or env vars; with no flag/env set you are asked at the console):
#   -s, --save [FILE]  save the full console output to FILE (default: ./test-reports/
#                      FULL_TEST_REPORT_<UTC>.txt in the folder you run from). Local
#                      paths are redacted (<sandbox>, ~) so the report is safe to share.  env SAVE=1 / SAVE_PATH=FILE
#   -v, --verbose      per-scenario function report (resolution, backend calls, join keys,
#                      verdict.json, REPORT.md, NEXT_ACTIONS.md)                           env VERBOSE=1
#   -k, --keep         keep the throw-away sandbox (raw run dirs) for inspection          env KEEP=1
#   -y, --no-prompt    never ask; unset options default to off (CI / non-interactive)
#   -h, --help
set -u
# ---- options: flags > env > console prompt (prompt only on an interactive terminal) ----
NO_PROMPT=0
while [ $# -gt 0 ]; do
  case "$1" in
    -s|--save)    SAVE=1; if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then SAVE_PATH="$2"; shift; fi ;;
    --save=*)     SAVE=1; SAVE_PATH="${1#--save=}" ;;
    -v|--verbose) VERBOSE=1 ;;
    -k|--keep)    KEEP=1 ;;
    -y|--no-prompt) NO_PROMPT=1 ;;
    -h|--help)    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (try --help)"; exit 2 ;;
  esac; shift
done
ask() { # var question - y/N prompt, only when stdin is a terminal and the var is unset
  local var="$1" ans
  [ -n "${!var+x}" ] && return 0
  if [ "$NO_PROMPT" = "0" ] && [ -t 0 ]; then
    read -r -p "$2 [y/N]: " ans
    case "$ans" in [yY]|[yY][eE][sS]) printf -v "$var" 1 ;; *) printf -v "$var" 0 ;; esac
  else printf -v "$var" 0; fi
}
ask SAVE    "Save the full test report to a file in this folder?"
ask VERBOSE "Verbose mode (function-by-function report per scenario)?"
ask KEEP    "Keep the sandbox (raw run folders) after the run?"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pick() { [ -f "$SCRIPT_DIR/$1" ] && echo "$SCRIPT_DIR/$1" || { [ -f "$HOME/$1" ] && echo "$HOME/$1"; }; }
TRACE="$(pick pms_trace.sh)"; KBSRC="$(pick connector_kb.json)"

# ---- prerequisites ------------------------------------------------------------
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "FAIL: bash >= 4 required (found $BASH_VERSION). brew install bash, then run with /opt/homebrew/bin/bash"; exit 2; fi
command -v python3 >/dev/null || { echo "FAIL: python3 not found (brew install python)"; exit 2; }
[ -n "$TRACE" ] || { echo "FAIL: pms_trace.sh not found next to this script or in ~"; exit 2; }
[ -n "$KBSRC" ] || { echo "FAIL: connector_kb.json not found next to this script or in ~"; exit 2; }
python3 -m json.tool "$KBSRC" >/dev/null || { echo "FAIL: connector_kb.json is not valid JSON"; exit 2; }
bash -n "$TRACE" || { echo "FAIL: pms_trace.sh has a syntax error"; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pms_mock.XXXXXX")"
LAUNCH_DIR="$PWD"
FULL_REPORT=""
if [ "${SAVE:-0}" = "1" ]; then
  FULL_REPORT="${SAVE_PATH:-$LAUNCH_DIR/test-reports/FULL_TEST_REPORT_$(date -u +%Y%m%dT%H%M%SZ).txt}"
  case "$FULL_REPORT" in /*) ;; *) FULL_REPORT="$LAUNCH_DIR/$FULL_REPORT" ;; esac
  mkdir -p "$(dirname "$FULL_REPORT")" || { echo "FAIL: cannot create $(dirname "$FULL_REPORT")"; exit 2; }
  : > "$FULL_REPORT.raw" || { echo "FAIL: cannot write $FULL_REPORT"; exit 2; }
  exec 3>&1 4>&2
  exec > >(tee -a "$FULL_REPORT.raw") 2>&1
  TEE_PID=$!
fi
finish() { # flush the tee, write the redacted report, then clean the sandbox
  local rc=$?
  if [ -n "$FULL_REPORT" ]; then
    exec 1>&3 2>&4 3>&- 4>&-
    wait "$TEE_PID" 2>/dev/null
    python3 - "$FULL_REPORT.raw" "$FULL_REPORT" "$ROOT" "$HOME" "$SCRIPT_DIR" <<'PYRED'
import sys
raw, out, root, home, sdir = sys.argv[1:6]
t = open(raw, errors="replace").read()
for a, b in ((root.replace("//", "/"), "<sandbox>"), (root, "<sandbox>"), (sdir, "<repo>"), (home, "~")):
    if a: t = t.replace(a, b)
t = t.replace("//pms_mock", "/pms_mock")
open(out, "w").write(t)
PYRED
    rm -f "$FULL_REPORT.raw"
    echo "full test report saved (paths redacted): $FULL_REPORT"
  fi
  if [ "${KEEP:-0}" = "1" ]; then echo "sandbox kept: $ROOT"; else rm -rf "$ROOT"; fi
  exit $rc
}
trap finish EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
if [ "${KEEP:-0}" = "1" ]; then
  FULL_REPORT="$ROOT/FULL_TEST_REPORT.txt"
  exec > >(tee -a "$FULL_REPORT") 2>&1
fi
# GNU tool shims: macOS BSD date/timeout/stat/sed/readlink lack the GNU flags the tool uses.
for t in date timeout stat sed readlink seq sort; do
  command -v "g$t" >/dev/null 2>&1 && ln -sf "$(command -v "g$t")" "$BIN/$t"
done
PATH="$BIN:$PATH"
date -u -d "2026-01-01 00:00:00" +%s >/dev/null 2>&1 || { echo "FAIL: GNU date required (brew install coreutils)"; exit 2; }
command -v timeout >/dev/null || { echo "FAIL: 'timeout' missing (brew install coreutils)"; exit 2; }
echo "== env: $(bash --version | head -1)"
echo "== env: $(python3 --version) | date=$(command -v date) | trace=$TRACE | kb=$KBSRC"

# ---- fixture dataset: what the log archive would contain ------------------------
# One JSON object per line; "_sys" / "_comp" route it to an app. Everything else is the
# raw log line the backend returns. All ids are synthetic.
FIX="$ROOT/fixture.jsonl"
cat > "$FIX" <<'FIXEOF'
{"_sys":"cm-ota2","_comp":"booking-gateway","@timestamp":"2026-01-10T12:03:11.402Z","level":"INFO","msg":"make_reservation received","reservationId":"OTA2-1000000001","sourceAgentCode":"OTA2","echoToken":"ECHO-7f3a9c21","flowToken":"0a1b2c3d-1111-4222-8333-944455556666","propertyUuid":"11111111-2222-4333-8444-555555555555","roomCode":"DBL","ratePlanCode":"BAR"}
{"_sys":"cm-ota2","_comp":"booking-gateway","@timestamp":"2026-01-10T12:03:11.988Z","level":"INFO","msg":"RESPONSE make_reservation","reservationId":"OTA2-1000000001","statusCode":200,"flowToken":"0a1b2c3d-1111-4222-8333-944455556666"}
{"_sys":"cm-ota2","_comp":"booking-processor","@timestamp":"2026-01-10T12:03:12.120Z","level":"INFO","msg":"acceptance persisted","statusCode":200,"flowToken":"0a1b2c3d-1111-4222-8333-944455556666","hubBookingUuid":"9c8b7a65-4321-4fed-8cba-0123456789ab"}
{"_sys":"hub-channel-store","_comp":"booking-api","@timestamp":"2026-01-10T12:03:12.733Z","level":"INFO","msg":"Fetching reservation for delivery","cmBookingId":"OTA2-1000000001","hubBookingUuid":"9c8b7a65-4321-4fed-8cba-0123456789ab","flowToken":"0a1b2c3d-1111-4222-8333-944455556666"}
{"_sys":"pms-hub","_comp":"booking-api","@timestamp":"2026-01-10T12:03:13.050Z","level":"INFO","msg":"pmsBookings upsert","hubBookingUuid":"9c8b7a65-4321-4fed-8cba-0123456789ab","pmsBookingId":"DIR-OTA2-1000000001-1","pmsType":"CLOUDPMS","hubPmsPropertyUuid":"22222222-3333-4444-8555-666666666666"}
{"_sys":"pms-hub","_comp":"pms-booking-events","@timestamp":"2026-01-10T12:03:14.410Z","level":"INFO","msg":"Delivered reservation version 1","hubBookingUuid":"9c8b7a65-4321-4fed-8cba-0123456789ab","status":"Delivered","flowToken":"0a1b2c3d-1111-4222-8333-944455556666"}
{"_sys":"cm-ota2","_comp":"booking-gateway","@timestamp":"2026-01-10T12:41:00.000Z","level":"INFO","msg":"make_reservation received","reservationId":"OTA2-1000000777","sourceAgentCode":"OTA2","flowToken":"ffffffff-0000-4000-8000-000000000777"}
{"_sys":"cm-ota2","_comp":"booking-gateway","@timestamp":"2026-01-10T15:20:01.100Z","level":"INFO","msg":"make_reservation received","reservationId":"OTA2-2000000002","sourceAgentCode":"OTA2","flowToken":"5e5e5e5e-2222-4333-8444-955566667777"}
{"_sys":"cm-ota2","_comp":"booking-gateway","@timestamp":"2026-01-10T15:20:01.600Z","level":"INFO","msg":"RESPONSE make_reservation","reservationId":"OTA2-2000000002","statusCode":200,"flowToken":"5e5e5e5e-2222-4333-8444-955566667777"}
{"_sys":"hub-channel-store","_comp":"booking-api","@timestamp":"2026-01-10T15:20:02.300Z","level":"INFO","msg":"Fetching reservation for delivery","cmBookingId":"OTA2-2000000002","hubBookingUuid":"7d7d7d7d-aaaa-4bbb-8ccc-dddddddddddd","flowToken":"5e5e5e5e-2222-4333-8444-955566667777"}
{"_sys":"pms-hub","_comp":"pms-booking-events","@timestamp":"2026-01-10T15:20:03.900Z","level":"ERROR","msg":"reservation conversion failed","hubBookingUuid":"7d7d7d7d-aaaa-4bbb-8ccc-dddddddddddd","status":"Error","faultCode":"ERR_CONVERSION_UNMAPPED_ROOM_RATE","flowToken":"5e5e5e5e-2222-4333-8444-955566667777"}
FIXEOF

# ---- log tree: the fixture laid out the way a real archive is ---------------------
# S3S_LAYOUT default {sys}/{comp}/{date}-{hour}* ; odd hours are gzipped to exercise .gz handling.
LOGS="$ROOT/logs"; ARCH="$ROOT/archive"; mkdir -p "$LOGS" "$ARCH/channelrelay-sync-partition-one-log-r1"
python3 - "$FIX" "$LOGS" <<'PY'
import gzip, json, os, sys
fix, root = sys.argv[1:]
files = {}
for l in open(fix):
    if not l.strip(): continue
    o = json.loads(l); ts = o["@timestamp"]
    rel = "%s/%s/%s-%s.log" % (o["_sys"], o["_comp"], ts[:10], ts[11:13])
    files.setdefault(rel, []).append(json.dumps({k: v for k, v in o.items() if not k.startswith("_")}, separators=(",", ":")))
for rel, lines in files.items():
    p = os.path.join(root, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
    data = "\n".join(lines) + "\n"
    if int(rel[-6:-4]) % 2: gzip.open(p + ".gz", "wt").write(data)
    else: open(p, "w").write(data)
# apps that exist in the estate but logged nothing for these bookings (catalog-only)
for app in ("cm-ota2/avail-gateway cm-ota2/booking-job cm-ota2/avail-api cm-ota2/property-api "
            "pms-hub/hub-booking-events pms-hub/avail-api pms-cm-bridge/state-sync-api "
            "pms-cm-bridge/booking-api hub-channel-store/notification-api").split():
    os.makedirs(os.path.join(root, app), exist_ok=True)
PY

# ---- backends: the REAL reference implementations shipped in backends/ -------------
BK=""; for d in "$SCRIPT_DIR/backends" "$HOME/backends" "$HOME/pms_tools/backends"; do [ -f "$d/s3search.py" ] && { BK="$d"; break; }; done
[ -n "$BK" ] || { echo "FAIL: backends/s3search.py not found (keep the repo layout: backends/ next to this script)"; exit 2; }
chmod +x "$BK/s3search.py" "$BK/s3grep.py" 2>/dev/null
export PT_SEARCH_CMD="$BK/s3search.py" PT_GREP_CMD="$BK/s3grep.py"     # never pick up a real backend on PATH
export S3S_ROOT="$LOGS" S3G_ROOT="$ARCH"
echo "== backends: $BK"

# transport shims (no network): 'ssh' runs the remote command locally, 'aws' maps s3:// to $ROOT/s3
SHIM="$ROOT/shim"; mkdir -p "$SHIM" "$ROOT/s3"; ln -s "$LOGS" "$ROOT/s3/demo-logs"
cat > "$SHIM/ssh" <<'SH'
#!/usr/bin/env bash
# test shim: ssh [-n] [-o opt]... target "command"  ->  run command locally
while [ $# -gt 0 ]; do case "$1" in -n) shift;; -o) shift 2;; -*) shift;; *) break;; esac; done
shift; exec bash -c "$*"
SH
cat > "$SHIM/aws" <<PY
#!/usr/bin/env python3
# test shim: aws s3 ls [--recursive] s3://b/p/  |  aws s3 cp s3://b/key -
import os, sys
R = "$ROOT/s3"
a = sys.argv[1:]
def loc(u): return os.path.join(R, u[5:])
if a[:2] == ["s3", "ls"]:
    rec = "--recursive" in a; u = [x for x in a if x.startswith("s3://")][0]; p = loc(u)
    if rec:
        b = u[5:].split("/")[0]
        for d, _, fs in os.walk(os.path.join(R, b), followlinks=True):
            for f in fs:
                key = os.path.relpath(os.path.join(d, f), os.path.join(R, b))
                if (b + "/" + key).startswith(u[5:]): print("2026-01-10 00:00:00 %9d %s" % (1, key))
    elif os.path.isdir(p):
        for n in sorted(os.listdir(p)):
            print("                           PRE %s/" % n if os.path.isdir(os.path.join(p, n)) else "2026-01-10 00:00:00 1 " + n)
    sys.exit(0)
if a[:2] == ["s3", "cp"] and a[3] == "-":
    sys.stdout.buffer.write(open(loc(a[2]), "rb").read()); sys.exit(0)
sys.exit(2)
PY
chmod +x "$SHIM/ssh" "$SHIM/aws"

print_verbose_function_report() {
  local run_dir="$1" call_log="$2"
  echo "==================== VERBOSE FUNCTION REPORT ===================="
  echo "--- [Function: System & App Resolution (resolve.tsv)] ---"
  [ -s "$run_dir/resolve.tsv" ] && cat "$run_dir/resolve.tsv" || echo "(none)"

  echo "--- [Function: Backend Search & Grep Calls (mock_calls.log)] ---"
  [ -s "$call_log" ] && cat "$call_log" || echo "(none)"

  echo "--- [Function: Join Key Harvester (join_keys.tsv)] ---"
  [ -s "$run_dir/join_keys.tsv" ] && cat "$run_dir/join_keys.tsv" || echo "(none)"

  echo "--- [Function: Gate & Failure Verdict Evaluator (verdict.json)] ---"
  [ -s "$run_dir/verdict.json" ] && python3 -m json.tool "$run_dir/verdict.json" || echo "(none)"

  echo "--- [Function: Main Trace Report Generator (REPORT.md)] ---"
  [ -s "$run_dir/REPORT.md" ] && cat "$run_dir/REPORT.md" || echo "(none)"

  echo "--- [Function: Remediation Advisor (NEXT_ACTIONS.md)] ---"
  [ -s "$run_dir/NEXT_ACTIONS.md" ] && cat "$run_dir/NEXT_ACTIONS.md" || echo "(none)"
  echo "================================================================="
}

# ---- scenario runner ------------------------------------------------------------
TOTAL_FAIL=0
run_case() { # name ref at extra-env...
  local name="$1" ref="$2" at="$3"; shift 3
  local H="$ROOT/home_$name"; mkdir -p "$H/pms_tools/kb"
  cp "${KBFROM:-$KBSRC}" "$H/pms_tools/kb/connector_kb.json"
  echo; echo "================ scenario: $name  (ref=$ref at=$at) ================"
  env HOME="$H" PATH="$PATH" S3S_CALL_LOG="$H/mock_calls.log" \
    PT_CASE="mock-$name" PT_REF="$ref" PT_CHANNEL=OTA2 PT_PMS=CLOUDPMS \
    PT_AT="$at" PT_AT_UNCERTAIN=1 PT_FANOUT_HOURS=1 PT_FROM="${at:0:10}" PT_TO="${at:0:10}" \
    PT_TASKS=trace PT_DETACH=0 PT_NO_PREFLIGHT=1 PT_SYS_SWEEP=0 PT_FULLDAY_FALLBACK=1 \
    PT_FOLLOW=1 PT_GREP_FALLBACK=1 PT_MODE=run PT_SEARCH_TIMEOUT=60 PT_CATALOG_TIMEOUT=60 \
    PT_KB_DIR="$H/pms_tools/kb" PT_KB_FILE=connector_kb.json PT_ON_EXISTS=wipe PT_ON_FINISHED=wipe \
    "$@" bash "$TRACE" < /dev/null > "$H/run.log" 2>&1
  local rc=$?
  RUN="$H/pms_tools/runs/mock-$name"; LOG="$H/run.log"
  CALLS=$(grep -c . "$H/mock_calls.log" 2>/dev/null || echo 0); KBLIVE="$H/pms_tools/kb/connector_kb.json"
  echo "trace exit=$rc  backend calls=$CALLS  kb-write: $(grep -h '\[kb-write\] updated' "$LOG" | tail -1)"
  [ "${VERBOSE:-0}" = "1" ] && print_verbose_function_report "$RUN" "$H/mock_calls.log"
  return 0
}

summ() { python3 - "$RUN" <<'PY'
import json, os, sys, glob
run = sys.argv[1]
v = json.load(open(os.path.join(run, "verdict.json")))
keys = [l.split("\t")[:2] for l in open(os.path.join(run, "join_keys.tsv"))] if os.path.exists(os.path.join(run, "join_keys.tsv")) else []
raw = glob.glob(os.path.join(run, "raw", "*.out"))
nonempty = [f for f in raw if os.path.getsize(f) > 0]
follow = [f for f in nonempty if os.path.basename(f).startswith("f_")]
print("  reached : %s" % v.get("reached"))
print("  missing : %s" % v.get("missing"))
for k in ("failed", "failed_gates", "terminal", "failure_codes", "na"):
    if k in v: print("  %-8s: %s" % (k, v[k]))
print("  join keys (%d): %s" % (len(keys), ", ".join("%s=%s" % (a, b) for a, b in keys)))
print("  evidence files with hits: %d (follow-up hits: %d)" % (len(nonempty), len(follow)))
PY
}
check() { # description python-expression-over(v, keys, run)
  local d="$1" expr="$2"
  if KBP="$KBLIVE" KBSRC_="${KBFROM:-$KBSRC}" python3 - "$RUN" "$expr" <<'PY'
import json, os, sys, glob
run, expr = sys.argv[1], sys.argv[2]
try: v = json.load(open(os.path.join(run, "verdict.json")))
except Exception: v = {}
jk = os.path.join(run, "join_keys.tsv")
keys = {}
if os.path.exists(jk):
    for l in open(jk):
        p = l.rstrip("\n").split("\t")
        if len(p) >= 2: keys.setdefault(p[0], set()).add(p[1])
nonempty = [os.path.basename(f) for f in glob.glob(os.path.join(run, "raw", "*.out")) if os.path.getsize(f) > 0]
report = open(os.path.join(run, "REPORT.md")).read() if os.path.exists(os.path.join(run, "REPORT.md")) else ""
reached = set(v.get("reached", []))
sys.exit(0 if eval(expr) else 1)
PY
  then echo "  [PASS] $d"; else echo "  [FAIL] $d"; CASE_FAIL=$((CASE_FAIL+1)); fi
}

# ---- scenario 1: healthy booking, end-to-end delivered ----------------------------
run_case delivered OTA2-1000000001 2026-01-10T12:00:00
CASE_FAIL=0
if [ -s "$RUN/verdict.json" ]; then summ; else echo "  verdict.json missing - log tail:"; tail -n 25 "$LOG"; fi
check "verdict.json written"                                  "bool(v)"
check "gates ARRIVAL,ACCEPTANCE,CM_STORE,PMS_RECEIVE,DELIVERY lit" "{'ARRIVAL','ACCEPTANCE','CM_STORE','PMS_RECEIVE','DELIVERY'} <= reached"
check "CONVERSION not lit (no failure)"                       "'CONVERSION' not in reached and not v.get('failure_codes')"
check "flowToken harvested"                                  "'0a1b2c3d-1111-4222-8333-944455556666' in keys.get('flowToken', set())"
check "hubBookingUuid harvested"                           "'9c8b7a65-4321-4fed-8cba-0123456789ab' in keys.get('hubBookingUuid', set())"
check "follow-up sweeps produced hits (f_*.out)"              "any(f.startswith('f_') for f in nonempty)"
check "co-tenant booking OTA2-1000000777 NOT in evidence"     "'ffffffff-0000-4000-8000-000000000777' not in str(keys)"
check "REPORT.md + NEXT_ACTIONS.md written"                   "bool(report) and os.path.exists(os.path.join(run,'NEXT_ACTIONS.md'))"
KB1="$KBLIVE"; CALLS1=$CALLS
check "KB write-back: timestamped .bak created"               "len(glob.glob(os.environ['KBP'] + '.bak.*')) == 1"
check "KB write-back: run recorded in channels.OTA2.history"  "json.load(open(os.environ['KBP']))['channels']['OTA2']['history'][-1]['case'] == 'mock-delivered'"
check "KB write-back: pms delivery_apps NOT polluted by channel apps" "not [a for a in json.load(open(os.environ['KBP']))['pms']['CLOUDPMS']['delivery_apps'] if not a.startswith('pms-')]"
check "KB write-back: KB-declared apps kept (no false stale repair)" "json.load(open(os.environ['KBP']))['channels']['OTA2']['log_apps'].get('ari_outbound') == json.load(open(os.environ['KBSRC_']))['channels']['OTA2']['log_apps'].get('ari_outbound')"
[ $CASE_FAIL -gt 0 ] && { TOTAL_FAIL=$((TOTAL_FAIL+CASE_FAIL)); echo "  log tail:"; tail -n 20 "$LOG"; }

# ---- scenario 1b: second session starts from the KB the first session wrote ----------
KBFROM="$KB1" run_case rerun OTA2-1000000001 2026-01-10T12:00:00
CASE_FAIL=0
[ -s "$RUN/verdict.json" ] && summ
check "same gates reached from the written-back KB"           "{'ARRIVAL','ACCEPTANCE','CM_STORE','PMS_RECEIVE','DELIVERY'} <= reached"
check "loaded the updated KB (history now has 2 runs)"        "len(json.load(open(os.environ['KBP']))['channels']['OTA2']['history']) == 2"
check "backend calls not higher than first session ($CALLS1)" "$CALLS <= $CALLS1"
[ $CASE_FAIL -gt 0 ] && { TOTAL_FAIL=$((TOTAL_FAIL+CASE_FAIL)); echo "  log tail:"; tail -n 20 "$LOG"; }

# ---- scenario 3: discovery + self-learning (channel module has NO app paths) -----------
# Session A must discover the channel system from the catalog, sweep the verified pool and write
# the apps that produced hits back to the KB; session B must start from those apps and need fewer calls.
KBBLANK="$ROOT/kb_blank_ota2.json"
python3 - "$KBSRC" "$KBBLANK" <<'PY'
import json, sys
k = json.load(open(sys.argv[1])); k["channels"]["OTA2"]["log_apps"] = {"reservation_inbound": None, "ari_outbound": None}
json.dump(k, open(sys.argv[2], "w"), indent=1)
PY
KBFROM="$KBBLANK" run_case discover OTA2-1000000001 2026-01-10T12:00:00
CASE_FAIL=0
[ -s "$RUN/verdict.json" ] && summ
KBD="$KBLIVE"; CALLSD=$CALLS
check "system discovered via cm-<prefix> convention (pool-verified)" "'sys_from_convention|OTA2|cm-ota2' in open(os.path.join(run,'resolve.tsv')).read()"
check "gates reached despite empty KB module"                 "{'ARRIVAL','ACCEPTANCE','CM_STORE','PMS_RECEIVE','DELIVERY'} <= reached"
check "KB learned channels.OTA2.log_apps.reservation_inbound" "json.load(open(os.environ['KBP']))['channels']['OTA2']['log_apps'].get('reservation_inbound') == 'cm-ota2/booking-gateway'"
[ $CASE_FAIL -gt 0 ] && { TOTAL_FAIL=$((TOTAL_FAIL+CASE_FAIL)); echo "  log tail:"; tail -n 20 "$LOG"; }
KBFROM="$KBD" run_case relearn OTA2-1000000001 2026-01-10T12:00:00
CASE_FAIL=0
[ -s "$RUN/verdict.json" ] && summ
check "session B resolved from learned KB apps (authoritative)" "'sys_from_kb_apps|OTA2|cm-ota2' in open(os.path.join(run,'resolve.tsv')).read()"
check "session B same gates"                                  "{'ARRIVAL','ACCEPTANCE','CM_STORE','PMS_RECEIVE','DELIVERY'} <= reached"
check "session B cheaper: $CALLS calls < $CALLSD (discovery)"  "$CALLS < $CALLSD"
[ $CASE_FAIL -gt 0 ] && { TOTAL_FAIL=$((TOTAL_FAIL+CASE_FAIL)); echo "  log tail:"; tail -n 20 "$LOG"; }

# ---- scenario 4: booking arrives but PMS conversion fails (terminal signature) -----
run_case convfail OTA2-2000000002 2026-01-10T15:00:00
CASE_FAIL=0
if [ -s "$RUN/verdict.json" ]; then summ; else echo "  verdict.json missing - log tail:"; tail -n 25 "$LOG"; fi
check "verdict.json written"                                  "bool(v)"
check "ARRIVAL, ACCEPTANCE, CM_STORE lit"                     "{'ARRIVAL','ACCEPTANCE','CM_STORE'} <= reached"
check "failure code ERR_CONVERSION_UNMAPPED_ROOM_RATE captured" "'ERR_CONVERSION_UNMAPPED_ROOM_RATE' in v.get('failure_codes', {})"
check "DELIVERY not reported as success"                      "'DELIVERY' not in reached"
check "deeper key hubBookingUuid harvested from follow hits" "'7d7d7d7d-aaaa-4bbb-8ccc-dddddddddddd' in keys.get('hubBookingUuid', set())"
check "terminal signature recognised from KB"                 "v.get('terminal') == 'ERR_CONVERSION_UNMAPPED_ROOM_RATE'"
[ $CASE_FAIL -gt 0 ] && { TOTAL_FAIL=$((TOTAL_FAIL+CASE_FAIL)); echo "  log tail:"; tail -n 20 "$LOG"; }

# ---- scenario 5: backend contract (direct calls) -----------------------------------
echo; echo "================ scenario: backend contract (backends/s3search.py, s3grep.py) ================"
CASE_FAIL=0
bk() { python3 "$BK/s3search.py" "$@"; }
expect() { # label expected-rc command...
  local label="$1" want="$2"; shift 2; local out rc; out=$("$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then
    echo "  [PASS] $label (rc=$rc, $(printf '%s' "$out" | grep -c .) lines)"
    [ "${VERBOSE:-0}" = "1" ] && [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/         | /'
  else
    echo "  [FAIL] $label (rc=$rc want $want): $(printf '%s' "$out" | head -2)"; CASE_FAIL=$((CASE_FAIL+1))
  fi
}

expect "ls * * lists the estate"                     0 bk ls '*' '*'
expect "ls glob cm-ota2 booking-*"               0 bk ls cm-ota2 'booking-*'
expect "grep one hour (plain file)"                  0 bk grep cm-ota2 booking-gateway 2026-01-10-12 OTA2-1000000001
expect "grep one hour (.gz file)"                    0 bk grep cm-ota2 booking-gateway 2026-01-10-15 OTA2-2000000002
expect "grep whole day, sys glob"                    0 bk grep '*' '*' '2026-01-10-*' 9c8b7a65-4321-4fed-8cba-0123456789ab
expect "grep wrong hour -> no match"                 1 bk grep cm-ota2 booking-gateway 2026-01-10-09 OTA2-1000000001
expect "query field equality"                        0 bk query pms-hub '*' '2026-01-10-*' 's.faultCode = "ERR_CONVERSION_UNMAPPED_ROOM_RATE"'
expect "query AND + LIKE"                            0 bk query cm-ota2 '*' '2026-01-10-*' "s.reservationId LIKE '%1000000001' AND s.statusCode = '200'"
expect "query non-matching field value"              1 bk query cm-ota2 '*' '2026-01-10-*' 's.reservationId = "OTA2-1000000"'
expect "unsafe name rejected"                        2 bk ls 'cm;rm -rf' '*'
expect "bad blob rejected"                           2 bk grep cm-ota2 '*' 2026-01-10 x
expect "s3grep find (empty legacy archive)"          1 python3 "$BK/s3grep.py" find OTA2-1 'channelrelay*partition*one*' 2026-01-10
L=$(bk grep '*' '*' '2026-01-10-*' OTA2-1000000001 | sort | cksum)
S=$(PATH="$SHIM:$PATH" S3S_ROOT="ssh://ops@loghost$LOGS" bk grep '*' '*' '2026-01-10-*' OTA2-1000000001 | sort | cksum)
A=$(PATH="$SHIM:$PATH" S3S_ROOT="s3://demo-logs" bk grep '*' '*' '2026-01-10-*' OTA2-1000000001 | sort | cksum)
[ "$L" = "$S" ] && echo "  [PASS] ssh:// transport returns identical lines" || { echo "  [FAIL] ssh:// transport differs"; CASE_FAIL=$((CASE_FAIL+1)); }
[ "$L" = "$A" ] && echo "  [PASS] s3:// transport returns identical lines"  || { echo "  [FAIL] s3:// transport differs";  CASE_FAIL=$((CASE_FAIL+1)); }
TOTAL_FAIL=$((TOTAL_FAIL+CASE_FAIL))

# ---- scenario 6/7: full trace over ssh:// and s3:// ---------------------------------
for T in "ssh:ssh://ops@loghost$LOGS" "s3:s3://demo-logs"; do
  PATH="$SHIM:$PATH" S3S_ROOT="${T#*:}" run_case "via-${T%%:*}" OTA2-1000000001 2026-01-10T12:00:00
  CASE_FAIL=0
  [ -s "$RUN/verdict.json" ] && summ
  check "all five gates lit over ${T%%:*} transport" "{'ARRIVAL','ACCEPTANCE','CM_STORE','PMS_RECEIVE','DELIVERY'} <= reached"
  [ $CASE_FAIL -gt 0 ] && { TOTAL_FAIL=$((TOTAL_FAIL+CASE_FAIL)); echo "  log tail:"; tail -n 20 "$LOG"; }
done

echo
if [ $TOTAL_FAIL -eq 0 ]; then echo "RESULT: PASS (all scenarios)"; exit 0; else echo "RESULT: FAIL ($TOTAL_FAIL check(s) failed)"; exit 1; fi
