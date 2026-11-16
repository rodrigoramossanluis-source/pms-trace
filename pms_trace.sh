# ============================================================================
# pms_trace v0.9.9-oss - solver-driven PMS<->channel reservation investigator
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Rodrigo Ramos  -  see LICENSE / README.md
# Requires: bash>=4, python3>=3.8, GNU coreutils (date -d, timeout). Log access goes through
# backends/s3search.py + s3grep.py (local dir, ssh://host/path or s3://bucket - see README.md).
# Knowledge base: external connector_kb.json (self-updating; see KNOWLEDGE BASE below).
# ------------------------------------------------------------------------------
# Supersedes v0.6.x and the standalone pms_res_tracer. Same paste contract:
#   1) Fill the INPUTS block.  2) Paste the ENTIRE file into the SSH console.
#   3) It runs detached and survives SSH drops; re-paste to resume (stage .done).
#
# WHAT CHANGED vs 0.6.2 (post-mortem of case CASE-SAMPLE-01-REF, 2026-10-28):
#   - RESOLVER: no KB module -> catalog-driven name resolution with alias
#     candidates (ota4 -> channel-four style). A missing module never gates the search;
#     the KB is a cache, the live estate is the truth. Resolution is ledgered.
#   - PATTERN VARIANTS: every scan tries the ref as given, the prefix-case
#     variant (ota4-X <-> OTA4-X) and the bare code. Lowercase-only scans caused
#     a false "never arrived" verdict in 0.6.0; that class of bug is closed.
#   - HOUR FAN-OUT: PT_AT_UNCERTAIN=1 (or empty hour sweeps with
#     PT_FULLDAY_FALLBACK=1) widens hour buckets +/-PT_FANOUT_HOURS and then to
#     the full day. Customer/GUI times are usually local, not UTC.
#   - SYSTEM SWEEP: for the resolved channel system the tool also scans
#     sys '*' per hour bucket - a hand-picked component list is never the
#     universe (notify-gateway was missed that way in 0.6.x).
#   - HARVEST & FOLLOW: first hits are parsed for join keys (flowToken,
#     hubBookingUuid, pmsBookingId, echoToken) and each key is re-scanned
#     across the chain (channel -> hub-channel-store -> pms-hub). The pms-hub
#     leg is found by keys, not by luck.
#   - VERDICT SYNTHESIZER: stage gates ARRIVAL -> INVENTORY -> ACCEPTANCE ->
#     CM_STORE -> PMS_RECEIVE -> CONVERSION -> DELIVERY are classified from the
#     raw hits (each gate independently; the order is report order, not an
#     enforced sequence). CONVERSION lights only on a conversion FAULT;
#     INVENTORY is N/A for channels whose KB module lists it in skip_gates;
#     faultCode is matched against KB failure_signatures (meaning + fix
#     path); every stage without hits gets an elimination ledger line
#     (ELIMINATED vs UNVERIFIED), never a bare "absent".
#   - FIDELITY AUTO-FETCH: PT_TASKS=fidelity with no files pulls the OTA-side
#     and PMS-side docs via harvested tokens and diffs canonical fields
#     (amounts before/after tax, taxes[], currency, guests, dates, room/rate
#     codes): PRESERVED / TRANSFORMED / DROPPED / ADDED.
#   - KB<->LIVE CROSS-VALIDATION: kb-test checks declared apps against the live
#     catalog AND re-probes module anchors; live runs write confirmed apps and
#     anchors back (KB accelerates, never gates).
#
# TASKS (PT_TASKS):  trace | fidelity | kb-test   (space-separated combo)
# v0.7.3 (second live run + operator review):
#     - CLASSIFIER PURITY: follow sweeps of low-selectivity keys (pmsType,
#       hubPmsPropertyUuid, roomCode, ratePlanCode - KB: low_selectivity_kinds) are
#       SKIPPED (they harvest co-tenant traffic: a live run lit DELIVERY with
#       152 hits from OTHER reservations, incl. hits BEFORE the booking existed,
#       and pulled ERR_PMS_BUSINESS_ERRORS noise into the report). Verdict,
#       signatures and silence now read evidence files only (t_* + high-
#       selectivity f_*); context sweeps are reported separately, never counted.
#     - TERMINAL SIGNATURES: a KB signature with "terminal": true marks
#       downstream gates N/A (no more DELIVERY [x] contradicting the verdict).
#     - ELIMINATION LEDGER populated (coverage counts + per-gate reason).
#     - RUN-MODE GATE: existing run dir -> PARTIAL asks resume/wipe/suffix
#       (default resume); FINISHED asks wipe/suffix (default suffix: isolated
#       -vN dir for cross-version crosscheck). PT_ON_EXISTS / PT_ON_FINISHED.
#     - INPUT REDESIGN: sweep keys (PT_PMS_CONF, PT_CM_RES_UUID, PT_PROPERTY_ID
#       = PROPKEY/hotelier alias), stay facts (PT_CHECKIN/PT_CHECKOUT), mapping
#       inputs (PT_PMS/CM_ROOM_CODE/RATE_CODE, PT_STAY_TOTAL, PT_CURRENCY) -
#       mapping inputs pre-fill the ERR_CONVERSION action; room/rate codes are
#       also harvested from payloads. inputs.env saved per run.
#     - FIXES: ledger lines= now counts the result file (was the empty wrapper
#       stdout); pmsd pass sweeps only apps NOT already swept; pms-hub
#       preflight control targets booking-api (was sys/*, 15min timeouts);
#       [kb] banner now lands in the detached log.
# v0.7.2 (live-run findings, case CASE-SAMPLE-01-REF-replication on log-server):
#     - ROOT-CAUSE FIX: the root catalog (ls * *) can silently truncate (search
#       timeout) - in v0.7.1 it convicted 6 GOOD KB apps as "stale". Now: an
#       UNVERIFIED catalog convicts nothing; the VERIFIED per-system listing
#       (ls <sys> *) is the only pool allowed to stale-check, and it is printed
#       for the operator plus persisted to raw/catalog_pool_<sys>.stdout.
#     - COST-ORDERED SWEEPS (live-measured: per-app hour scan ~1s, sys-wide
#       ~4-6min): trusted KB pool first, then catalog-only apps, sys-wide '*'
#       LAST RESORT (PT_SYS_SWEEP=auto). GUI ladder no longer uses sys-wide.
#     - KB FILE IS AN INPUT: PT_KB_FILE names the KB in ~/pms_tools/kb/ (ladder:
#     PT_KB_FILE -> newest connector_kb*.json in the KB dir -> newest valid .bak).
#     - preflight timeout raised (pms-hub control hit the 300s cat timeout).
#     - KB write-back now leaves a timestamped .bak before every write.
# v0.7.1 (closes the gaps found in the 0.7.0 design review):
#   - STALE-KB FALLBACK: KB-declared apps are catalog-checked at resolve time; stale
#     entries fall back to catalog candidates AND are repaired in the write-back.
#   - GUI INPUT LADDER: PT_HOTEL_UUID / PT_HOTELIER_ID / PT_PROPKEY / PT_MEMBERSHIP /
#     PT_LISTING_ID / PT_GUEST join the sweeps as first-class keys; blank = wide.
#   - pmsType REACTION: a harvested pmsType (e.g. LegacyPMS) auto-loads pms.<CODE>
#     and sweeps its delivery_apps; hubPmsPropertyUuid scopes pms-hub.
#   - RICH WRITE-BACK: history records winning pattern variant, window mode,
#     failure signatures seen, harvested key kinds and stale repairs.
#   - CONDITIONAL GOALS: NEXT_ACTIONS.md chains from the verdict (unmapped ->
#     mapping-state check; delivered -> fidelity; nothing -> widen guidance).
# RESULTS:  ~/pms_tools/runs/<CASE>/  (REPORT.md, NEXT_ACTIONS.md, ledger.tsv, raw/, join_keys.tsv)
# KNOWLEDGE BASE: ~/pms_tools/kb/$PT_KB_FILE - external file, NOT embedded. Loaded at start; every live run
#   writes back (timestamped .bak, locked atomic write). Missing -> newest connector_kb*.json; corrupt -> newest valid .bak.
# ============================================================================

# ------------------------------ INPUTS (edit) -------------------------------
PT_CASE="${PT_CASE:-CASE-0001-sample-trace}"     # case number or short label (run dir name)
PT_REF="${PT_REF:-OTA2-1000000001}"              # reservation ref, e.g. ota4-DEMO000001, OTA2-1000000001
PT_PMS="${PT_PMS:-CLOUDPMS}"                     # PMSA_XML | PMSA_REST | LEGACYPMS | CLOUDPMS | blank = discover from hits
PT_CHANNEL="${PT_CHANNEL:-OTA2}"                 # OTA/channel code or name; blank = derive from ref prefix
PT_AT="${PT_AT:-2026-01-10T12:00:00}"            # booking creation "YYYY-MM-DD HH:MM:SS" (see PT_AT_UNCERTAIN)
PT_AT_UNCERTAIN="${PT_AT_UNCERTAIN:-1}"          # 1 = AT is GUI/local/approximate -> hour fan-out + tz correction
PT_TZ_OFFSET="${PT_TZ_OFFSET:--6}"               # property GUI tz vs UTC; UTC = gui_time - offset (used when UNCERTAIN=1)
PT_FROM="${PT_FROM:-2026-01-01}"                 # first day YYYY-MM-DD (blank = AT date, else today)
PT_TO="${PT_TO:-2026-01-13}"                     # last day YYYY-MM-DD (blank = same as FROM)
PT_TASKS="${PT_TASKS:-trace}"                    # trace | fidelity | kb-test | ari | space-separated combo (expert override; PT_GOAL sets this for you)
PT_GOAL="${PT_GOAL:-}"                           # goal switch (R22): overbooking | missing-reservation | rate-mismatch | delivery-failure | billing-trace | blank|custom = PT_TASKS as typed
PT_ALLOW_PARTIAL="${PT_ALLOW_PARTIAL:-0}"        # 1 = run despite goal input-contract gaps (gaps marked UNVERIFIED); 0 = refuse + print the fill list
PT_SKIP_LEGS="${PT_SKIP_LEGS:-}"                 # space-separated stage-name substrings to skip
PT_MODE="${PT_MODE:-run}"                        # run | plan (plan = print searches only)
PT_DETACH="${PT_DETACH:-1}"                      # 1 = background, survives SSH drop | 0 = foreground
PT_RESUME="${PT_RESUME:-1}"                      # 1 = skip scans already done | 0 = redo everything
PT_SEARCH_TIMEOUT="${PT_SEARCH_TIMEOUT:-1500}"   # seconds per search (rc=124 -> retried on re-paste)
PT_CATALOG_TIMEOUT="${PT_CATALOG_TIMEOUT:-300}"  # catalog/pool listings (rc!=0 -> catalog UNVERIFIED, convicts nothing)
PT_PREFLIGHT_TIMEOUT="${PT_PREFLIGHT_TIMEOUT:-900}" # control-token fetch
PT_CONTROL_TOKEN="${PT_CONTROL_TOKEN:-reservation}" # common word for the preflight live-pipe control
PT_NO_PREFLIGHT="${PT_NO_PREFLIGHT:-0}"          # 1 = skip the positive-control check (not advised)
# solver knobs
PT_FANOUT_HOURS="${PT_FANOUT_HOURS:-3}"          # +/-hours around AT when UNCERTAIN=1
PT_FULLDAY_FALLBACK="${PT_FULLDAY_FALLBACK:-1}"  # 1 = empty hour-bucket sweeps widen to full day
PT_LAD_FD_ZERO="${PT_LAD_FD_ZERO:-0}"            # 1 = force full-day fallback even for zero-echo ladder keys
PT_SYS_SWEEP="${PT_SYS_SWEEP:-auto}"             # auto = sys-wide only when per-app passes are empty. 1=always 0=never
PT_REGION="${PT_REGION:-both}"                   # ari/guiattrib/bridge-flush: ra | rb | both - regional component selector
PT_LGCY_LOOKBACK_DAYS="${PT_LGCY_LOOKBACK_DAYS:-7}"  # lgcy-ari: days to walk back from booking day on LGCY sync partitions
PT_LGCY_REGION_SUFFIX="${PT_LGCY_REGION_SUFFIX:-r1}" # lgcy-ari: LGCY sync bucket region suffix
PT_CLOUDPMS_PROPERTY_ID="${PT_CLOUDPMS_PROPERTY_ID:-}"       # bridge-flush: numeric CloudPMS property id
PT_FLUSH_ORIGIN_DAY="${PT_FLUSH_ORIGIN_DAY:-0}"  # bridge-flush: 1 = extend culprit-origin scan to the full flush day
PT_ANCHOR_MODE="${PT_ANCHOR_MODE:-booking}"      # ari: booking (PT_AT=booking ts, sweep BACKWARD only) | day
PT_BREAK_ON="${PT_BREAK_ON:-auto}"               # ari sweep break: auto | any | target
PT_FETCH_MAX_LINES="${PT_FETCH_MAX_LINES:-200000}" # cap per-scan output lines
PT_FOLLOW="${PT_FOLLOW:-1}"                      # 1 = harvest join keys from hits and re-scan across the chain
PT_MAX_FOLLOW_KEYS="${PT_MAX_FOLLOW_KEYS:-12}"   # cap harvested keys that get follow-up scans
PT_GREP_FALLBACK="${PT_GREP_FALLBACK:-1}"        # 1 = case-insensitive local sweep of ALL fetched data before verdict
# GUI input ladder (all optional; each narrows and speeds the search - blank = wide)
PT_PMS_CONF="${PT_PMS_CONF:-}"                   # PMS confirmation / reservation code
PT_CM_RES_UUID="${PT_CM_RES_UUID:-}"             # CM reservation UUID
PT_HOTEL_UUID="${PT_HOTEL_UUID:-}"               # CM hotel UUID
PT_PROPERTY_ID="${PT_PROPERTY_ID:-}"             # hotelier / property ID or PROPKEY
PT_MEMBERSHIP="${PT_MEMBERSHIP:-}"               # OTA membership / property membership id
PT_LISTING_ID="${PT_LISTING_ID:-}"               # channel listing / room id, if known
PT_GUEST="${PT_GUEST:-}"                         # guest surname as booked (case-sensitive in logs)
PT_PROPKEY="${PT_PROPKEY:-}"                           # legacy alias of PT_PROPERTY_ID
PT_HOTELIER_ID="${PT_HOTELIER_ID:-}"             # legacy alias of PT_PROPERTY_ID
# --- ari mode: value attribution + ARI push tracing ---
PT_BOOKING_REF="${PT_BOOKING_REF:-}"             # ari: related booking ref (context only)
PT_HOTELIER_ID2="${PT_HOTELIER_ID2:-}"           # ari: legacy numeric hotelier/hotel id
PT_TARGET_VALUES="${PT_TARGET_VALUES:-}"         # ari: value(s) to flag, space-separated
PT_STAY_DATES="${PT_STAY_DATES:-}"               # ari: suspect stay dates YYYY-MM-DD, space-separated
PT_RATE_CODE="${PT_RATE_CODE:-}"                 # ari: rate code (CM/channel side)
PT_ROOM_TYPE_CODE="${PT_ROOM_TYPE_CODE:-}"       # ari: room type code (CM/channel side)
PT_CHANNEL_HOTEL_UUID="${PT_CHANNEL_HOTEL_UUID:-}" # ari: hubChannelPropertyUuid
PT_BILLING_FROM="${PT_BILLING_FROM:-}"           # billing: status-trace window start (YYYY-MM-DD)
PT_BILLING_TO="${PT_BILLING_TO:-}"               # billing: status-trace window end
PT_BILLING_ACCOUNTS="${PT_BILLING_ACCOUNTS:-}"       # billing: billing account numbers
PT_BILLING_KEY_DAYS="${PT_BILLING_KEY_DAYS:-}"   # billing: key days for payment probes
PT_SERIES_FROM="${PT_SERIES_FROM:-}"             # ari series: presence day-series start
PT_SERIES_TO="${PT_SERIES_TO:-}"                 # ari series: presence day-series end
PT_SOURCE_SYSTEM="${PT_SOURCE_SYSTEM:-auto}"     # ari: auto | bridge | xengine
# --- guiattrib mode: attribute a GUI config change to a user ---
PT_GUI_DATE="${PT_GUI_DATE:-}"                   # guiattrib: GUI audit date in UTC YYYY-MM-DD
PT_GUI_HOUR="${PT_GUI_HOUR:-}"                   # guiattrib: GUI audit hour in UTC HH (00-23)
PT_GUI_USER="${PT_GUI_USER:-}"                   # guiattrib: suspected actor email
PT_PMS_HOTEL_CODE="${PT_PMS_HOTEL_CODE:-}"       # ari xengine ingest: PMS-side hotel code
PT_CM_HOTELIER_ID="${PT_CM_HOTELIER_ID:-}"       # ari: CM hotelier id
PT_ENTITY_ID="${PT_ENTITY_ID:-}"                 # ari: hotelier entity id
# --- stay facts ---
PT_CHECKIN="${PT_CHECKIN:-}"                     # YYYY-MM-DD
PT_CHECKOUT="${PT_CHECKOUT:-}"                   # YYYY-MM-DD
# --- mapping inputs ---
PT_PMS_ROOM_CODE="${PT_PMS_ROOM_CODE:-}"         # room code as the PMS expects it
PT_PMS_RATE_CODE="${PT_PMS_RATE_CODE:-}"         # rate code as the PMS expects it
PT_CM_ROOM_CODE="${PT_CM_ROOM_CODE:-}"           # room code on the CM/channel side
PT_CM_RATE_CODE="${PT_CM_RATE_CODE:-}"           # rate code on the CM/channel side
PT_STAY_TOTAL="${PT_STAY_TOTAL:-}"               # total the guest/PMS shows
PT_CURRENCY="${PT_CURRENCY:-}"                   # ISO currency
# fidelity inputs
PT_OTA_FILE="${PT_OTA_FILE:-}"                   # path to channel XML
PT_PMS_FILE="${PT_PMS_FILE:-}"                   # path to PMS-bound XML
PT_OTA_TOKEN="${PT_OTA_TOKEN:-}"                 # token (echo/trace) to fetch the channel doc live
PT_PMS_TOKEN="${PT_PMS_TOKEN:-}"                 # message uuid to fetch the PMS doc live
# knowledge base (decoupled external JSON - unconditional writeback target)
PT_KB_DIR="${PT_KB_DIR:-$HOME/pms_tools/kb}"
PT_KB_FILE="${PT_KB_FILE:-connector_kb.json}"
PT_ON_EXISTS="${PT_ON_EXISTS:-ask}"               # existing PARTIAL run dir: ask|resume|wipe|suffix
PT_ON_FINISHED="${PT_ON_FINISHED:-ask}"          # existing FINISHED run dir: ask|wipe|suffix
# --------------------------- END OF INPUTS ----------------------------------

set -u
# v0.7.9.1: LADDER COST CUT (live test-run-v3): UUID-shaped GUI keys no longer spawn
#           a tail-fragment pattern (00000000-... -> full string only; the
#           0000000000AB variant doubled every uuid scan). Zero-echo ladder keys
#           skip the full-day fallback: a GUI key with ZERO hits in every app at
#           every planned hour is not in the logs near this booking (v3 burned
#           ~10 min of full-day pms-hub scans on one such uuid). PT_LAD_FD_ZERO=1
#           forces the old behaviour.
# v0.7.9: EVIDENCE-HOUR REGISTRY + LADDER PURITY FIX
#         - pt_hours_refresh/pt_app_hours: apps with ref-matched evidence drive
#           their own downstream plan ({h, h+1} forward); unknown apps fall back
#           to anchor +/-1 / typed plan (maintainer: "known good timestamp goes
#           downstream; current design stays as fallback").
#         - PURITY BUGFIX (live test-run-v2): hour-bounded t_lad_* property-key
#           scans admitted sibling traffic as evidence (pre-arrival Success lines
#           falsely lit DELIVERY again). t_lad_* now obeys the same ref/token
#           line filter as fd files, in BOTH harvest and verdict.
#         - INVENTORY skip-gate bugfix: PT_CHAN_SYS is now persisted into
#           inputs.env at resolve time (verdict could never see it before).
# v0.7.8: TIME CONTROL - typed AT taken as-is (CM admin/log timeline; PT_TZ_OFFSET
#         is informational, NEVER shifts discovery). Fanout is always +/-N and
#         DAY-CROSSING (was clamped to the AT day -> midnight bookings missed).
#         ARRIVAL ANCHOR: the first live ref hit locks PT_ANCHOR; every downstream
#         stage scans anchor +/-1h instead of the typed window. Fallback ladder in
#         ONE run: typed hour(+/-fan) -> full-day arrival apps -> day drift
#         (late hour -> next day; early -> previous; else both). Full-day no longer
#         runs per sweep tag. CROSS-REF: other run dirs scanned for shared property
#         identifiers (membership/uuids/hotelCode) -> "SAME PROPERTY" report line.
# v0.7.7: fd-pollution purge - full-day ladder sweeps admit only ref/token-matching lines
#         (harvest AND verdict); sweep guard covers ALL KB low_selectivity_kinds
#         (sourceAgentCode/hotelCode no longer spawn 1k-line context sweeps);
#         ChannelRelay INVENTORY gate N/A via KB skip_gates; roomTypeCode/rateCode
#         harvest variants; HIT appendix annotates context/fd files.
PT_VERSION="0.9.9-oss"
echo "== PMS TOOL PASTE v${PT_VERSION} =="

# ---- search backend resolution (aliases die in detached shells) -------------
# The tool never touches logs directly: every search goes through two small CLIs that only
# STRUCTURE the search (sys/comp/hour -> files -> matching lines):
#   s3search.py ls|grep|query ...      primary log store
#   s3grep.py   find <lit> <bkt> <day>  optional secondary/legacy archive
# Reference implementations ship in backends/ (local folder, ssh://host/path or s3://bucket; see README).
# Resolution order: PT_SEARCH_CMD / PT_GREP_CMD -> PATH -> backends/ next to this script
#                   -> ~/pms_tools/backends/ -> shell alias (interactive sessions only).
pt_find_backend() { # name override-var-value
  local name="$1" ov="$2" d _a
  if [ -n "$ov" ]; then [ -x "$ov" ] && { echo "$ov"; return; }; echo "[fetch] WARN: override $ov not executable" >&2; fi
  command -v "$name" 2>/dev/null && return
  for d in "$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd)/backends" "$HOME/pms_tools/backends"; do
    [ -x "$d/$name" ] && { echo "$d/$name"; return; }
  done
  _a=$(alias "$name" 2>/dev/null | tr -d "'\"" | tr ' ' '\n' | grep -m1 '\.py$')
  _a="${_a/#\~/$HOME}"; [ -n "$_a" ] && [ -f "$_a" ] && echo "$_a"
}
PT_S3SEARCH="$(pt_find_backend s3search.py "${PT_SEARCH_CMD:-}")"
PT_S3GREP="$(pt_find_backend s3grep.py "${PT_GREP_CMD:-}")"
if [ -z "$PT_S3SEARCH" ]; then
  echo "[fetch] FATAL: s3search.py not found (PT_SEARCH_CMD, PATH, ./backends, ~/pms_tools/backends). See README 'Log backend'."
  return 1 2>/dev/null || exit 1
fi
echo "[fetch] backend: $PT_S3SEARCH ${S3S_ROOT:+(S3S_ROOT=$S3S_ROOT)} | archive: ${PT_S3GREP:-none}"

pt_s3() { if [ -x "$PT_S3SEARCH" ]; then timeout "$PT_SEARCH_TIMEOUT" "$PT_S3SEARCH" "$@"; else timeout "$PT_SEARCH_TIMEOUT" python3 "$PT_S3SEARCH" "$@"; fi; }

# ---- run dir + logging ------------------------------------------------------
[ -n "$PT_CASE" ] || PT_CASE="nocase-$(date -u +%Y%m%dT%H%M%SZ)"
PT_RUN_DIR="$HOME/pms_tools/runs/$PT_CASE"
mkdir -p "$PT_RUN_DIR/raw" "$PT_RUN_DIR/state"

# ---- knowledge base: direct single-file target (no version search) ----------
PT_KB_DIR="${PT_KB_DIR:-$HOME/pms_tools/kb}"
PT_KB_FILE="${PT_KB_FILE:-connector_kb.json}"
PT_KB_PATH="$PT_KB_DIR/$PT_KB_FILE"
# Load ladder (the KB is an external, self-updating file - never embedded in this script):
#   1) $PT_KB_DIR/$PT_KB_FILE (the live file; write-back updates it in place, so it is always newest)
#   2) missing  -> newest connector_kb*.json in $PT_KB_DIR (never a .bak) is promoted to $PT_KB_FILE
#   3) corrupt  -> live file kept as .corrupt.<ts>, newest VALID .bak restored
pt_kb_valid() { python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$1" 2>/dev/null; }
if [ ! -f "$PT_KB_PATH" ]; then
  _cand=$(ls -t "$PT_KB_DIR"/connector_kb*.json 2>/dev/null | head -1)
  if [ -n "$_cand" ] && pt_kb_valid "$_cand"; then
    cp "$_cand" "$PT_KB_PATH" && echo "[kb] $PT_KB_FILE missing - promoted newest $(basename "$_cand")"
  fi
fi
if [ -f "$PT_KB_PATH" ] && ! pt_kb_valid "$PT_KB_PATH"; then
  _ts=$(date -u +%Y%m%dT%H%M%SZ); mv "$PT_KB_PATH" "$PT_KB_PATH.corrupt.$_ts"
  for _cand in $(ls -t "$PT_KB_PATH".bak.* 2>/dev/null); do
    if pt_kb_valid "$_cand"; then cp "$_cand" "$PT_KB_PATH"; echo "[kb] WARN: live KB was invalid JSON (kept as .corrupt.$_ts) - restored $(basename "$_cand")"; break; fi
  done
fi
if [ ! -f "$PT_KB_PATH" ]; then
  echo "[kb] ERROR: KB file not found at $PT_KB_PATH. Place $PT_KB_FILE in $PT_KB_DIR first." >&2
  exit 1
fi
#   4) a deployed versioned KB (connector_kb_v*.json) NEWER than the live file is promoted:
#      live -> .bak, new structure wins, learned data (history, verified anchors, apps the new
#      file leaves null) is carried over so a KB release never wipes what runs have learned.
_cand=$(ls -v "$PT_KB_DIR"/connector_kb_v*.json 2>/dev/null | tail -1)
if [ -n "$_cand" ] && [ "$_cand" != "$PT_KB_PATH" ] && [ "$_cand" -nt "$PT_KB_PATH" ] && pt_kb_valid "$_cand"; then
  python3 - "$_cand" "$PT_KB_PATH" "$(date -u +%Y%m%dT%H%M%SZ)" <<'PYPROMO'
import json, os, shutil, sys, fcntl
new_p, live_p, stamp = sys.argv[1:4]
lock = open(live_p + ".lock", "w"); fcntl.flock(lock, fcntl.LOCK_EX)
new, live = json.load(open(new_p)), json.load(open(live_p))
carried = 0
for sect in ("channels", "pms"):
    for code, lm in (live.get(sect) or {}).items():
        nm = (new.setdefault(sect, {})).get(code)
        if nm is None:                                   # module only the live KB knows (learned stub)
            new[sect][code] = lm; carried += 1; continue
        seen = {json.dumps(h, sort_keys=True) for h in nm.get("history", [])}
        for h in lm.get("history", []):
            if json.dumps(h, sort_keys=True) not in seen: nm.setdefault("history", []).append(h); carried += 1
        for k in ("_stale_repaired",):
            if lm.get(k): nm.setdefault(k, []).extend(x for x in lm[k] if x not in nm.get(k, []))
        la_n, la_l = nm.get("log_apps"), lm.get("log_apps")
        if isinstance(la_n, dict) and isinstance(la_l, dict):
            for k, v in la_l.items():
                if v and not la_n.get(k): la_n[k] = v; carried += 1
        ea_l = lm.get("example_anchors") or {}
        v_live, v_new = ea_l.get("verified_at") or "", (nm.get("example_anchors") or {}).get("verified_at") or ""
        if v_live > v_new:                               # ISO dates compare correctly as strings
            nm.setdefault("example_anchors", {})["verified_at"] = v_live
shutil.copy2(live_p, "%s.bak.%s.promote" % (live_p, stamp))
tmp = live_p + ".tmp.%d" % os.getpid()
with open(tmp, "w") as f: json.dump(new, f, indent=1); f.write("\n")
os.replace(tmp, live_p)
print("[kb] promoted newer %s -> %s (previous live kept as .bak.%s.promote; %d learned items carried over)"
      % (os.path.basename(new_p), os.path.basename(live_p), stamp, carried))
PYPROMO
fi
unset _cand _ts
export PT_KB_PATH

kb() { python3 - "$@" <<'PYEOF'
import json, sys, os
kb = json.load(open(os.environ["PT_KB_PATH"]))
cur = kb
for part in sys.argv[1].split("."):
    if isinstance(cur, dict) and part in cur: cur = cur[part]
    else: print(""); sys.exit(0)
if cur is None: print("")
else: print(json.dumps(cur) if isinstance(cur, (dict, list)) else cur)
PYEOF
}
kb_list() { python3 -c "import json,os;print(' '.join(json.load(open(os.environ['PT_KB_PATH']))['$1']))"; }
kb_sig() { # failure signature lookup: code -> json
  python3 - "$1" <<'PYEOF'
import json, os, sys
kb = json.load(open(os.environ["PT_KB_PATH"]))
sig = kb.get("failure_signatures", {}).get(sys.argv[1])
print(json.dumps(sig) if sig else "")
PYEOF
}

echo "[kb] $(kb schema_version) @ $PT_KB_PATH (PT_KB_FILE=$PT_KB_FILE) channels=[$(kb_list channels)] pms=[$(kb_list pms)]"
[ -z "$(kb channel_codes._note)" ] && echo "[kb] WARN: loaded KB has NO channel_codes - prefix resolution DISABLED, blind discovery possible. Deploy a current connector_kb.json."

[ -z "$PT_PROPERTY_ID" ] && PT_PROPERTY_ID="${PT_PROPKEY:-${PT_HOTELIER_ID:-}}"
{ for v in PT_CASE PT_REF PT_PMS PT_PMS_CONF PT_CM_RES_UUID PT_HOTEL_UUID PT_PROPERTY_ID PT_MEMBERSHIP PT_LISTING_ID PT_GUEST PT_CHECKIN PT_CHECKOUT PT_PMS_ROOM_CODE PT_PMS_RATE_CODE PT_CM_ROOM_CODE PT_CM_RATE_CODE PT_STAY_TOTAL PT_CURRENCY PT_AT PT_AT_UNCERTAIN PT_TZ_OFFSET PT_TARGET_VALUES PT_STAY_DATES PT_RATE_CODE PT_ROOM_TYPE_CODE PT_SOURCE_SYSTEM PT_BOOKING_REF PT_CHANNEL PT_HOTELIER_ID2; do eval "echo $v=\${$v:-}"; done; } > "$PT_RUN_DIR/inputs.env"

# ---- pattern variants: ref as given + prefix-case variant + bare code --------
pt_variants() {
  # UPPERCASE RULE (verified 2026-10-28): CM booking IDs are stored UPPERCASE; prefix presence
  # varies by component. Patterns: full-uppercase ref + bare source id (ref minus the channel
  # prefix). v0.7.5: multi-segment refs strip the FIRST segment when it is a 2-5 char channel code (letter first, e.g. ABC / OTA2)
  # (ABC-123456789-XYZ123 -> 123456789-XYZ123, the reservationId log field); otherwise strip
  # the last segment as before.
  local ref="$1" up first core
  up=$(echo "$ref" | tr 'a-z' 'A-Z')
  # UUID-shaped keys (GUI hotel/cm uuids): full string only - the tail fragment
  # (e.g. 0000000000AB) is a low-value pattern that doubles every uuid scan
  if echo "$up" | grep -qE '^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$'; then
    echo "$up"; return 0
  fi
  first="${up%%-*}"
  if [ "$first" != "$up" ] && echo "$first" | grep -qE '^[A-Z][A-Z0-9]{1,4}$'; then
    core="${up#*-}"
  else
    core="${up##*-}"; [ "$core" = "$up" ] && core=""
  fi
  local v="$up"
  [ -n "$core" ] && v="$v $core"
  echo "$v" | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' '
}

# ---- channel resolution: KB module first, catalog-driven alias second --------
PT_PREFIX=""
[ -n "$PT_REF" ] && PT_PREFIX=$(echo "$PT_REF" | sed -n 's/^\([A-Za-z][A-Za-z0-9]*\)-.*/\1/p' | tr 'A-Z' 'a-z')
PT_CHAN=""
if [ -n "$PT_REF" ]; then
  for c in $(kb_list channels); do
    for p in $(kb "channels.$c.ref_prefixes" | python3 -c "import json,sys;d=sys.stdin.read().strip();print(' '.join(json.loads(d) if d else []))" 2>/dev/null); do
      case "$PT_REF" in "$p"*|$(echo "$p" | tr 'a-z' 'A-Z')*) PT_CHAN="$c";; esac
    done
  done
fi

# catalog: root listing = SYSTEM DISCOVERY ONLY (can silently truncate - never
# used to convict KB apps). Per-system listing = the VERIFIED component pool.
pt_catalog() {
  if [ ! -f "$PT_RUN_DIR/raw/catalog_root.rc" ]; then
    PT_SEARCH_TIMEOUT="$PT_CATALOG_TIMEOUT" pt_s3 ls '*' '*' > "$PT_RUN_DIR/raw/catalog_root.stdout" 2>/dev/null
    echo "$?" > "$PT_RUN_DIR/raw/catalog_root.rc"
  fi
  cat "$PT_RUN_DIR/raw/catalog_root.stdout" 2>/dev/null
}
pt_pool() { # sys -> verified per-system pool ("sys/comp" lines); rc!=0 = unverified
  local sys="$1" sf; sf=$(echo "$sys" | tr '/ *' '___')
  local f="$PT_RUN_DIR/raw/catalog_pool_$sf.stdout" rcf="$PT_RUN_DIR/raw/catalog_pool_$sf.rc"
  if [ ! -f "$rcf" ]; then
    PT_SEARCH_TIMEOUT="$PT_CATALOG_TIMEOUT" pt_s3 ls "$sys" '*' > "$f" 2>/dev/null
    echo "$?" > "$rcf"
  fi
  [ "$(cat "$rcf" 2>/dev/null)" = "0" ] || return 1
  grep -o "$sys/[A-Za-z0-9._-]*" "$f" 2>/dev/null | sort -u
}
# systems in the root catalog whose path mentions a token (case-insensitive)
pt_sys_candidates() { # token -> "sys " list (unique)
  [ -n "${1// /}" ] || return 0   # empty token would match EVERY catalog line (picked pms-cm-bridge for an OTA2 ref)
  { pt_catalog | grep -io "cm-[a-z0-9._-]*" | grep -i "$1"
    pt_catalog | grep -i "$1" | awk -F/ 'NF>=2{print $(NF-1)}'
  } | sort -u
}

# ---- channel resolution from KB channel_codes (prefix map) -------------------
pt_channel_from_codes() { # sets PT_CHAN (KB module) or synthesizes PT_CHAN_SYS/APPS
  [ -z "$PT_CHAN" ] || return 0
  local want=""
  if [ -n "$PT_CHANNEL" ]; then
    want=$(python3 - "$PT_CHANNEL" <<'PYEOF'
import json, os, sys
kb = json.load(open(os.environ["PT_KB_PATH"]))
w = sys.argv[1].strip().upper()
codes = kb.get("channel_codes", {}).get("codes", {})
if w in codes:
    print(w)
else:
    for c, m in codes.items():
        n = m.get("name", "").upper()
        if n == w or n.split("(")[0].strip() == w:
            print(c); break
PYEOF
)
  fi
  [ -z "$want" ] && want=$(echo "$PT_PREFIX" | tr 'a-z' 'A-Z')
  [ -n "$want" ] || return 0
  local cname; cname=$(kb "channel_codes.codes.$want.name")
  [ -n "$cname" ] && [ "$cname" != "null" ] || return 0
  local am; am=$(kb "channels.$want.app_match")
  if [ -n "$am" ] && [ "$am" != "null" ]; then
    PT_CHAN="$want"
    pt_log "[resolve] channel '$want' ($cname) -> KB module $want"
    pt_note "- resolve: channel '$want' ($cname) via prefix/PT_CHANNEL -> KB module"
    return 0
  fi
  local dsys; dsys=$(kb "dedicated_systems.$want.system")
  if [ -n "$dsys" ] && [ "$dsys" != "null" ]; then
    PT_CHAN_SYS="$dsys"
    pt_log "[resolve] channel '$want' ($cname) -> dedicated system $dsys (no KB module yet; system-scoped sweep, discovery skipped)"
    pt_note "- resolve: channel '$want' ($cname) via channel_codes -> dedicated system $dsys (module stub pending; blind discovery skipped)"
    return 0
  fi
  local sc; sc=$(kb "channel_codes.codes.$want.channelrelay")
  if [ "$sc" = "True" ] || [ "$sc" = "true" ]; then
    PT_CHAN_SYS=$(kb "channelrelay.system")
    PT_CHAN_APPS=$(kb "channelrelay.apps" | python3 -c "import json,sys;d=sys.stdin.read().strip();print(' '.join(json.loads(d) if d and d!='null' else []))" 2>/dev/null)
    pt_log "[resolve] channel '$want' ($cname) is ChannelRelay -> apps:$PT_CHAN_APPS (blind discovery skipped)"
    pt_note "- resolve: channel '$want' ($cname) via channel_codes -> ChannelRelay $PT_CHAN_SYS; blind discovery skipped"
  fi
}

pt_resolve() { # -> sets PT_CHAN_SYS, PT_CHAN_APPS; ledger to resolve.tsv
  pt_channel_from_codes
  PT_CHAN_SYS="${PT_CHAN_SYS:-}"; PT_CHAN_APPS="${PT_CHAN_APPS:-}"
  : > "$PT_RUN_DIR/resolve.tsv"
  PT_STALE_APPS=""; PT_POOL=""; PT_CATALOG_ONLY=""
  if [ -n "$PT_CHAN" ]; then
    # R20 (v0.9.4b4): KB app paths are AUTHORITATIVE for the channel system. Catalog
    # name-matching collides with co-tenant apps: OTA5 matched channels-hub/ota5-api,
    # sort put 'channels-hub' before 'cm-ota5', head -1 picked the WRONG sys, then the
    # stale check convicted good KB apps against the WRONG pool and swept 17 foreign
    # apps (case CASE-00000001, run killed). channels-hub has its own prefix/channels; an
    # OTA5- ref is the cm-ota5 connector - the KB module says so via its app paths.
    local firstapp; firstapp=$(kb "channels.$PT_CHAN.log_apps.reservation_inbound" | tr ' ' '\n' | grep -m1 '/')
    [ -z "$firstapp" ] && firstapp=$(kb "channels.$PT_CHAN.log_apps.ari_outbound" | tr ' ' '\n' | grep -m1 '/')
    [ -z "$firstapp" ] && firstapp=$(kb "channels.$PT_CHAN.log_apps.other_apps" | tr ' ' '\n' | grep -m1 '/')
    if [ -n "$firstapp" ]; then
      PT_CHAN_SYS="${firstapp%%/*}"
      echo "sys_from_kb_apps|$PT_CHAN|$PT_CHAN_SYS" >> "$PT_RUN_DIR/resolve.tsv"
      pt_log "[resolve] sys=$PT_CHAN_SYS from KB app paths (authoritative; catalog name-match skipped)"
    else
      # v0.9.7b2 (case CASE-00000002): thin KB module (no usable app paths) used to fall straight to
      # catalog name-match, which landed OTA6 on an unrelated vendor system and swept the WRONG system for ~1h.
      # Prefer the cm-<prefix> convention, but ONLY if the pool verifies the system exists.
      local conv="cm-$(echo "$PT_PREFIX" | tr 'A-Z' 'a-z')"
      if [ -n "$PT_PREFIX" ] && [ -n "$(pt_pool "$conv" 2>/dev/null)" ]; then
        PT_CHAN_SYS="$conv"
        echo "sys_from_convention|$PT_CHAN|$PT_CHAN_SYS" >> "$PT_RUN_DIR/resolve.tsv"
        pt_log "[resolve] no KB app paths - sys=$PT_CHAN_SYS from cm-<prefix> convention (pool-verified; name-match skipped)"
      else
        local am; am=$(kb "channels.$PT_CHAN.app_match")
        PT_CHAN_SYS=$(pt_sys_candidates "${am:-$PT_PREFIX}" | head -1)
        echo "sys_from_namematch|$PT_CHAN|${PT_CHAN_SYS:-none}" >> "$PT_RUN_DIR/resolve.tsv"
        pt_log "[resolve] no KB app paths and convention failed - sys=$PT_CHAN_SYS from catalog name-match (UNVERIFIED last resort)"
      fi
    fi
    PT_CHAN_APPS="$(kb "channels.$PT_CHAN.log_apps.reservation_inbound") $(kb "channels.$PT_CHAN.log_apps.ari_outbound") $(kb "channels.$PT_CHAN.log_apps.other_apps" | python3 -c "import json,sys;d=sys.stdin.read().strip();print(' '.join(json.loads(d) if d and d!='null' else []))" 2>/dev/null)"
    echo "kb_module|$PT_CHAN|sys=${PT_CHAN_SYS:-?}|apps=$PT_CHAN_APPS" >> "$PT_RUN_DIR/resolve.tsv"
    pt_log "[resolve] KB module $PT_CHAN: sys=${PT_CHAN_SYS:-?} apps=$PT_CHAN_APPS"
    # stale check: ONLY a verified per-system pool may convict a KB app
    if [ -n "$PT_CHAN_SYS" ]; then
      PT_POOL=$(pt_pool "$PT_CHAN_SYS" | tr '
' ' ')
      if [ -n "$PT_POOL" ]; then
        pt_log "[resolve] pool for $PT_CHAN_SYS ($(echo $PT_POOL | wc -w) apps, verified listing): $(echo $PT_POOL | sed "s|$PT_CHAN_SYS/||g")"
        echo "pool|$PT_CHAN_SYS|$(echo $PT_POOL | tr ' ' ',')" >> "$PT_RUN_DIR/resolve.tsv"
      else
        pt_log "[resolve] WARN: no verified pool for $PT_CHAN_SYS - stale-check SKIPPED, KB apps trusted (an unverified catalog convicts nothing)"
        echo "stale_check|$PT_CHAN|SKIPPED - pool unverified, KB trusted" >> "$PT_RUN_DIR/resolve.tsv"
      fi
    fi
    local a ok_apps=""
    for a in $PT_CHAN_APPS; do
      # R5' (v0.8.0b2): a bare system name (thin module) is system-sweep intent, NOT a
      # stale app - dropping it used to zero the trusted list and force a full-pool
      # sweep behind a misleading "every KB app stale" line (run CASE-00000004).
      case "$a" in */*) : ;; *) ok_apps="$ok_apps $a"; pt_log "[resolve] KB entry '$a' is system-level (thin module) - kept as system sweep intent"; continue;; esac
      if [ -z "$PT_POOL" ]; then ok_apps="$ok_apps $a"; continue; fi
      if echo " $PT_POOL " | grep -q " $a "; then
        ok_apps="$ok_apps $a"
      else
        PT_STALE_APPS="$PT_STALE_APPS $a"
        local hint; hint=$(echo $PT_POOL | tr ' ' '
' | grep -i "$(pt_app_comp "$a" | cut -c1-6)" | head -3 | tr '
' ' ')
        echo "kb_stale|$PT_CHAN|$a|not in verified pool|closest:${hint:-none}" >> "$PT_RUN_DIR/resolve.tsv"
        pt_log "[resolve] STALE KB app: $a (not in verified pool; closest:${hint:-none}) - excluded from trusted sweep"
      fi
    done
    PT_CHAN_APPS=$(echo $ok_apps | tr ' ' '
' | grep -v '^$' | tr '
' ' ')
    # catalog-only: live-pool apps the KB does not know - recorded; swept only if the trusted pass is empty
    if [ -n "$PT_POOL" ]; then
      local p
      for p in $PT_POOL; do
        case " $PT_CHAN_APPS " in *" $p "*) : ;; *) PT_CATALOG_ONLY="$PT_CATALOG_ONLY $p"; echo "catalog_only|$PT_CHAN|$p|in live pool, not in KB" >> "$PT_RUN_DIR/resolve.tsv";; esac
      done
      if [ -z "${PT_CHAN_APPS// /}" ]; then PT_CHAN_APPS="$PT_POOL"; PT_CATALOG_ONLY=""; pt_log "[resolve] every KB app stale - sweeping the full verified pool"; fi
    fi
  fi
  if [ -z "$PT_CHAN_SYS" ]; then
    # alias candidates: prefix itself, cm-<prefix>, and any KB channel whose app_match exists
    local cand c sysc
    for cand in "$PT_PREFIX" "cm-$PT_PREFIX"; do
      sysc=$(pt_sys_candidates "$cand" | head -1)
      if [ -n "$sysc" ]; then PT_CHAN_SYS="$sysc"; echo "catalog_alias|$cand|sys=$sysc" >> "$PT_RUN_DIR/resolve.tsv"; break; fi
    done
    # last resort: every KB channel app_match not already tried (prefix unknown to KB)
    if [ -z "$PT_CHAN_SYS" ]; then
      for c in $(kb_list channels); do
        local am2; am2=$(kb "channels.$c.app_match")
        [ -z "$am2" ] || [ "$am2" = "null" ] && continue
        sysc=$(pt_sys_candidates "$am2" | head -1)
        [ -n "$sysc" ] && echo "kb_app_match_available|$c|$sysc (not matched to prefix $PT_PREFIX)" >> "$PT_RUN_DIR/resolve.tsv"
      done
    fi
  fi
  [ -n "$PT_CHAN_SYS" ] && pt_log "[resolve] channel system: $PT_CHAN_SYS"
  [ -z "$PT_CHAN_SYS" ] && pt_log "[resolve] WARN: no channel system resolved - trace will lean on pms-hub + harvest"
}

# ---- --at window: typed AT taken AS-IS (CM admin / log timeline) --------------
# PT_TZ_OFFSET is informational only (what the property platform shows); it must
# NEVER shift the discovery hour - tz weirdness is absorbed by the anchor drift.
PT_AT_DATE=""; PT_AT_HOUR=""; PT_ANCHOR=""
if [ -n "$PT_AT" ]; then
  PT_AT_DATE="${PT_AT%%[T ]*}"
  _at_rest="${PT_AT##*[T ]}"
  PT_AT_HOUR="${_at_rest%%:*}"
  [ -n "$PT_FROM" ] || PT_FROM="$PT_AT_DATE"
  [ -n "$PT_TO" ]   || PT_TO="$PT_AT_DATE"
  echo "[window] booking ts=$PT_AT taken AS-IS (log timeline); tz_offset=$PT_TZ_OFFSET informational (property platform tz), NOT applied; uncertain=$PT_AT_UNCERTAIN fanout=+/-$PT_FANOUT_HOURS"
fi
[ -n "$PT_FROM" ] || PT_FROM=$(date -u +%F); [ -n "$PT_TO" ] || PT_TO="$PT_FROM"

pt_hours_plan() { # fanout -> hour prefixes, DAY-CROSSING; anchor-locked -> anchor +/-1h
  # epoch arithmetic: GNU date relative strings ("-3 hours") mis-parse next to a
  # datetime (tz ambiguity) - always shift in seconds from a pinned epoch
  local fan="${1:-0}" i base base_s
  if [ -n "${PT_ANCHOR:-}" ]; then
    base_s=$(date -u -d "${PT_ANCHOR:0:10} ${PT_ANCHOR:11:2}:00:00" +%s)
    for i in -1 0 1; do date -u -d "@$((base_s + i * 3600))" +'%F-%H'; done
    return 0
  fi
  [ -z "$PT_AT_HOUR" ] && return 0
  base_s=$(date -u -d "$PT_AT_DATE $PT_AT_HOUR:00:00" +%s)
  for i in $(seq -- "-$fan" "$fan"); do
    date -u -d "@$((base_s + i * 3600))" +'%F-%H'
  done
}

# ---- fetch with rc + stderr capture ------------------------------------------
pt_app_sys()  { echo "${1%%/*}"; }
pt_app_comp() { case "$1" in */*) echo "${1#*/}";; *) echo "*";; esac; }

pt_fetch() { # app blob pattern outfile
  local app="$1" blob="$2" pat="$3" out="$4"
  local sys comp; sys=$(pt_app_sys "$app"); comp=$(pt_app_comp "$app")
  # R18 (v0.9.4b2): an empty pattern is a match-ALL grep (co-tenant dump). Refuse and
  # mark UNVERIFIED - never absent (case CASE-00000001: fabricated/blank CM hotel uuid input).
  if [ -z "$pat" ]; then
    echo "[fetch] REFUSED: empty pattern ($app $blob) - a required input is blank" >> "$out.stderr"
    pt_note "- FETCH skipped: $app $blob (empty pattern - blank input; UNVERIFIED, not absent)"
    return 0
  fi
  # R21 (v0.9.5b1): weak bare-numeric patterns flood runs with co-tenant/timestamp lines
  # (live disaster: '12345' -> 2.6MB of garbage). Refuse <=5 digits; warn on 6-7 (proven-good
  # ids like membership 600000-class stay allowed but get flagged for field-anchored follow-up).
  if [[ "$pat" =~ ^[0-9]{1,5}$ ]]; then
    echo "[fetch] REFUSED: weak numeric pattern '$pat' (<=5 digits) at $app $blob - matches timestamps/ids everywhere; use a field-anchored pattern" >> "$out.stderr"
    pt_note "- FETCH skipped: $app $blob (R21 weak numeric '$pat'; UNVERIFIED, not absent)"
    return 0
  fi
  if [[ "$pat" =~ ^[0-9]{6,7}$ ]]; then
    echo "[fetch] LOW-SELECTIVITY warn: bare numeric '$pat' at $app $blob - if output floods, re-run field-anchored" >> "$out.stderr"
  fi
  if [ "$sys" = "pms-hub" ] && [ "$comp" = "*" ]; then
    case "$blob" in *-[0-9][0-9]) : ;; *)
      echo "[fetch] REFUSED: pms-hub '*' full-day ($app $blob) - hour-bounded only" >> "$out.stderr"; return 1;; esac
  fi
  # R9 (v0.8.0b3): cap fetched output - a hot token once dumped 1.1M lines/>1GB into the
  # run dir and the fetch got SIGKILLed (rc=137). Cap at PT_FETCH_MAX_LINES; SIGPIPE-style
  # exits (141/120) after a full cap still count as evidence.
  pt_s3 grep "$sys" "$comp" "$blob" "$pat" 2>"$out.stderr" | head -n "${PT_FETCH_MAX_LINES:-200000}" >> "$out"
  local rc=${PIPESTATUS[0]}
  if [ "$rc" = "141" ] || [ "$rc" = "120" ]; then
    echo "[fetch] note: output capped at ${PT_FETCH_MAX_LINES:-200000} lines ($app $blob)" >> "$out.stderr"; rc=0
  fi
  echo "$rc" > "$out.rc"
  [ $rc -gt 1 ] && echo "[fetch] WARN rc=$rc $app $blob '$pat' - see $out.stderr"
  return $rc
}

pt_qfetch() { # app blob 's.field = "x"' outfile - query-mode fetch (token/actor correlation)
  local app="$1" blob="$2" q="$3" out="$4"
  local sys comp; sys=$(pt_app_sys "$app"); comp=$(pt_app_comp "$app")
  pt_s3 query "$sys" "$comp" "$blob" "$q" 2>"$out.stderr" | head -n "${PT_FETCH_MAX_LINES:-200000}" >> "$out"
  local rc=${PIPESTATUS[0]}
  { [ "$rc" = "141" ] || [ "$rc" = "120" ]; } && rc=0
  echo "$rc" > "$out.rc"
  [ $rc -gt 1 ] && echo "[fetch] WARN rc=$rc $app $blob query - see $out.stderr"
  return $rc
}

# ---- stage runner: resume + ledger -------------------------------------------
PT_N=0
pt_log() { echo "[$(date -u +%H:%M:%S)] $*"; }
pt_chan_code() { # channel code regardless of mode (PT_CHAN is trace-mode only; PT_CHANNEL is the input)
  local c="${PT_CHAN:-$PT_CHANNEL}"
  if [ -z "$c" ] && [ -n "$PT_REF" ]; then
    c=$(python3 - "$PT_REF" <<'PYCC'
import json, os, sys
head = sys.argv[1].upper().split("-")[0].split(":")[0]
codes = json.load(open(os.environ["PT_KB_PATH"])).get("channel_codes", {}).get("codes", {})
print(head if head in codes else "")
PYCC
)
  fi
  echo "$c"
}
pt_is_channelrelay() { local c; c=$(pt_chan_code); [ -n "$c" ] && [ "$(kb "channel_codes.codes.$c.channelrelay" 2>/dev/null)" = "True" ]; }

# ---- R22 (v0.9.6-lgcy): LEGACY-STACK ChannelRelay legs ---------------------------------
# ChannelRelay split-brain (verified case CASE-00000005 / OTA-X / PROPERTY-ALPHA, 2026-11-02):
#   reservations -> CUR cm-channelrelay/booking-gateway (OTA_HotelResNotifRQ)
#   ARI pushes   -> LGCY sync-engine partition engines, s3grep buckets
#                   channelrelay*sync*partition*<one|two|three>*log*<region>*,
#                   key listingAcctId=<id>; header carries ownerId/listingAcctId/
#                   sourceAgentCode/propertyUuid/channelPropertyUuid; RQ/RS pair by EchoToken;
#                   RS carries <Success/> or Errors. CUR cm-channelrelay/avail-gateway
#                   carries NO ARI traffic - never gate on it for ChannelRelay channels.
pt_lgcy_fetch() { # pattern bucketglob day outfile
  local pat="$1" bucket="$2" day="$3" out="$4"
  if [ -z "${PT_S3GREP:-}" ]; then
    echo "[lgcy] FATAL: s3grep.py not found on PATH" >> "$out.stderr"; echo 2 > "$out.rc"; return 2
  fi
  timeout "$PT_SEARCH_TIMEOUT" "$PT_S3GREP" find "$pat" "$bucket" "$day" 2>"$out.stderr" | head -n "${PT_FETCH_MAX_LINES:-200000}" >> "$out"
  local rc=${PIPESTATUS[0]}
  echo "$rc" > "$out.rc"
  [ "$rc" -gt 1 ] && echo "[lgcy] WARN rc=$rc '$pat' $bucket $day - see $out.stderr"
  return $rc
}

pt_lgcy_partition_order() {
  local order known
  order=$(kb "channelrelay_lgcy.default_partition_order" 2>/dev/null); [ -z "${order// /}" ] && order="three one two"
  known=$(kb "channelrelay_lgcy.partitions.$(pt_chan_code).partition" 2>/dev/null)
  [ -n "${known// /}" ] && order="$known $(echo $order | tr ' ' '\n' | grep -vx "$known" | tr '\n' ' ')"
  echo "$order"
}

pt_ari_push_lgcy() {
  pt_is_channelrelay || return 0
  if [ -z "$PT_MEMBERSHIP" ]; then pt_log "[lgcy] no PT_MEMBERSHIP - LGCY ARI leg skipped"; pt_note "- LGCY_ARI: skipped (no membership id)"; return 0; fi
  local p day n hit sn bkt
  local chan; chan=$(pt_chan_code)
  pt_log "[lgcy] ChannelRelay $chan - LGCY ARI leg: key=listingAcctId=$PT_MEMBERSHIP partitions:$(pt_lgcy_partition_order)"
  pt_note "- LGCY_ARI leg: ChannelRelay $PT_CHAN - buckets channelrelay*sync*partition*<p>*log*${PT_LGCY_REGION_SUFFIX:-r1}*, key listingAcctId=$PT_MEMBERSHIP, $PT_AT_DATE back ${PT_LGCY_LOOKBACK_DAYS:-7}d (first hit day + one baseline day, then stop)"
  for p in $(pt_lgcy_partition_order); do
    hit=0; day="$PT_AT_DATE"; n=0
    while :; do
      n=$((n+1))
      bkt="channelrelay*sync*partition*${p}*log*${PT_LGCY_REGION_SUFFIX:-r1}*"
      sn="t_ari_push_lgcy_${p}_${day}"
      pt_run_stage "$sn" "lgcy-sync/$p $day listingAcctId=$PT_MEMBERSHIP" \
        "pt_lgcy_fetch 'listingAcctId=$PT_MEMBERSHIP' '$bkt' '$day' '$PT_RUN_DIR/raw/$sn.out'"
      [ -s "$PT_RUN_DIR/raw/$sn.out" ] && hit=1
      if [ "$hit" = 1 ] && [ $n -ge 2 ]; then break; fi
      [ $n -ge "${PT_LGCY_LOOKBACK_DAYS:-7}" ] && break
      [ "$day" = "$PT_FROM" ] && break
      day=$(date -u -d "$day -1 day" +%F)
    done
    [ "$hit" = 1 ] && break
  done
}

pt_ari_lgcy_report() {
  pt_is_channelrelay || return 0
  python3 - "$PT_RUN_DIR" "$PT_STAY_DATES" "$PT_RATE_CODE" "$PT_ROOM_TYPE_CODE" <<'PYOWEOF'
import glob, os, re, sys
run, dts, rate, room = sys.argv[1], set(sys.argv[2].split()), sys.argv[3], sys.argv[4]
files = sorted(glob.glob(os.path.join(run, "raw", "t_ari_push_lgcy_*.out")))  # t_ari_push_lgcy_* also feeds the verdict CHANNEL_PUSH/OTA_ACK gates
rq = rs_ok = rs_err = 0
seg = re.compile(r'<StatusApplicationControl End="([^"]+)" InvTypeCode="([^"]+)" RatePlanCode="([^"]+)" Start="([^"]+)"/>')
amt = re.compile(r'AmountAfterTax="([0-9.]+)"')
tsp = re.compile(r'TimeStamp="([^"]+)"')
hits = []
for f in files:
    for line in open(f, encoding="latin-1"):
        if "OTA_HotelRateAmountNotifRQ" in line:
            rq += 1
            ts = tsp.search(line)
            for end, inv, rp, start in seg.findall(line):
                if dts and not any(start <= d <= end for d in dts): continue
                if room and inv != room: continue
                if rate and rp != rate: continue
                a = amt.search(line[line.find(end):])
                hits.append((ts.group(1) if ts else "?", start, end, inv, rp, a.group(1) if a else "?"))
        if "NotifRS" in line:
            if "<Success" in line: rs_ok += 1
            if "Errors" in line or "Fault" in line: rs_err += 1
with open(os.path.join(run, "REPORT.md"), "a") as r:
    r.write("\n### LGCY ARI pushes (ChannelRelay legacy-stack sync partitions)\n")
    if not files:
        r.write("- no LGCY scans ran (leg skipped or s3grep.py missing)\n")
    elif rq == 0:
        r.write("- LGCY scans ran (%d day-files) but ZERO RateAmountNotifRQ for this membership - pushes NOT evidenced in scanned days (elimination fact, NOT proof of absence beyond the bound)\n" % len(files))
    else:
        r.write("- RateAmountNotifRQ=%d  RS Success=%d  RS Errors=%d\n" % (rq, rs_ok, rs_err))
        for t, s, e, i, p, a in hits[:40]:
            r.write("  - %s %s..%s %s / %s = %s\n" % (t, s, e, i, p, a))
PYOWEOF
}

pt_ari_booking_xml_lgcy() {
  pt_is_channelrelay || return 0
  [ -n "$PT_BOOKING_REF" ] || return 0
  if ls "$PT_RUN_DIR"/raw/t_ari_xml_*.out >/dev/null 2>&1 && grep -lq . "$PT_RUN_DIR"/raw/t_ari_xml_*.out 2>/dev/null; then
    pt_log "[lgcy] CUR XML leg produced hits - LGCY XML fallback skipped"; return 0
  fi
  pt_note "- LGCY_XML fallback: CUR cm-channelrelay produced no booking XML - scanning LGCY partitions for '$PT_BOOKING_REF' on $PT_AT_DATE"
  local p sn
  for p in $(pt_lgcy_partition_order); do
    sn="t_ari_owxml_${p}_${PT_AT_DATE}"
    pt_run_stage "$sn" "lgcy-part/$p $PT_AT_DATE '$PT_BOOKING_REF'" \
      "pt_lgcy_fetch '$PT_BOOKING_REF' 'channelrelay*partition*${p}*log*${PT_LGCY_REGION_SUFFIX:-r1}*' '$PT_AT_DATE' '$PT_RUN_DIR/raw/$sn.out'"
    [ -s "$PT_RUN_DIR/raw/$sn.out" ] && break
  done
}

pt_note() { echo "$*" >> "$PT_RUN_DIR/REPORT.md"; }
pt_sanitize() { echo "$1" | tr '/ *' '___' | tr -cd 'A-Za-z0-9_.-'; }

pt_run_stage() {
  local name="$1" label="$2" cmd="$3"
  local _sk
  for _sk in $PT_SKIP_LEGS; do
    case "$name" in *"$_sk"*) pt_log "[skip] $name (PT_SKIP_LEGS)"; echo "$name|skipped-by-PT_SKIP_LEGS|rc=0|lines=0" >> "$PT_RUN_DIR/ledger.tsv"; return 0;; esac
  done
  PT_N=$((PT_N + 1))
  if [ "$PT_RESUME" = "1" ] && [ -f "$PT_RUN_DIR/state/$name.done" ]; then
    pt_log "[$PT_N] SKIP $name (done)"; return 0
  fi
  pt_log "[$PT_N] RUN  $name - $label"
  if [ "$PT_MODE" = "plan" ]; then echo "  PLAN [$name] $cmd" | tee -a "$PT_RUN_DIR/REPORT.md"; return 0; fi
  ( eval "$cmd" ) >> "$PT_RUN_DIR/raw/$name.stdout" 2>&1
  local rc=$?
  local lines
  if [ -f "$PT_RUN_DIR/raw/$name.out" ]; then lines=$(grep -c . "$PT_RUN_DIR/raw/$name.out" 2>/dev/null)
  else lines=$(grep -c . "$PT_RUN_DIR/raw/$name.stdout" 2>/dev/null); fi
  lines=${lines:-0}
  if [ "$rc" -le 1 ]; then touch "$PT_RUN_DIR/state/$name.done"
  elif [ "$rc" -eq 124 ]; then pt_log "[$PT_N] TIMEOUT $name - re-paste retries it"; fi
  echo "$name|$label|rc=$rc|lines=$lines" >> "$PT_RUN_DIR/ledger.tsv"
  pt_log "[$PT_N] DONE $name rc=$rc lines=$lines"
  return 0
}

# ---- KB write-back (unconditional .bak + live & zero-hit stub persistence) ----
# Every live run (hits OR zero hits) records itself in the KB. Sequence, under an exclusive lock
# (fcntl - works on Linux and macOS; protects concurrent detached runs from lost updates):
#   re-read live KB -> timestamped .bak of it -> merge -> write tmp -> atomic rename.
# Skipped only in PT_MODE=plan (dry run) or when the KB is not writable.
# Retention: PT_KB_BAK_KEEP newest .bak files (default 20); PT_KB_HISTORY_KEEP entries per module (default 50).
pt_kb_write() { # create_or_dash [pat:/win:/sig:/keys:/stale: args] apps...
  [ "$PT_MODE" = "plan" ] && { echo "[kb-write] plan mode - KB untouched"; return 0; }
  [ -w "$PT_KB_PATH" ] || { echo "[kb-write] KB not writable at $PT_KB_PATH, skipping"; return 0; }
  python3 - "$PT_KB_PATH" "$PT_CASE" "$PT_REF" "$PT_CHAN" "${PT_PMS_EFFECTIVE:-$PT_PMS}" "$(date -u +%F)" "$PT_PREFIX" "${PT_CHAN_SYS:-}" "$(date -u +%Y%m%dT%H%M%SZ)" "${PT_KB_BAK_KEEP:-20}" "${PT_KB_HISTORY_KEEP:-50}" "$@" <<'PYEOF'
import json, sys, os, glob, shutil, fcntl
path, case, ref, chan, pms, today, prefix, chan_sys, stamp, bak_keep, hist_keep = sys.argv[1:12]
bak_keep, hist_keep = int(bak_keep), int(hist_keep)
create = ""; apps = []
extra = {"patterns_hit": [], "window_mode": [], "signatures": [], "key_kinds": [], "stale_repaired": []}
for a in sys.argv[12:]:
    if a.startswith("create:"): create = a.split(":", 1)[1]
    elif a.startswith("pat:"):   extra["patterns_hit"] = [x for x in a[4:].split(",") if x]
    elif a.startswith("win:"):   extra["window_mode"].append(a[4:])
    elif a.startswith("sig:"):   extra["signatures"].append(a[4:])
    elif a.startswith("keys:"):  extra["key_kinds"] = [x for x in a[5:].split(",") if x]
    elif a.startswith("stale:"): extra["stale_repaired"].append(a[6:])
    elif a and a != "-": apps.append(a)

lock = open(path + ".lock", "w")
fcntl.flock(lock, fcntl.LOCK_EX)
try:
    with open(path) as f:
        kb = json.load(f)                      # refuse to back up / overwrite an unreadable KB
    bak = "%s.bak.%s.%d" % (path, stamp, os.getpid())
    shutil.copy2(path, bak)
    print("[kb-write] backup saved: " + bak)

    target_chan = (chan or create or prefix or "").strip().upper()
    hist = {"ts": today, "case": case, "mode": "trace-run", "ref": ref or None,
            "apps_confirmed_live": apps, "source": "trace run, case " + case}
    for k, v in extra.items():
        if v: hist[k] = v

    def sys_of(a): return a.split("/", 1)[0]

    def repair_stale(mod):
        if not extra["stale_repaired"]: return
        fixed = mod.setdefault("_stale_repaired", [])
        la = mod.get("log_apps") or {}
        for s in extra["stale_repaired"]:
            for k, v in list(la.items()):
                if v == s: la[k] = None
                elif isinstance(v, list) and s in v: la[k] = [x for x in v if x != s]
            for lst_key in ("other_apps", "delivery_apps", "inventory_apps"):
                if isinstance(mod.get(lst_key), list) and s in mod[lst_key]:
                    mod[lst_key] = [x for x in mod[lst_key] if x != s]
            fixed.append({"app": s, "marked": today, "by": "pms_trace auto-writeback, case " + case})

    def touch(mod):
        h = mod.setdefault("history", [])
        h.append(hist)
        if hist_keep > 0 and len(h) > hist_keep: del h[:len(h) - hist_keep]
        ea = mod.setdefault("example_anchors", {})
        if ref and not ea.get("reservation"): ea["reservation"] = ref
        ea["verified_at"] = today
        return mod

    added_c = added_p = 0
    if target_chan:
        if target_chan not in kb.setdefault("channels", {}):
            kb["channels"][target_chan] = {
                "name": "UNKNOWN - stub created by auto-writeback; complete manually",
                "code": target_chan, "integration": None,
                "ref_prefixes": [(ref.split("-")[0] + "-") if ref and "-" in ref else (target_chan + "-")],
                "log_apps": {"reservation_inbound": None, "ari_outbound": None},
                "behavior_rules": [], "capabilities": {}, "example_anchors": {},
                "_stub_created": today, "_stub_by": "pms_trace auto-writeback, case " + case}
            print("[kb-write] created channel stub channels." + target_chan)
        m = touch(kb["channels"][target_chan])
        repair_stale(m)
        la = m.setdefault("log_apps", {})
        concrete = [a for a in apps if not a.endswith("/*") and "/" in a]
        # channel module caches ONLY its own system's apps (hub-channel-store / pms-* are shared legs)
        csys = chan_sys or (sys_of(la["reservation_inbound"]) if la.get("reservation_inbound") else "")
        own = [a for a in concrete if csys and sys_of(a) == csys]
        if not la.get("reservation_inbound") and own:
            la["reservation_inbound"] = own[0]; la["_confirmed_by"] = "live trace, case " + case
        known = {la.get("reservation_inbound"), la.get("ari_outbound")}
        oa = la.get("other_apps") if isinstance(la.get("other_apps"), list) else []
        for a in own:
            if a not in known and a not in oa: oa.append(a); added_c += 1
        if oa: la["other_apps"] = oa

    if pms and pms in kb.get("pms", {}):
        m = touch(kb["pms"][pms])
        repair_stale(m)
        da = m.setdefault("delivery_apps", [])
        psys = {sys_of(a) for a in da}
        for a in apps:
            if a.endswith("/*") or "/" not in a: continue
            if (sys_of(a) in psys or sys_of(a).startswith("pms-")) and a not in da:
                da.append(a); added_p += 1

    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(kb, f, indent=1); f.write("\n"); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, path)
    baks = sorted(glob.glob(path + ".bak.*"), key=os.path.getmtime, reverse=True)
    for old in baks[bak_keep:]:
        try: os.remove(old)
        except OSError: pass
    print("[kb-write] updated (channels.%s +%d apps, pms.%s +%d apps, history appended; %d .bak kept)"
          % (target_chan or '-', added_c, pms or '-', added_p, min(len(baks), bak_keep)))
finally:
    fcntl.flock(lock, fcntl.LOCK_UN); lock.close()
PYEOF
}

# ---- preflight: one positive control per system ------------------------------
pt_ctlapp() { case "$1" in pms-hub) echo "pms-hub/booking-api";; cm) echo "cm/avail-api-ra";; *) echo "$1/*";; esac; } # R6 (v0.8.0b2): cm control component-scoped - cm/* sys-wide exceeded 900s live
pt_preflight() { # systems... -> rc 0 when every system answered the control
  local sys ctl_out lines rc=0
  for sys in "$@"; do
    ctl_out="$PT_RUN_DIR/raw/preflight_$(pt_sanitize "$sys").stdout"
    local tok="$PT_CONTROL_TOKEN"; [ "$sys" = "cm" ] && tok="${PT_CONTROL_TOKEN_CM:-propertyUuid}"
    if [ -n "$PT_AT_DATE" ]; then
      PT_FETCH_MAX_LINES=200 PT_SEARCH_TIMEOUT="$PT_PREFLIGHT_TIMEOUT" pt_fetch "$(pt_ctlapp "$sys")" "$(pt_hours_plan 0 | head -1)" "$tok" "$ctl_out"
    else
      PT_FETCH_MAX_LINES=200 PT_SEARCH_TIMEOUT="$PT_PREFLIGHT_TIMEOUT" pt_fetch "$(pt_ctlapp "$sys")" "${PT_FROM}-*" "$tok" "$ctl_out"
    fi
    lines=$(grep -c . "$ctl_out" 2>/dev/null); lines=${lines:-0}
    if [ "$lines" -eq 0 ]; then
      pt_log "[preflight] FAIL $sys: control '$tok' returned 0 lines - empty results for this system are UNVERIFIED"
      pt_note "- **PREFLIGHT FAIL $sys** - control returned 0 lines; empty sweeps for this system are UNVERIFIED (pipe, retention or wrong system)."
      rc=1
    else
      pt_log "[preflight] OK $sys ($lines lines) - empty sweeps for this system are trustworthy"
      pt_note "- preflight control $sys: OK ($lines lines)"
    fi
  done
  return $rc
}

# ---- evidence-hour registry: apps with proven hours drive their own plan ------
pt_hours_refresh() { # rebuild hours.tsv: sanitized_app <TAB> hour, ref-matched lines only
  python3 - "$PT_RUN_DIR" $(pt_variants "$PT_REF") <<'PYEOF'
import glob, os, re, sys
run, pats = sys.argv[1], sys.argv[2:]
TAGS = ("anchorfd_fd", "fallback", "anchorfd", "disc", "lad", "pms", "kb", "cat", "sys")
hours = {}
for f in sorted(glob.glob(os.path.join(run, "raw", "t_*.out"))):
    b = os.path.basename(f)[:-4]
    app = None
    for tag in TAGS:
        if b.startswith("t_" + tag + "_"):
            app = b[len(tag) + 3:]
            break
    if not app: continue
    m = re.search(r"_20\d\d-\d\d-\d\d", app)
    if m: app = app[:m.start()]
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except Exception: continue
    for line in lines:
        if not line.strip() or line.startswith("[fetch]"): continue
        if not any(p in line for p in pats): continue
        hm = re.search(r"(20\d\d-\d\d-\d\d)[T ](\d\d)", line)
        if hm: hours.setdefault(app, set()).add("%s-%s" % (hm.group(1), hm.group(2)))
out = os.path.join(run, "hours.tsv")
with open(out, "w") as fh:
    for app in sorted(hours):
        for h in sorted(hours[app]):
            fh.write("%s\t%s\n" % (app, h))
PYEOF
}

pt_app_hours() { # app fan -> evidence hours {h,h+1} (forward) when known; else pt_hours_plan
  local app="$1" fan="${2:-0}" san hs=""
  san=$(pt_sanitize "$app")
  [ -s "$PT_RUN_DIR/hours.tsv" ] && hs=$(awk -F'\t' -v a="$san" '$1==a{print $2}' "$PT_RUN_DIR/hours.tsv" | sort -u)
  if [ -n "$hs" ]; then
    local h s out=""
    for h in $hs; do
      s=$(date -u -d "${h:0:10} ${h:11:2}:00:00" +%s)
      out="$out $(date -u -d "@$s" +'%F-%H') $(date -u -d "@$((s + 3600))" +'%F-%H')"
    done
    echo $out | tr ' ' '\n' | sort -u
  else
    pt_hours_plan "$fan"
  fi
}

# ---- sweep engine: apps x hour-plan x pattern-variants, full-day fallback -----
pt_sweep() { # tag "app1 app2 ..." [fanout]
  local tag="$1" apps="$2" fan="${3:-0}"
  local app pat bp day sn hit_any=0
  local pats; pats=$(pt_variants "$PT_REF")
  pt_hours_refresh   # registry: apps with ref-matched evidence already on disk
  for app in $apps; do
    for pat in $pats; do
      if [ -n "$PT_AT_DATE" ]; then
        for bp in $(pt_app_hours "$app" "$fan"); do
          sn="t_${tag}_$(pt_sanitize "$app")_$(pt_sanitize "$bp")_$(pt_sanitize "$pat")"
          pt_run_stage "$sn" "$app $bp '$pat'" \
            "pt_fetch '$app' '$bp' '$pat' '$PT_RUN_DIR/raw/$sn.out'"
          [ -s "$PT_RUN_DIR/raw/$sn.out" ] && hit_any=1
        done
      else
        day="$PT_FROM"
        while : ; do
          sn="t_${tag}_$(pt_sanitize "$app")_$(pt_sanitize "$day")_$(pt_sanitize "$pat")"
          pt_run_stage "$sn" "$app $day-* '$pat'" \
            "pt_fetch '$app' '${day}-*' '$pat' '$PT_RUN_DIR/raw/$sn.out'"
          [ -s "$PT_RUN_DIR/raw/$sn.out" ] && hit_any=1
          [ "$day" = "$PT_TO" ] && break
          day=$(date -u -d "$day +1 day" +%F)
        done
      fi
    done
  done
  return $hit_any
}

pt_sweep_fd() { # tag apps day - EXPLICIT full-day wildcard fallback (rc 1 = found)
  # Full-day is a deliberate escalation step, never a per-tag default (v0.7.8):
  # caller decides when the hour plan earned it. Used by pt_anchor (arrival) and
  # the GUI ladder (property keys).
  local tag="$1" apps="$2" day="$3"
  [ -n "$day" ] || return 0
  local app pat sn hit_any=0
  local pats; pats=$(pt_variants "$PT_REF")
  pt_log "[sweep_fd:$tag] full-day wildcard ${day}-* (hour plan earned the fallback)"
  for app in $apps; do
    for pat in $pats; do
      sn="t_${tag}_fd_$(pt_sanitize "$app")_$(pt_sanitize "$day")_$(pt_sanitize "$pat")"
      pt_run_stage "$sn" "$app ${day}-* '$pat'" \
        "pt_fetch '$app' '${day}-*' '$pat' '$PT_RUN_DIR/raw/$sn.out'"
      [ -s "$PT_RUN_DIR/raw/$sn.out" ] && hit_any=1
    done
  done
  return $hit_any
}

# any non-empty result from a sweep pass?
pt_any_hit() { local f; for f in "$PT_RUN_DIR/raw"/t_$1_*.out; do [ -s "$f" ] && return 0; done; return 1; }

# ---- arrival anchor: lock the live event hour, own the fallback ladder --------
pt_anchor() {
  [ -n "$PT_AT_DATE" ] || return 0
  [ -n "${PT_ANCHOR:-}" ] && return 0
  local pats; pats=$(pt_variants "$PT_REF")
  _anchor_scan() { # earliest ref-matching timestamp-hour across all pulled evidence
    python3 - "$PT_RUN_DIR" $pats <<'PYEOF'
import glob, os, re, sys
run, pats = sys.argv[1], sys.argv[2:]
best = None
for f in sorted(glob.glob(os.path.join(run, "raw", "t_*.out"))):
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except Exception: continue
    for line in lines:
        if not line.strip() or line.startswith("[fetch]"): continue
        if not any(p in line for p in pats): continue
        m = re.search(r"(20\d\d-\d\d-\d\d)[T ](\d\d)", line)
        if m:
            h = "%s-%s" % (m.group(1), m.group(2))
            if best is None or h < best: best = h
            break
print(best or "")
PYEOF
  }
  PT_ANCHOR=$(_anchor_scan)
  # fallback ladder: full-day arrival apps on the AT day
  if [ -z "$PT_ANCHOR" ] && [ "$PT_FULLDAY_FALLBACK" = "1" ]; then
    local arr_apps="${PT_CHAN_APPS:-}"
    [ -z "$arr_apps" ] && [ -n "${PT_CHAN_SYS:-}" ] && arr_apps="$PT_CHAN_SYS/*"
    if [ -n "$arr_apps" ]; then
      pt_sweep_fd "anchorfd" "$arr_apps" "$PT_AT_DATE"
      PT_ANCHOR=$(_anchor_scan)
    fi
    # day drift: near-midnight typed hours cross the day boundary
    if [ -z "$PT_ANCHOR" ] && [ -n "$arr_apps" ]; then
      local hh=$((10#$PT_AT_HOUR)) days=""
      if [ $hh -ge 20 ]; then days="+1"; elif [ $hh -le 4 ]; then days="-1"; else days="-1 +1"; fi
      local d nd
      for d in $days; do
        nd=$(date -u -d "$PT_AT_DATE $d day" +%F)
        pt_log "[anchor] day drift -> $nd-* (typed hour $PT_AT_HOUR near day boundary)"
        pt_sweep_fd "anchorfd" "$arr_apps" "$nd"
        PT_ANCHOR=$(_anchor_scan)
        [ -n "$PT_ANCHOR" ] && break
      done
    fi
  fi
  if [ -n "$PT_ANCHOR" ]; then
    local drift_h
    drift_h=$(( ( $(date -u -d "${PT_ANCHOR:0:10} ${PT_ANCHOR:11:2}:00" +%s) - $(date -u -d "$PT_AT_DATE $PT_AT_HOUR:00" +%s) ) / 3600 ))
    pt_log "[anchor] LOCKED live arrival $PT_ANCHOR (typed $PT_AT_DATE h$PT_AT_HOUR, drift ${drift_h}h) - downstream stages scan anchor +/-1h"
    pt_note "- time anchor: **$PT_ANCHOR** locked from live data (typed AT=$PT_AT, drift ${drift_h}h; tz_offset=$PT_TZ_OFFSET informational) - downstream scans = anchor +/-1h"
  else
    pt_log "[anchor] no arrival evidence in hour plan, full-day, or day drift"
    pt_note "- time anchor: NOT locked (hour plan, full-day and +/-1 day drift all empty) - downstream uses the typed hour plan"
  fi
  return 0
}

# ---- cross-run property correlation -------------------------------------------
pt_crossref() {
  python3 - "$PT_RUN_DIR" "$(dirname "$PT_RUN_DIR")" <<'PYEOF'
import glob, json, os, sys
run, runs_root = sys.argv[1], sys.argv[2]
def env_of(d):
    env = {}
    try:
        for line in open(os.path.join(d, "inputs.env")):
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1); env[k] = v
    except Exception: pass
    return env
def keys_of(d):
    keys = {}
    try:
        for line in open(os.path.join(d, "join_keys.tsv")):
            p = line.rstrip("\n").split("\t")
            if len(p) >= 2: keys.setdefault(p[0], set()).add(p[1])
    except Exception: pass
    return keys
cur_env, cur_keys = env_of(run), keys_of(run)
cur_ids = {}
for k, label in (("PT_MEMBERSHIP","membership"), ("PT_PROPERTY_ID","property_id"), ("PT_HOTEL_UUID","hotel_uuid"), ("PT_PMS_CONF","pms_conf")):
    if cur_env.get(k): cur_ids.setdefault(label, set()).add(cur_env[k])
for kind in ("hubPmsPropertyUuid", "hotelCode"):
    if kind in cur_keys: cur_ids.setdefault(kind, set()).update(cur_keys[kind])
cur_ids = {k: v for k, v in cur_ids.items() if v}
if not cur_ids: sys.exit(0)
matches = []
for d in sorted(glob.glob(os.path.join(runs_root, "*"))):
    if os.path.abspath(d) == os.path.abspath(run) or not os.path.isdir(d): continue
    o_env, o_keys = env_of(d), keys_of(d)
    shared = []
    for label, vals in cur_ids.items():
        for v in vals:
            if len(v) < 4: continue
            if v in o_env.values() or any(v in s for s in o_keys.values()):
                shared.append("%s=%s" % (label, v))
    if shared:
        codes = {}
        try: codes = json.load(open(os.path.join(d, "verdict.json"))).get("failure_codes", {})
        except Exception: pass
        matches.append((os.path.basename(d), sorted(set(shared)), codes))
if not matches: sys.exit(0)
lines = ["", "### Cross-run property correlation"]
for case, shared, codes in matches:
    lines.append("- **SAME PROPERTY as run `%s`** (shared: %s)" % (case, ", ".join(shared)))
    if codes:
        lines.append("  - that run failed with: %s - same root-cause class; one mapping fix can cover all channels of the property" % ", ".join("`%s`" % c for c in sorted(codes)))
txt = "\n".join(lines) + "\n"
open(os.path.join(run, "REPORT.md"), "a").write(txt)
print(txt)
PYEOF
}

# ---- harvest: join keys from every hit so far ---------------------------------
pt_harvest() {
  python3 - "$PT_RUN_DIR" "$PT_REF" <<'PYEOF'
import json, os, re, sys, glob
run, ref = sys.argv[1], sys.argv[2]
pats = [ref]
if "-" in ref:
    bare = ref.split("-", 1)[1]
    if bare and bare != ref: pats.append(bare)
keys = {}  # value -> {kind, first_app, first_hour}
KIND_RES = [
    ("flowToken",        re.compile(r'flowToken"?\s*[:=]\s*"?(?P<v>[0-9a-f]{8}-[0-9a-f-]{27,36})')),
    ("hubBookingUuid", re.compile(r'hubBookingUuid"?\s*[:=]\s*"?(?P<v>[0-9a-f-]{36})')),
    ("hubPmsPropertyUuid",    re.compile(r'hubPmsPropertyUuid"?\s*[:=]\s*"?(?P<v>[0-9a-f-]{36})')),
    ("pmsBookingId",  re.compile(r'pmsBookingId"?\s*[:=]\s*"?(?P<v>[A-Za-z0-9-]{4,40})')),
    ("echoToken",         re.compile(r'[Ee]choToken\\?"?\s*[:=]?\s*\\?"?(?P<v>[A-Za-z0-9-]{4,40})')),
    ("listing_id",        re.compile(r'listing_id"?\s*[:=]\s*"?(?P<v>\d{4,20})')),
    ("pmsType",           re.compile(r'pmsType"?\s*[:=]\s*"?(?P<v>[A-Z0-9_]{2,20})')),
    ("sourceAgentCode",  re.compile(r'sourceAgentCode"?\s*[:=]\s*"?(?P<v>[A-Z0-9]{2,5})')),
    ("hotelCode",         re.compile(r'HotelCode\\?"?=\\?"?(?P<v>\d{3,12})')),
    ("roomCode",          re.compile(r'(?:roomCode|roomTypeCode)"?\s*[:=]\s*"?(?P<v>[A-Za-z0-9_.-]{1,30})')),
    ("ratePlanCode",      re.compile(r'(?:ratePlanCode|rateCode)"?\s*[:=]\s*"?(?P<v>[A-Za-z0-9_.-]{1,30})')),
]
def hour_of(line, fname):
    m = re.search(r'(20\d\d-\d\d-\d\d)[T ](\d\d)', line)
    if m: return "%s-%s" % (m.group(1), m.group(2))
    m = re.search(r'(20\d\d-\d\d-\d\d)-(\d\d)', fname)
    return "%s-%s" % (m.group(1), m.group(2)) if m else ""
fd_files = fd_admitted = 0
# f_*.out = follow hits; pt_follow only sweeps HIGH-selectivity keys, so these lines are
# booking-true and may seed deeper keys (the post-follow re-harvest relies on this).
for f in sorted(glob.glob(os.path.join(run, "raw", "t_*.out"))) + sorted(glob.glob(os.path.join(run, "raw", "f_*.out"))):
    base = os.path.basename(f)
    # v0.7.7/v0.7.9 co-tenant guard: property-keyed scans (full-day sweeps AND any
    # t_lad_* ladder file - GUI keys are property-scoped at ANY hour) may only seed
    # keys from lines that carry the booking ref itself; everything else is the
    # property's other reservations (they must never spawn follow sweeps)
    is_fd = "_fd_" in base or base.startswith("t_lad_")
    if is_fd: fd_files += 1
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except Exception: continue
    for line in lines:
        if not line.strip(): continue
        if is_fd:
            if not any(p in line for p in pats): continue
            fd_admitted += 1
        for kind, rx in KIND_RES:
            for m in rx.finditer(line):
                v = m.group("v")
                if v not in keys:
                    keys[v] = {"kind": kind, "src": base, "hour": hour_of(line, base)}
out = os.path.join(run, "join_keys.tsv")
with open(out, "w") as fh:
    for v, meta in sorted(keys.items(), key=lambda kv: kv[1]["hour"]):
        fh.write("%s\t%s\t%s\t%s\n" % (meta["kind"], v, meta["hour"], meta["src"]))
print("[harvest] %d join keys -> %s" % (len(keys), out))
if fd_files:
    print("[harvest] property/full-day guard: %d property-keyed file(s), %d ref-matching line(s) admitted; co-tenant lines ignored" % (fd_files, fd_admitted))
PYEOF
}

# ---- follow: re-scan the chain with harvested keys ----------------------------
pt_follow() {
  [ "$PT_FOLLOW" = "1" ] || return 0
  [ -s "$PT_RUN_DIR/join_keys.tsv" ] || { pt_log "[follow] no join keys harvested"; return 0; }
  local kind key hour src n=0
  local chan_sys="${PT_CHAN_SYS:-}"
  local _lowk; _lowk=$(kb_list low_selectivity_kinds 2>/dev/null)
  [ -z "$_lowk" ] && _lowk="pmsType hubPmsPropertyUuid roomCode ratePlanCode sourceAgentCode hotelCode"
  while IFS=$'\t' read -r kind key hour src; do
    [ "$kind" = "pmsBookingId" ] && continue   # same string family as the ref; already scanned
    case " $_lowk " in *" $kind "*) pt_log "[follow] $kind=$key - context-only (low selectivity, co-tenant risk); not swept" >> "$PT_RUN_DIR/REPORT.md"; continue;; esac
    n=$((n + 1)); [ "$n" -gt "${PT_MAX_FOLLOW_KEYS:-12}" ] && break
    local hb="${hour:-${PT_AT_DATE:-$PT_FROM}-00}"
    local dayp="${hb%-*}"
    local hh h10
    h10=$(echo "$hb" | sed -n 's/.*-\([0-9][0-9]\)$/\1/p'); h10=${h10:-00}
    local hlo=$((10#$h10 - 1)) hhi=$((10#$h10 + 1))
    [ $hlo -lt 0 ] && hlo=0; [ $hhi -gt 23 ] && hhi=23
    local hh_list=""
    for hh in $(seq $hlo $hhi); do hh_list="$hh_list $(printf '%s-%02d' "$dayp" "$hh")"; done
    # kind-specific follow targets: each key type has a natural home in the chain
    local targets=""
    case "$kind" in
      listing_id)        targets="${chan_sys:+$chan_sys/avail-api $chan_sys/notify-gateway}";;
      echoToken)         targets="${chan_sys:+$chan_sys/notify-gateway} pms-hub/booking-api";;
      hubBookingUuid|hubPmsPropertyUuid)
                         targets="pms-hub/booking-api pms-hub/pms-booking-events hub-channel-store/booking-api";;
      *)                 targets="${chan_sys:+$chan_sys/booking-processor} hub-channel-store/booking-api pms-hub/booking-api pms-hub/pms-booking-events";;
    esac
    [ -z "$targets" ] && continue
    local app
    for app in $targets; do
      for hh in $hh_list; do
        local sn="f_$(pt_sanitize "$app")_$(pt_sanitize "$hh")_$(pt_sanitize "${key:0:13}")"
        pt_run_stage "$sn" "FOLLOW $app $hh '$key'" \
          "pt_fetch '$app' '$hh' '$key' '$PT_RUN_DIR/raw/$sn.out'"
      done
    done
  done < "$PT_RUN_DIR/join_keys.tsv"
  # re-harvest after follow (follow hits may carry deeper keys, one extra pass)
  pt_harvest
  return 0
}

# ---- verdict synthesizer: stage gates + failure signatures + elimination ledger
# ---- case-insensitive fallback sweep (grep as last resort) -------------------
pt_fallback_icase() {
  # After all remote queries: local case-insensitive grep for the ref over EVERYTHING we
  # pulled (any file, any key). Catches case-mangled occurrences that the uppercase
  # server-side patterns would miss; on blind runs this is the last-resort elimination
  # check: if this finds nothing, the ref is truly absent from all fetched data.
  [ "$PT_GREP_FALLBACK" = "1" ] || { echo "[fallback] disabled (PT_GREP_FALLBACK=0)"; return 0; }
  local out="$PT_RUN_DIR/raw/t_fallback_icase.out"
  : > "$out"
  local up core
  up=$(echo "$PT_REF" | tr 'a-z' 'A-Z'); core="${up##*-}"
  grep -hiF -e "$PT_REF" -e "$up" ${core:+-e "$core"} "$PT_RUN_DIR"/raw/*.out 2>/dev/null \
    | grep -v '^\[fallback-icase\]' | sort -u | sed 's/^/[fallback-icase] /' >> "$out" || true
  grep -v '^\[fallback-icase\].*\[fallback-icase\]' "$out" > "$out.tmp" 2>/dev/null || true
  mv "$out.tmp" "$out" 2>/dev/null || true
  local n; n=$(grep -c . "$out" 2>/dev/null); n=${n:-0}
  if [ "$n" -gt 0 ]; then
    echo "[fallback] icase sweep: $n line(s) mention the ref (case-insensitive) -> $out"
  else
    rm -f "$out"
    echo "[fallback] icase sweep: ref absent from ALL fetched data (any case) - strengthens elimination"
  fi
}
pt_verdict() {
  python3 - "$PT_RUN_DIR" "$PT_KB_PATH" "$PT_REF" <<'PYEOF'
import json, os, re, sys, glob, datetime
run, kb_path, ref = sys.argv[1], sys.argv[2], sys.argv[3]
kb = json.load(open(kb_path))
sigs = kb.get("failure_signatures", {})
low = set(kb.get("low_selectivity_kinds", ["pmsType", "hubPmsPropertyUuid", "roomCode", "ratePlanCode"]))

kind_of = {}
tokens = set()   # high-selectivity harvested values = booking-true markers
jk = os.path.join(run, "join_keys.tsv")
if os.path.exists(jk):
    for line in open(jk):
        p = line.rstrip("\n").split("\t")
        if len(p) >= 2:
            kind_of[p[1][:13]] = p[0]
            if p[0] not in low and len(p[1]) >= 6:
                tokens.add(p[1])

refpats = {ref, ref.upper()}
if "-" in ref:
    bare = ref.split("-", 1)[1]
    if bare: refpats.add(bare); refpats.add(bare.upper())

env = {}
try:
    for line in open(os.path.join(run, "inputs.env")):
        if "=" in line:
            k, val = line.rstrip("\n").split("=", 1); env[k] = val
except Exception: pass

def files_of(pat):
    return sorted(glob.glob(os.path.join(run, "raw", pat)))

def is_context(fname):
    b = os.path.basename(fname)
    if not b.startswith("f_"): return False
    key13 = b[:-4].rsplit("_", 1)[-1]
    return kind_of.get(key13) in low

all_f = files_of("f_*.out")
evidence_files = files_of("t_*.out") + [f for f in all_f if not is_context(f)]
context_files  = [f for f in all_f if is_context(f)]

# v0.7.7: full-day property sweeps are evidence ONLY where a line carries the ref
# or a harvested high-selectivity token; every other line is a sibling reservation
hits, fd_files, fd_admitted = [], 0, 0
for f in evidence_files:
    is_fd = "_fd_" in os.path.basename(f) or os.path.basename(f).startswith("t_lad_")
    if is_fd: fd_files += 1
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except Exception: continue
    for l in lines:
        if not l.strip() or l.startswith("[fetch]"): continue
        if is_fd:
            if not (any(p in l for p in refpats) or any(t in l for t in tokens)): continue
            fd_admitted += 1
        hits.append(l)

# v0.9.1: canonical dedupe - the same event appears in t_*, f_* and t_fallback_icase files
# (icase lines carry a "[fallback-icase] " prefix that defeats exact-string dedupe and
# double-counted failure events in live run CASE-00000003: 20 counted, 5 distinct)
_seen_ev = set(); _deduped = []
for l in hits:
    s = l[len("[fallback-icase] "):] if l.startswith("[fallback-icase] ") else l
    k = None
    try:
        o = json.loads(s)
        k = (o.get("@timestamp") or o.get("time") or o.get("date"), o.get("msg"))
    except Exception:
        pass
    k = k or ("raw", s)
    if k in _seen_ev: continue
    _seen_ev.add(k); _deduped.append(l)
hits = _deduped

preflight_ok = {}
for f in files_of("preflight_*.stdout"):
    sysname = os.path.basename(f)[len("preflight_"):].rsplit(".stdout", 1)[0].replace("_", "-")
    preflight_ok[sysname] = os.path.getsize(f) > 0

GATES = [
    ("ARRIVAL",    re.compile(r'make_reservation|booked_at|booking.?request|reservation.?create', re.I)),
    ("INVENTORY",  re.compile(r'sellable|availab|inventory', re.I)),
    ("ACCEPTANCE", re.compile(r'acceptance|status:?\s*"?20[02]|RESPONSE.*\b200\b|"statusCode":\s*20[02]', re.I)),
    ("CM_STORE",   re.compile(r'hub-channel-store|Fetching reservation|cmBookingId', re.I)),
    ("PMS_RECEIVE",re.compile(r'pms-hub|pmsBookings|booking-events', re.I)),
    ("CONVERSION", re.compile(r'faultCode|ERR_CONVERSION|"status":\s*"Error"', re.I)),
    ("DELIVERY",   re.compile(r'"status":\s*"(Success|Delivered|Completed|Processed)"|delivery.?success|sent to pms|Delivered reservation version', re.I)),
]
# KB-declared non-applicable gates (e.g. INVENTORY for ChannelRelay push channels)
skip_gates = {}
chan_sys = env.get("PT_CHAN_SYS", "")
sc = kb.get("channelrelay", {})
if chan_sys and chan_sys == sc.get("system"):
    for g in sc.get("skip_gates", []):
        skip_gates[g] = "no %s stage for ChannelRelay push channels (KB channelrelay.skip_gates)" % g

gate_hits = {g: [] for g, _ in GATES}
_seen = set()
failure_codes = {}
email_silence = False
times = {}
for l in hits:
    for g, rx in GATES:
        if rx.search(l) and (g, l) not in _seen:
            gate_hits[g].append(l); _seen.add((g, l))
    m = re.search(r'faultCode"?\s*[:=]\s*"?([A-Z_]+)', l)
    if m: failure_codes[m.group(1)] = failure_codes.get(m.group(1), 0) + 1
    if re.search(r'notification email', l, re.I): email_silence = True
    try: o = json.loads(l)
    except Exception: o = None
    if o:
        t = o.get("time") or o.get("@timestamp") or o.get("date")
        if t:
            for g, rx in GATES:
                if rx.search(l) and g not in times: times[g] = t

terminal = None
for code in failure_codes:
    if sigs.get(code, {}).get("terminal"): terminal = code; break
# v0.9.1: a gate is FAILED (not lit, not "no hits") when failure events bind to this booking.
# ERR_CONVERSION* fails the CONVERSION gate; any other failure code fails DELIVERY
# (live misread CASE-00000003: DELIVERY showed [x] from a weak line while delivery had 413'd).
failed_gates = {}
if failure_codes:
    conv = [c for c in failure_codes if c.startswith("ERR_CONVERSION")]
    others = [c for c in failure_codes if not c.startswith("ERR_CONVERSION")]
    if conv: failed_gates["CONVERSION"] = conv
    if others or conv: failed_gates["DELIVERY"] = others or conv
order = [g for g, _ in GATES]
na_gates = set()
if terminal and "CONVERSION" in order:
    for g in order[order.index("CONVERSION") + 1:]:
        if not gate_hits[g]: na_gates.add(g)

reached = [g for g in order if gate_hits[g]]
missing = [g for g in order if not gate_hits[g] and g not in na_gates and g not in skip_gates and g not in failed_gates]

rep = []
rep.append("")
rep.append("## VERDICT (synthesized %s)" % datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"))
rep.append("")
for g in order:
    if g in failed_gates:
        rep.append("- [!] **%s - FAILED** - failure event(s) bound to this booking: %s (%d hit(s) also seen)" % (g, ", ".join(failed_gates[g]), len(gate_hits[g])))
    elif gate_hits[g]:
        rep.append("- [x] **%s** - %d hit(s)%s" % (g, len(gate_hits[g]), (", first at " + times[g]) if g in times else ""))
    elif g in na_gates:
        rep.append("- [~] %s - N/A: terminal failure `%s` at CONVERSION (downstream never attempted)" % (g, terminal))
    elif g in skip_gates:
        rep.append("- [~] %s - N/A: %s" % (g, skip_gates[g]))
    else:
        rep.append("- [ ] %s - no hits in evidence" % g)
rep.append("")
if context_files:
    rep.append("_context sweeps excluded from evidence: %d file(s) from low-selectivity keys (%s) - co-tenant traffic, never gate evidence_" % (len(context_files), ", ".join(sorted(low))))
if fd_files:
    rep.append("_property/full-day sweeps: %d property-keyed file(s), %d line(s) admitted by ref/token match; sibling-reservation lines excluded (v0.7.7/v0.7.9 co-tenant guard)_" % (fd_files, fd_admitted))
rep.append("")
if failure_codes:
    rep.append("### Failure signatures")
    for code, n in sorted(failure_codes.items()):
        sig = sigs.get(code)
        if sig:
            rep.append("- `%s` (x%d): %s" % (code, n, sig.get("meaning", "")))
            if sig.get("fix_path"): rep.append("  - fix: %s" % sig["fix_path"])
            if sig.get("silence_caveat"): rep.append("  - caveat: %s" % sig["silence_caveat"])
        else:
            rep.append("- `%s` (x%d): NOT in KB failure_signatures - add it after this case" % (code, n))
    rep.append("")
if email_silence:
    rep.append("### Silence caveat")
    rep.append("- The hotel has **no notification email configured** - this failure was SILENT for the property (pms-hub error-handler tried to notify and failed).")
    rep.append("")

try:
    ledger = [l.split("|") for l in open(os.path.join(run, "ledger.tsv")).read().splitlines() if l.strip()]
except Exception:
    ledger = []
n_scans = len(ledger)
n_empty = sum(1 for r in ledger if len(r) > 3 and r[3] == "lines=0")
n_hit = sum(1 for r in ledger if len(r) > 3 and r[3].startswith("lines=") and r[3] != "lines=0")
pf_txt = " ".join("%s=%s" % (k, "OK" if v else "FAIL") for k, v in sorted(preflight_ok.items()))
GATE_WHY = {
    "ARRIVAL":    "channel inbound swept per-app across the trusted pool (+catalog-only on empty), patterns=uppercase ref + bare code (CM IDs stored UPPERCASE), hour fan-out + full-day fallback + icase sweep",
    "INVENTORY":  "inventory state only visible via listing_id follow scans; none of the harvested keys produced an inventory hit",
    "ACCEPTANCE": "acceptance events swept with the arrival patterns; booking-processor joined by flowToken",
    "CM_STORE":   "hub-channel-store scanned directly and via every harvested flowToken/UUID",
    "PMS_RECEIVE":"pms-hub booking-api + pms-booking-events scanned with all pattern variants (hour-bounded) and all harvested keys",
    "CONVERSION": "no faultCode/status=Error observed in any evidence hit",
    "DELIVERY":   "no Success/Delivered/Completed status observed in any of the %d evidence hit(s)" % len(hits),
}
rep.append("### Elimination ledger (why an empty stage is believed)")
rep.append("- coverage: %d stage(s) run, %d empty, %d with hits; preflight: %s" % (n_scans, n_empty, n_hit, pf_txt or "n/a"))
for g in missing:
    rep.append("- **%s empty**: %s" % (g, GATE_WHY.get(g, "swept, no evidence")))
if not missing and not na_gates:
    rep.append("- no empty stages; chain fully lit")
rep.append("")

with open(os.path.join(run, "REPORT.md"), "a") as fh:
    fh.write("\n".join(rep) + "\n")
print("\n".join(rep))
json.dump({"reached": reached, "missing": missing, "na": sorted(na_gates),
           "skipped": sorted(skip_gates), "fd_files": fd_files, "fd_admitted": fd_admitted,
           "failure_codes": failure_codes, "email_silence": email_silence,
           "terminal": terminal, "hits": len(hits), "context_files": len(context_files)},
          open(os.path.join(run, "verdict.json"), "w"), indent=1)
PYEOF
}

# ---- trace v2 ------------------------------------------------------------------
pt_trace() {
  [ -n "$PT_REF" ] || { echo "[trace] FATAL: set PT_REF"; return 2; }
  echo "[trace] ref=$PT_REF window=$PT_FROM..$PT_TO at=${PT_AT:-none} uncertain=$PT_AT_UNCERTAIN"
  pt_note "# PMS TOOL PASTE v${PT_VERSION} - case $PT_CASE"
  pt_note "- ref=$PT_REF pms=${PT_PMS:-auto} window=$PT_FROM..$PT_TO at=${PT_AT:-full-day} uncertain=$PT_AT_UNCERTAIN tz=$PT_TZ_OFFSET"

  # 1. resolve (KB module -> catalog alias -> ledger; runs in-shell: it sets PT_CHAN_SYS)
  pt_resolve
  # persist the resolved system so verdict/crossref can read it from inputs.env
  [ -n "${PT_CHAN_SYS:-}" ] && ! grep -q '^PT_CHAN_SYS=' "$PT_RUN_DIR/inputs.env" 2>/dev/null \
    && echo "PT_CHAN_SYS=$PT_CHAN_SYS" >> "$PT_RUN_DIR/inputs.env" 
  # unresolved channel -> broad discovery sweep across every cm-* system in the live catalog
  if [ -z "${PT_CHAN_SYS:-}" ]; then
    local disc_systems
    disc_systems=$(pt_catalog | awk -F/ 'NF>=2{print $(NF-1)}' | grep '^cm-' | sort -u | head -40)
    pt_log "[resolve] discovery sweep over systems: $(echo $disc_systems | tr '\n' ' ')"
    pt_note "- resolve: no KB module / alias; discovery sweep over: $(echo $disc_systems | tr '\n' ' ')"
    local ds
    for ds in $disc_systems; do pt_sweep "disc" "$ds/*" "${PT_FANOUT_HOURS:-3}"; done
    # if any discovery hit landed, re-resolve the system from the hit filenames
    local first_hit
    first_hit=$(ls "$PT_RUN_DIR/raw"/t_disc_*.out 2>/dev/null | head -1)
    if [ -n "$first_hit" ]; then
      PT_CHAN_SYS=$(basename "$first_hit" | sed 's/^t_disc_//; s/_.*//' | tr '_' '-')
      pt_log "[resolve] discovery hit -> channel system $PT_CHAN_SYS"
      pt_kb_write "create:$(echo "$PT_PREFIX" | tr 'a-z' 'A-Z')" "$PT_CHAN_SYS/discovered"
    fi
  fi
  local pats; pats=$(pt_variants "$PT_REF")
  pt_note "- patterns: $pats (uppercase rule: CM booking IDs are stored UPPERCASE; lowercase variants dropped - verified 2026-10-28)"
  pt_log "[trace] patterns: $pats"

  # 2. preflight per system we are about to trust
  if [ "$PT_NO_PREFLIGHT" != "1" ]; then
    local syslist="${PT_CHAN_SYS:-} pms-hub"
    pt_preflight $syslist || pt_note "- (continuing despite preflight failure; verdict marks UNVERIFIED stages)"
  fi

  # 3. channel-side sweeps, cost-ordered: trusted pool -> catalog-only -> sys-wide LAST RESORT
  local fan=0; [ "$PT_AT_UNCERTAIN" = "1" ] && fan="${PT_FANOUT_HOURS:-3}"
  # resolved+stale-filtered app list from pt_resolve is authoritative; KB re-read is only a fallback
  local chan_apps="${PT_CHAN_APPS:-}"
  [ -z "$chan_apps" ] && [ -n "$PT_CHAN" ] && chan_apps="$(kb "channels.$PT_CHAN.log_apps.reservation_inbound") $(kb "channels.$PT_CHAN.log_apps.other_apps" | python3 -c "import json,sys;d=sys.stdin.read().strip();print(' '.join(json.loads(d) if d and d!='null' else []))" 2>/dev/null)"
  chan_apps=$(echo $chan_apps | tr ' ' '
' | grep -v -e '^$' -e '^None$' -e '^null$' | tr '
' ' ')
  [ -n "$chan_apps" ] && pt_sweep "kb" "$chan_apps" "$fan"
  if ! pt_any_hit kb && [ -n "${PT_CATALOG_ONLY// /}" ]; then
    pt_log "[trace] trusted pool empty - widening to catalog-only apps (still per-app, cheap):$PT_CATALOG_ONLY"
    pt_sweep "cat" "$PT_CATALOG_ONLY" "$fan"
  fi
  # v0.9.7b2: never fire the minutes-per-hour system-wide sweep on an UNVERIFIED system
  # (name-match guess). A wrong-system guess made this burn ~1h on an unrelated vendor system (case CASE-00000002).
  if [ "$PT_SYS_SWEEP" != "0" ] && [ -n "$PT_CHAN_SYS" ]; then
    if ! grep -qE "sys_from_(kb_apps|convention)" "$PT_RUN_DIR/resolve.tsv" 2>/dev/null; then
      pt_log "[trace] system from name-match only - system-wide sweep SUPPRESSED (unverified system; fix the KB module or set PT_SYS_SWEEP=1 to force)"
    elif [ "$PT_SYS_SWEEP" = "1" ] || { ! pt_any_hit kb && ! pt_any_hit cat; }; then
      pt_log "[trace] LAST RESORT system-wide sweep (sys/* scans cost minutes each on live)"
      pt_sweep "sys" "$PT_CHAN_SYS/*" "$fan"
    else
      pt_log "[trace] per-app hits landed - system-wide sweep skipped (PT_SYS_SWEEP=auto)"
    fi
  fi

  # 3a. arrival anchor: lock the live event hour BEFORE ladder/pms stages
  pt_anchor

  # 3b. GUI input ladder: every extra identifier is a first-class sweep key
  local extra_keys=""
  for k in "$PT_HOTEL_UUID" "$PT_HOTELIER_ID" "$PT_PROPKEY" "$PT_MEMBERSHIP" "$PT_LISTING_ID" "$PT_GUEST"; do
    [ -n "$k" ] && extra_keys="$extra_keys $k"
  done
  if [ -n "$extra_keys" ]; then
    pt_log "[ladder] extra GUI keys:$extra_keys"
    pt_note "- GUI ladder keys:$extra_keys"
    local fd_day="${PT_ANCHOR:+${PT_ANCHOR:0:10}}"; fd_day="${fd_day:-$PT_AT_DATE}"
    for k in $extra_keys; do
      PT_REF_SAVE="$PT_REF"; PT_REF="$k"
      local chan_rc=1 core_rc=1
      if [ -n "$chan_apps" ]; then
        pt_sweep "lad" "$chan_apps" "$fan"; chan_rc=$?
      fi
      pt_sweep "lad" "pms-hub/booking-api pms-hub/pms-booking-events hub-channel-store/booking-api" "$fan"; core_rc=$?
      # (pt_sweep rc: 1 = hits found, 0 = empty). fd fallback only for keys that
      # echo SOMEWHERE - a zero-echo key is not in the logs near this booking
      if [ "$PT_FULLDAY_FALLBACK" = "1" ]; then
        if [ "$chan_rc" -eq 1 ] || [ "$core_rc" -eq 1 ] || [ "$PT_LAD_FD_ZERO" = "1" ]; then
          [ "$chan_rc" -eq 0 ] && [ -n "$chan_apps" ] && pt_sweep_fd "lad" "$chan_apps" "$fd_day"
          [ "$core_rc" -eq 0 ] && pt_sweep_fd "lad" "pms-hub/booking-api pms-hub/pms-booking-events hub-channel-store/booking-api" "$fd_day"
        else
          pt_log "[ladder] key $k: zero echo in all apps/hours - full-day skipped (PT_LAD_FD_ZERO=1 to force)"
          pt_note "- ladder key \`$k\`: zero echo in all apps/hours - full-day skipped (absent near the booking; PT_LAD_FD_ZERO=1 forces)"
        fi
      fi
      PT_REF="$PT_REF_SAVE"
    done
  fi

  # 4. pms-hub direct: ref patterns hour-bounded (never full-day '*')
  local pms_apps="pms-hub/booking-api pms-hub/pms-booking-events"
  [ -n "$PT_PMS" ] && pms_apps="$pms_apps $(kb "pms.$PT_PMS.delivery_apps" | python3 -c "import json,sys;d=sys.stdin.read().strip();print(' '.join(json.loads(d) if d and d!='null' else []))" 2>/dev/null)"
  pt_sweep "pms" "$pms_apps" "$fan"

  # 5. harvest -> follow the join keys across the chain
  pt_run_stage harvest "join-key harvest" "pt_harvest"
  # channel cross-check: sourceAgentCode in the hits must match the resolved channel
  local bagt; bagt=$(awk -F'\t' '$1=="sourceAgentCode"{print $2}' "$PT_RUN_DIR/join_keys.tsv" 2>/dev/null | sort -u | tr '\n' ' ')
  if [ -n "${bagt// /}" ]; then
    local resolved="${PT_CHAN:-$(echo "$PT_PREFIX" | tr 'a-z' 'A-Z')}"
    if echo " $bagt " | grep -q " $resolved "; then
      pt_note "- channel cross-check: sourceAgentCode=$bagt matches resolved channel $resolved - diagnosis confirmed"
    else
      pt_note "- channel cross-check WARN: sourceAgentCode=$bagt != resolved channel $resolved - re-check channel resolution"
    fi
  fi
  pt_run_stage follow "follow harvested keys" "pt_follow"

  # 5b. cross-run property correlation (shared identifiers across run dirs)
  pt_run_stage crossref "cross-run property correlation" "pt_crossref"

  # 5b. pmsType reaction: the harvested PMS code selects its own module and delivery apps
  local pms_code
  pms_code=$(awk -F'\t' '$1=="pmsType"{print $2; exit}' "$PT_RUN_DIR/join_keys.tsv" 2>/dev/null)
  if [ -n "$pms_code" ] && [ -z "$PT_PMS" ]; then
    local pd_apps
    pd_apps=$(kb "pms.$pms_code.delivery_apps" | python3 -c "import json,sys;d=sys.stdin.read().strip();print(' '.join(json.loads(d) if d and d!='null' else []))" 2>/dev/null)
    if [ -n "$pd_apps" ]; then
      local pd_new="" pa
      for pa in $pd_apps; do case " $pms_apps " in *" $pa "*) : ;; *) pd_new="$pd_new $pa";; esac; done
      if [ -n "${pd_new// /}" ]; then
        pt_log "[pmsType] harvested $pms_code -> sweeping delivery apps not already covered:$pd_new"
        pt_note "- pmsType reaction: harvested $pms_code; swept extra delivery apps:$pd_new (rest already covered)"
        pt_sweep "pmsd" "$pd_new" "$fan"
      else
        pt_log "[pmsType] harvested $pms_code -> delivery apps already swept in the pms pass - skipping duplicate"
        pt_note "- pmsType reaction: harvested $pms_code; delivery apps already covered by the pms pass"
      fi
      PT_PMS_EFFECTIVE="$pms_code"
    else
      pt_log "[pmsType] harvested $pms_code but no KB module - recorded for KB completion"
      pt_note "- pmsType reaction: $pms_code harvested; NO KB module yet (add pms.$pms_code)"
      PT_PMS_EFFECTIVE="$pms_code"
    fi
  else
    PT_PMS_EFFECTIVE="${PT_PMS:-$pms_code}"
  fi

  # 6. case-insensitive fallback sweep, then classify + verdict (+ verdict.json for conditional chaining)
  pt_run_stage fallback_icase "case-insensitive ref sweep (fallback)" "pt_fallback_icase"
  pt_run_stage verdict "stage classification + verdict" "pt_verdict"
  pt_run_stage next_actions "conditional next actions" "pt_next_actions"

  # 7. KB write-back of confirmed apps (app names come from ledger labels, never from filenames)
  local hitapps=""
  local f b lbl app
  for f in "$PT_RUN_DIR/raw"/t_*.out "$PT_RUN_DIR/raw"/f_*.out; do
    [ -e "$f" ] || continue
    if [ -s "$f" ]; then
      b=$(basename "$f" .out)
      ann=""
      case "$b" in *_fd_*|t_fallback_icase) ann=" [full-day: ref/token-filtered at verdict]";; esac
      if [ -z "$ann" ] && [ "${b#f_}" != "$b" ]; then
        k13="${b##*_}"
        kkind=$(awk -F'\t' -v k="$k13" 'index($2, k)==1 {print $1; exit}' "$PT_RUN_DIR/join_keys.tsv" 2>/dev/null)
        [ -n "$kkind" ] && case " $(kb_list low_selectivity_kinds 2>/dev/null) " in
          *" $kkind "*) ann=" [context: low-selectivity $kkind - excluded from evidence]";; esac
      fi
      pt_note "- HIT: $b ($(grep -c . "$f") lines)$ann"
      lbl=$(awk -F'|' -v n="$b" '$1==n{print $2; exit}' "$PT_RUN_DIR/ledger.tsv" 2>/dev/null)
      app=$(echo "$lbl" | sed 's/^FOLLOW //' | awk '{print $1}')
      case "$app" in */*) hitapps="$hitapps $app";; esac
    fi
  done
  hitapps=$(echo $hitapps | tr ' ' '\n' | sort -u | tr '\n' ' ')
  # rich write-back: winning patterns, window mode, signatures, key kinds, stale repairs
  local wb_args="" p hit_pats=""
  for p in $(pt_variants "$PT_REF"); do
    grep -lq -- "$p" "$PT_RUN_DIR/raw"/t_*.out "$PT_RUN_DIR/raw"/f_*.out 2>/dev/null && hit_pats="$hit_pats $p"
  done
  hit_pats=$(echo $hit_pats | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
  [ -n "$hit_pats" ] && wb_args="$wb_args pat:$(echo $hit_pats | tr ' ' ',')"
  [ "$PT_AT_UNCERTAIN" = "1" ] && wb_args="$wb_args win:fanout+${PT_FANOUT_HOURS:-3}h" || wb_args="$wb_args win:hour"
  grep -q "_fd_" "$PT_RUN_DIR/ledger.tsv" 2>/dev/null && wb_args="$wb_args win:fullday-fallback"
  local sig
  for sig in $(grep -aho 'faultCode"\?[:=]\s*"\?[A-Z_]*' "$PT_RUN_DIR/raw"/*.out 2>/dev/null | sed 's/.*[:=]\s*"\?//' | sort -u); do
    wb_args="$wb_args sig:$sig"
  done
  local kk
  kk=$(cut -f1 "$PT_RUN_DIR/join_keys.tsv" 2>/dev/null | sort -u | tr '\n' ',')
  [ -n "$kk" ] && wb_args="$wb_args keys:${kk%,}"
  local st
  for st in $PT_STALE_APPS; do wb_args="$wb_args stale:$st"; done
  pt_kb_write "-" $wb_args $hitapps
  pt_note "- ledger: $PT_RUN_DIR/ledger.tsv  keys: $PT_RUN_DIR/join_keys.tsv  raw: $PT_RUN_DIR/raw/"
}


# ---- conditional next actions: the verdict decides the next move --------------
pt_next_actions() {
  [ -s "$PT_RUN_DIR/verdict.json" ] || { echo "[next] no verdict.json - run trace first"; return 0; }
  python3 - "$PT_RUN_DIR" "$PT_KB_PATH" <<'PYEOF'
import json, os, sys
run, kb_path = sys.argv[1], sys.argv[2]
v = json.load(open(os.path.join(run, "verdict.json")))
kb = json.load(open(kb_path))
sigs = kb.get("failure_signatures", {})
keys = {}
try:
    for line in open(os.path.join(run, "join_keys.tsv")):
        p = line.rstrip("\n").split("\t")
        if len(p) >= 2 and p[0] not in keys: keys[p[0]] = p[1]
except Exception: pass
env = {}
try:
    for line in open(os.path.join(run, "inputs.env")):
        if "=" in line:
            k, val = line.rstrip("\n").split("=", 1); env[k] = val
except Exception: pass

out = ["# NEXT ACTIONS (chained from the verdict - the tool's own reading of what to do now)", ""]
n = 0
codes = sorted(v.get("failure_codes", {}))
for code in codes:
    sig = sigs.get(code, {})
    n += 1
    out.append("%d. **Failure `%s`** (%d event%s)" % (n, code, v["failure_codes"][code], "s" if v["failure_codes"][code] > 1 else ""))
    if sig.get("meaning"): out.append("   - meaning: %s" % sig["meaning"])
    if sig.get("fix_path"): out.append("   - fix path: %s" % sig["fix_path"])
    if not sig: out.append("   - not in KB failure_signatures - verify it belongs to THIS booking before acting, then add it")
    if code == "ERR_CONVERSION_UNMAPPED_ROOM_RATE":
        h = keys.get("hubPmsPropertyUuid", "(see join_keys.tsv)")
        obs_r, obs_rt = keys.get("roomCode", "?"), keys.get("ratePlanCode", "?")
        exp_r = env.get("PT_PMS_ROOM_CODE") or "?"
        exp_rt = env.get("PT_PMS_RATE_CODE") or "?"
        out.append("   - mapping check: confirm room/rate mapping Channel Manager -> PMS for hubPmsPropertyUuid `%s` (PMS-HUB Admin UI / CM mapping screen); after mapping, resend the reservation from the CM reservation page" % h)
        out.append("   - codes: payload observed roomCode=`%s` ratePlanCode=`%s` | PMS expects room=`%s` rate=`%s` (fill PT_PMS_ROOM_CODE/PT_PMS_RATE_CODE from the PMS to compare)" % (obs_r, obs_rt, exp_r, exp_rt))
        out.append("   - property-wide: this mapping covers ALL channels of the property - expect every other channel's bookings to fail with the same signature until mapped; one fix clears them all (confirmed 2026-10-30: OTA4 + OTA5, same property)")
if v.get("email_silence"):
    n += 1
    out.append("%d. **Silence**: the hotel has no notification email configured - recommend enabling reservation-failure notifications so this class of failure is never silent again" % n)
if "DELIVERY" in v.get("reached", []) and "CONVERSION" not in v.get("reached", []):
    n += 1
    out.append("%d. **Delivered**: chain into fidelity - re-paste with PT_TASKS=\"trace fidelity\" (docs auto-fetch from the harvested tokens) to verify OTA->PMS data transformation" % n)
if not v.get("hits"):
    n += 1
    out.append("%d. **No evidence anywhere**: before calling it absent - widen PT_FROM/PT_TO, set PT_AT_UNCERTAIN=1 (or full-day), and add any GUI identifiers you can get (PT_PMS_CONF / PT_CM_RES_UUID / PT_HOTEL_UUID / PT_PROPERTY_ID / PT_MEMBERSHIP / PT_LISTING_ID / PT_GUEST)" % n)
missing = [g for g in ("ARRIVAL", "ACCEPTANCE", "CM_STORE", "PMS_RECEIVE") if g in v.get("missing", [])]
if v.get("hits") and missing and not codes:
    n += 1
    out.append("%d. **Broken chain**: stage(s) %s never lit although the ref is present - inspect the elimination ledger; the break point is the first unlit stage" % (n, ", ".join(missing)))
if v.get("context_files"):
    out.append("")
    out.append("_%d context file(s) from low-selectivity keys were excluded from evidence (co-tenant traffic); see REPORT.md_" % v["context_files"])
if n == 0:
    out.append("- verdict chain is complete and clean; no chained action required")
txt = "\n".join(out) + "\n"
open(os.path.join(run, "NEXT_ACTIONS.md"), "w").write(txt)
print(txt)
PYEOF
}

# ---- fidelity v2 (auto-fetch via harvested tokens when files are absent) -------
pt_fidelity() {
  local of="$PT_OTA_FILE" pf="$PT_PMS_FILE"
  for d in "." "$HOME/pms_tools" "$HOME" "$PT_RUN_DIR"; do
    [ -z "$of" ] || [ -f "$of" ] || [ ! -f "$d/$of" ] || of="$d/$of"
    [ -z "$pf" ] || [ -f "$pf" ] || [ ! -f "$d/$pf" ] || pf="$d/$pf"
  done
  # auto-fetch: OTA-side doc via echo/trace token; PMS-side doc via harvested hubBookingUuid
  if [ ! -f "${of:-/dev/null}" ]; then
    local tok="${PT_OTA_TOKEN:-$(awk -F'\t' '$1=="echoToken"{print $2; exit}' "$PT_RUN_DIR/join_keys.tsv" 2>/dev/null)}"
    if [ -n "$tok" ] && [ -n "${PT_CHAN_SYS:-}" ]; then
      of="$PT_RUN_DIR/raw/ota_doc.xml"; : > "$of"
      pt_fetch "$PT_CHAN_SYS/notify-gateway" "${PT_AT_DATE:-$PT_FROM}-*" "$tok" "$of"
    fi
  fi
  if [ ! -f "${pf:-/dev/null}" ]; then
    local uuid="${PT_PMS_TOKEN:-$(awk -F'\t' '$1=="hubBookingUuid"{print $2; exit}' "$PT_RUN_DIR/join_keys.tsv" 2>/dev/null)}"
    if [ -n "$uuid" ]; then
      pf="$PT_RUN_DIR/raw/pms_doc.xml"; : > "$pf"
      pt_fetch "pms-hub/booking-api" "${PT_AT_DATE:-$PT_FROM}-*" "$uuid" "$pf"
    fi
  fi
  if [ ! -s "${of:-/dev/null}" ] || [ ! -s "${pf:-/dev/null}" ]; then
    echo "[fidelity] docs unavailable (ota=${of:-none} pms=${pf:-none})."
    echo "[fidelity] when the trace verdict is a CONVERSION failure, no PMS-bound doc exists - the diff target is the conversion gate, not a document."
    pt_note "- fidelity: docs unavailable (ota=${of:-none} pms=${pf:-none}); if the verdict is CONVERSION failure, no PMS-bound doc exists by definition."
    return 2
  fi
  echo "[fidelity] ota=$of pms=$pf"
  python3 - "$of" "$pf" "$PT_RUN_DIR/fidelity_report.txt" <<'PYEOF'
import json, os, re, sys
ota_path, pms_path, rep_path = sys.argv[1:4]
def extract_xml(raw, roots):
    for r in roots:
        i = raw.find("<" + r)
        if i >= 0:
            j = raw.rfind("</" + r + ">")
            if j > i: return raw[i:j + len(r) + 3]
    return None
def unesc(s):
    return s.replace("\\\\", "\x00").replace('\\"', '"').replace("\\n", "\n").replace("\x00", "\\")
def parse_fields(xml):
    out = {}
    m = re.search(r'AmountAfterTax=\\?"([\d.]+)\\?"', xml)
    if m: out["after_tax"] = m.group(1)
    m = re.search(r'AmountBeforeTax=\\?"([\d.]+)\\?"', xml)
    if m: out["before_tax"] = m.group(1)
    taxes = re.findall(r'<Tax [^>]*Amount=\\?"([\d.]+)\\?"[^>]*Code=\\?"([\w]+)\\?"[^>]*Type=\\?"(\w+)\\?"', xml)
    if taxes: out["taxes"] = taxes
    m = re.search(r'<valueNum>([\d.]+)</valueNum>', xml)
    if m: out["pms_amount"] = m.group(1)
    m = re.search(r'CurrencyCode=\\?"([A-Z]{3})\\?"', xml)
    if m: out["currency"] = m.group(1)
    m = re.search(r'RoomTypeCode=\\?"([\w-]+)\\?"', xml)
    if m: out["room_code"] = m.group(1)
    m = re.search(r'RatePlanCode=\\?"([\w-]+)\\?"', xml)
    if m: out["rate_code"] = m.group(1)
    guests = re.findall(r'<GivenName>([^<]+)</GivenName>', xml)
    if guests: out["guests"] = guests
    dates = re.findall(r'<TimeSpan Start=\\?"([\d-]+)\\?" End=\\?"([\d-]+)\\?"', xml)
    if dates: out["dates"] = dates[0]
    return out
raw_ota = unesc(open(ota_path, encoding="latin-1").read())
raw_pms = unesc(open(pms_path, encoding="latin-1").read())
ota = parse_fields(extract_xml(raw_ota, ["OTA_HotelResNotifRQ", "OTA_HotelResNotifRS", "OTA_HotelResRQ"]) or raw_ota)
pms = parse_fields(extract_xml(raw_pms, ["Reservation", "OTA_HotelResNotifRQ"]) or raw_pms)
def verdict(src, dst):
    if src and dst: return ("PRESERVED" if src == dst else "TRANSFORMED", "%s -> %s" % (src, dst))
    if src and not dst: return ("DROPPED", "%s -> (absent)" % src)
    if dst and not src: return ("ADDED", "(absent) -> %s" % dst)
    return ("ABSENT_BOTH", "-")
rows = []
for label, sk, pk in [
    ("rate.amount_after_tax -> pms.amount", "after_tax", "pms_amount"),
    ("rate.amount_before_tax", "before_tax", "before_tax"),
    ("rate.currency", "currency", "currency"),
    ("room.code", "room_code", "room_code"),
    ("rate.code", "rate_code", "rate_code"),
    ("guest.names", "guests", "guests"),
    ("stay.dates", "dates", "dates"),
]:
    v, d = verdict(ota.get(sk), pms.get(pk)); rows.append((label, v, d))
v, d = verdict("x".join(t[0] for t in ota.get("taxes", [])) or None, "x".join(t[0] for t in pms.get("taxes", [])) or None)
rows.append(("rate.taxes[]", v, d))
verdicts = []
if ota.get("before_tax") and pms.get("pms_amount") and pms["pms_amount"] == ota.get("after_tax"):
    verdicts.append("CONFIG_IGNORED: PMS doc carries the after-tax amount while a before-tax amount existed at source")
if ota.get("taxes") and not pms.get("taxes"):
    verdicts.append("TAX_BREAKDOWN_DROPPED: %d tax lines at source, none in the PMS doc" % len(ota["taxes"]))
for f, v, d in rows:
    if v == "DROPPED": verdicts.append("FIELD_DROPPED: %s (%s)" % (f, d))
lines = ["FIDELITY REPORT", "ota_doc=%s" % ota_path, "pms_doc=%s" % pms_path, ""]
lines += ["%-42s %-12s %s" % (f, v, d) for f, v, d in rows]
lines += ["", "VERDICTS:"] + ["  - " + v for v in verdicts]
rep = "\n".join(lines)
open(rep_path, "w").write(rep + "\n")
print(rep)
PYEOF
}

# ---- kb-test v2: KB <-> live cross-validation ----------------------------------
pt_kb_test() {
  echo "[kb-test] module reachability + catalog cross-check + anchor probes"
  pt_catalog > /dev/null
  python3 - "$PT_RUN_DIR" <<'PYEOF'
import json, os, sys
kb = json.load(open(os.environ["PT_KB_PATH"]))
catalog = open(os.path.join(sys.argv[1], "raw", "catalog_root.stdout"), encoding="utf-8", errors="replace").read()
for sect in ("channels", "pms"):
    for code, m in kb[sect].items():
        apps = []
        la = m.get("log_apps") or {}
        for k, v in (la.items() if isinstance(la, dict) else []):
            if v and not k.startswith("_"): apps += v if isinstance(v, list) else [v]
        apps += m.get("delivery_apps", []) + m.get("inventory_apps", []) + m.get("other_apps", [])
        live, stale = [], []
        for a in sorted(set(apps)):
            (live if ("/" + a.split("/")[0] + "/" + (a.split("/")[1] if "/" in a else "")) in catalog.replace("*", "") or a.split("/")[-1] in catalog else stale).append(a)
        ea = m.get("example_anchors", {})
        print("[kb-test] %s %s: apps live=%d stale=%d verified=%s history=%d" % (
            sect[:-1], code, len(live), len(stale), ea.get("verified_at", "?"), len(m.get("history", []))))
        for a in stale: print("[kb-test]   STALE? %s (not in live catalog)" % a)
sigs = kb.get("failure_signatures", {})
print("[kb-test] failure_signatures: %d loaded (%s)" % (len(sigs), ", ".join(sorted(sigs)) if sigs else "none"))
PYEOF
  for app in $(python3 -c "
import json,os
kb=json.load(open(os.environ['PT_KB_PATH'])); s=set()
for sect in ('channels','pms'):
  for m in kb[sect].values():
    la=m.get('log_apps') or {}
    for k,v in (la.items() if isinstance(la,dict) else []):
      if v and not k.startswith('_'): s.update(v if isinstance(v,list) else [v])
    for v in m.get('delivery_apps',[])+m.get('inventory_apps',[])+m.get('other_apps',[]): s.add(v)
print(' '.join(sorted(s)))"); do
    local sys comp got st
    sys=$(pt_app_sys "$app"); comp=$(pt_app_comp "$app")
    got=$(pt_s3 ls "$sys" "$comp" 2>/dev/null | grep -c "$sys/")
    [ "$got" -gt 0 ] && st="LIVE" || st="STALE?"
    echo "[kb-test] $st  $app"
  done
}

# ============================================================================
# ARI MODE (S2 beta): value attribution + ARI push tracing --------------------
# Gates: SOURCE(who/what set it) -> INGEST(PMS-side leg, N/A for manual) ->
#        CM_PERSIST(SET in avail-api) -> CHANNEL_PUSH -> OTA_ACK.
# Design facts from KB v0.2.0 (stage-1 sweep):
#   - cm/avail-api DELTA-CHECKS inbound: absence = "already set", never "not delivered".
#   - hub-xbridge/ari-relay is a blind hop (no flowToken) - never swept, never gated.
#   - CloudPMS payloads are S3-only; batch flowTokens renamed (originFlowTokens) - free-text search.
#   - Attribution: client/originSystem on SET lines; platform -> gui-gateway flowToken -> user email.
# ============================================================================

pt_ari_inputs_env() {
  { for v in PT_CASE PT_REF PT_BOOKING_REF PT_CHANNEL PT_HOTEL_UUID PT_PROPERTY_ID PT_MEMBERSHIP PT_HOTELIER_ID PT_CHANNEL_HOTEL_UUID PT_TARGET_VALUES PT_STAY_DATES PT_RATE_CODE PT_ROOM_TYPE_CODE PT_SOURCE_SYSTEM PT_PMS_HOTEL_CODE PT_AT PT_AT_UNCERTAIN PT_TZ_OFFSET PT_FROM PT_TO; do eval "echo $v=\${$v:-}"; done; } > "$PT_RUN_DIR/inputs.env"
  [ -n "${PT_CHAN_SYS:-}" ] && ! grep -q '^PT_CHAN_SYS=' "$PT_RUN_DIR/inputs.env" && echo "PT_CHAN_SYS=$PT_CHAN_SYS" >> "$PT_RUN_DIR/inputs.env"
}

# filter + classify avail-api evidence (python: the heavy lifting)
pt_ari_filter() {
  python3 - "$PT_RUN_DIR" "$PT_HOTEL_UUID" "$PT_TARGET_VALUES" "$PT_STAY_DATES" "$PT_RATE_CODE" "$PT_ROOM_TYPE_CODE" <<'PYEOF'
import glob, json, os, re, sys
run, hotel, values, dates, rate_code, room_code = sys.argv[1:7]
vals = [v for v in values.split() if v]
dts = [d for d in dates.split() if d]
rows = []
SET_RX = re.compile(r'SET\s(RATE|AVAIL|RESTRICTION|STOP|INVENTORY)|"message"\s*:\s*"SET', re.I)
TS_RX = re.compile(r'(20\d\d-\d\d-\d\d)[T ](\d\d:\d\d:\d\d)')
# R12 (v0.8.0b4): values must match as VALUES, not as substrings of identifiers or HTTP
# noise. Live false positive (run CASE-00000004): "999" inside ownerId=129990 on a SET AVAIL
# line was classified as a rate TARGET_EVENT; "200" matches status: 200 everywhere.
NOISE_RX = re.compile(r'status"?\s*[:=]\s*"?\d{3}\b|[A-Za-z_]*[Ii][Dd]=\d+|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|roomTypeId=\d+|roomRateRef=\d+')
RATE_CTX_RX = re.compile(r'SET\sRATE|rate|price|amount|value', re.I)
def value_hit(line, v):
    scrub = NOISE_RX.sub(" ", line)
    return re.search(r'(?<![\d.])' + re.escape(v) + r'(?![\d.])', scrub) is not None
def field(line, name):
    m = re.search(r'"' + name + r'"\s*:\s*"([^"]*)"', line)          # JSON "name":"multi word value"
    if m: return m.group(1)
    m = re.search(r'\b' + name + r'=\s*"?([^",\s}]+)', line)         # k=v fallback
    return m.group(1) if m else ""
for f in sorted(glob.glob(os.path.join(run, "raw", "t_ari_inv_*.out"))):
    app = os.path.basename(f)[:-4]
    for line in open(f, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if not line.strip() or line.startswith("[fetch]"): continue
        if not SET_RX.search(line): continue
        ts_m = TS_RX.search(line)
        ts = "%sT%s" % (ts_m.group(1), ts_m.group(2)) if ts_m else ""
        csys = field(line, "originSystem") or field(line, "client_system")
        client = field(line, "client")
        tok = field(line, "flowToken")
        rru = field(line, "roomRateKey")
        vhit = [v for v in vals if value_hit(line, v)]
        dhit = [d for d in dts if d in line]
        kind = "context"
        # R12: a TARGET_EVENT needs a rate value in a rate context + the stay date;
        # availability counts on SET AVAIL lines are reported as availability, not rates.
        if vhit and dhit and RATE_CTX_RX.search(line): kind = "TARGET_EVENT"
        elif vhit or dhit: kind = "partial"
        rows.append({"ts": ts, "app": app, "kind": kind, "originSystem": csys,
                     "client": client, "flowToken": tok, "roomRateKey": rru,
                     "values": vhit, "dates": dhit, "line": line[:600]})
rows.sort(key=lambda r: r["ts"])
with open(os.path.join(run, "ari_evidence.tsv"), "w") as fh:
    fh.write("ts\tkind\toriginSystem\tclient\tflowToken\troomRateKey\tvalues\tdates\tapp\n")
    for r in rows:
        fh.write("\t".join([r["ts"], r["kind"], r["originSystem"], r["client"], r["flowToken"],
                            r["roomRateKey"], ",".join(r["values"]), ",".join(r["dates"]), r["app"]]) + "\n")
tgt = [r for r in rows if r["kind"] == "TARGET_EVENT"]
print("[ari-filter] %d SET lines kept (%d TARGET_EVENT = value+date match)" % (len(rows), len(tgt)))
for r in tgt[:5]:
    print("[ari-filter] TARGET %s sys=%s client=%s tok=%s values=%s dates=%s" % (r["ts"], r["originSystem"], r["client"], r["flowToken"], ",".join(r["values"]), ",".join(r["dates"])))
PYEOF
}

# attribution: platform updates -> gui-gateway flowToken -> user email
pt_ari_attribute() {
  [ -s "$PT_RUN_DIR/ari_evidence.tsv" ] || { pt_log "[ari] no evidence rows - attribution skipped"; return 0; }
  local toks
  toks=$(awk -F'\t' 'NR>1 && tolower($3) ~ /platform|webcm|extranet/ && $5 != "" {print $1"|"$5}' "$PT_RUN_DIR/ari_evidence.tsv" | sort -u | head -8)
  if [ -z "$toks" ]; then
    pt_log "[ari] no platform-attributed SET lines with flowToken - gui-gateway lookup skipped (PMS/CloudPMS push or unattributed)"
    return 0
  fi
  local pair ts tok hh day sn
  for pair in $toks; do
    ts="${pair%%|*}"; tok="${pair##*|}"
    day="${ts%%T*}"; hh=$(echo "$ts" | sed -n 's/.*T\([0-9][0-9]\):.*/\1/p'); hh=${hh:-00}
    sn="f_ari_gui_$(pt_sanitize "$tok")"
    pt_run_stage "$sn" "GUI portal-property/gui-gateway ${day}-${hh} '$tok'" \
      "pt_fetch 'portal-property/gui-gateway' '${day}-${hh}' '$tok' '$PT_RUN_DIR/raw/$sn.out'"
  done
  # harvest emails from the gui-gateway evidence
  python3 - "$PT_RUN_DIR" <<'PYEOF'
import glob, os, re, sys
run = sys.argv[1]
emails = set()
for f in glob.glob(os.path.join(run, "raw", "f_ari_gui_*.out")):
    for line in open(f, encoding="utf-8", errors="replace"):
        for m in re.finditer(r'[\w.+-]+@[\w-]+\.[\w.]+', line):
            e = m.group(0)
            if not e.endswith(("example.com", "example.internal")): emails.add(e)
if emails:
    open(os.path.join(run, "ari_actors.txt"), "w").write("\n".join(sorted(emails)) + "\n")
    print("[ari-attr] user(s) behind platform updates: %s" % ", ".join(sorted(emails)))
else:
    print("[ari-attr] gui-gateway swept but no user email found (token may not join; check raw f_ari_gui_*)")
PYEOF
}

# ingest leg: only when attribution points at a PMS/CloudPMS push (never for manual updates)
pt_ari_ingest() {
  local src="$PT_SOURCE_SYSTEM"
  if [ "$src" = "auto" ]; then
    if [ -s "$PT_RUN_DIR/ari_evidence.tsv" ] && awk -F'\t' 'NR>1 && tolower($3) ~ /pms|cloud/ {f=1} END{exit !f}' "$PT_RUN_DIR/ari_evidence.tsv"; then
      awk -F'\t' 'NR>1 {print tolower($3)}' "$PT_RUN_DIR/ari_evidence.tsv" | grep -qi 'cloud' && src="bridge" || src="xengine"
    else
      pt_log "[ari] INGEST N/A - evidence shows manual/platform origin (or no SET lines); no PMS ingest leg to trace"
      pt_note "- INGEST leg: N/A - origin is platform/manual (or no SET evidence); no PMS push in the chain"
      return 0
    fi
  fi
  case "$src" in
    bridge|cloud*)
      [ -n "$PT_PROPERTY_ID" ] || { pt_log "[ari] CloudPMS ingest needs PT_PROPERTY_ID (propkey)"; return 0; }
      pt_log "[ari] CloudPMS ingest leg: pms-cm-bridge/avail-sync by propkey (payloads S3-only; batch-renamed flowTokens)"
      pt_note "- INGEST leg: pms-cm-bridge/avail-sync swept by propkey=$PT_PROPERTY_ID (batch tokens: free-text search)"
      local day="$PT_FROM"
      while :; do
        local sn="t_ari_ing_$(pt_sanitize pms-cm-bridge/avail-sync)_$day"
        pt_run_stage "$sn" "pms-cm-bridge/avail-sync ${day}-* '$PT_PROPERTY_ID'" \
          "pt_fetch 'pms-cm-bridge/avail-sync' '${day}-*' '$PT_PROPERTY_ID' '$PT_RUN_DIR/raw/$sn.out'"
        [ "$day" = "$PT_TO" ] && break
        day=$(date -u -d "$day +1 day" +%F)
      done;;
    xengine)
      [ -n "$PT_PMS_HOTEL_CODE" ] || { pt_log "[ari] xengine ingest needs PT_PMS_HOTEL_CODE"; return 0; }
      pt_log "[ari] xengine ingest leg: hub-xbridge/ari-feed by hotelCode (ari-relay is a blind hop - skipped by design)"
      pt_note "- INGEST leg: hub-xbridge/ari-feed swept by hotelCode=$PT_PMS_HOTEL_CODE; ari-relay skipped (blind hop, KB v0.2.0)"
      local day="$PT_FROM"
      while :; do
        local sn="t_ari_ing_$(pt_sanitize hub-xbridge/ari-feed)_$day"
        pt_run_stage "$sn" "hub-xbridge/ari-feed ${day}-* '$PT_PMS_HOTEL_CODE'" \
          "pt_fetch 'hub-xbridge/ari-feed' '${day}-*' '$PT_PMS_HOTEL_CODE' '$PT_RUN_DIR/raw/$sn.out'"
        [ "$day" = "$PT_TO" ] && break
        day=$(date -u -d "$day +1 day" +%F)
      done;;
    *) pt_log "[ari] unknown PT_SOURCE_SYSTEM='$src' - ingest skipped";;
  esac
}

# push leg: CM -> channel ARI for the same values/dates
pt_ari_push_apps() {
  [ -n "${PT_CHANNEL_APP:-}" ] && { echo "$PT_CHANNEL_APP"; return 0; }
  local sys="${PT_CHAN_SYS:-}"
  [ -z "$sys" ] && return 0
  # R26 (v0.9.5b3): include connection-* - cm-channelrelay has NO inventory component; the
  # OTA-facing ARI exchange lives in mapping-api (live catalog CASE-00000005). Log the pool
  # when the fallback fires so a wrong guess is visible instead of silent.
  local allpool; allpool=$(pt_pool "$sys" 2>/dev/null)
  local pool; pool=$(echo "$allpool" | grep -iE 'inventory|avail|ari|rate|connection' | head -3 | tr '\n' ' ')
  if [ -n "${pool// /}" ]; then echo "$pool"; else
    pt_note "- CHANNEL_PUSH apps: FALLBACK $sys/avail-gateway (pool had no inventory/connection comps; pool=$allpool)"
    echo "$sys/avail-gateway"
  fi
}

pt_ari_push() {
  if pt_is_channelrelay; then
    pt_log "[ari] ChannelRelay channel - CUR push leg skipped (ChannelRelay ARI lives on LGCY sync partitions; covered by LGCY_ARI leg)"
    pt_note "- CHANNEL_PUSH(CUR): skipped - ChannelRelay channel; ARI covered by LGCY_ARI leg (legacy-stack sync partitions, key listingAcctId)"
    return 0
  fi
  local apps; apps=$(pt_ari_push_apps)
  [ -n "${apps// /}" ] || { pt_log "[ari] no channel system resolved - push leg skipped"; pt_note "- CHANNEL_PUSH: skipped (no channel resolved)"; return 0; }
  # R25 (v0.9.5b3): multi-word codes ("BAR HD", "FAM 2AD+2CH") were word-split into
  # garbage patterns ('BAR','HD') - newline list + read -r preserves them (CASE-00000005 run)
  local pats_file="$PT_RUN_DIR/state/push_pats.txt"; : > "$pats_file"
  local p
  for p in "$PT_MEMBERSHIP" "$PT_HOTELIER_ID2" "$PT_CHANNEL_HOTEL_UUID" "$PT_RATE_CODE" "$PT_ROOM_TYPE_CODE" "$PT_CM_HOTELIER_ID" "$PT_ENTITY_ID"; do
    [ -n "$p" ] && printf '%s\n' "$p" >> "$pats_file"
  done
  [ -s "$pats_file" ] || { pt_log "[ari] no push-side identifiers (membership/hotel id/rate code) - push leg skipped"; return 0; }
  local pats; pats=$(paste -sd', ' "$pats_file")   # display only - scans iterate the file (spaces preserved)
  # R10 (v0.8.0b3): chain to inventory hit hour(s) +/-1h; else bounded day blobs
  # PT_FROM..PT_AT_DATE (never forward of the claimed moment; never unbounded).
  local blobs=""
  if [ -n "${PT_PUSH_HOURS// /}" ]; then
    blobs="$PT_PUSH_HOURS"
    pt_log "[ari] push leg CHAINED to inventory hit hour(s) +/-1h"
  else
    local d="$PT_FROM" dend="${PT_AT_DATE:-$PT_TO}"
    while :; do blobs="$blobs ${d}-*"; [ "$d" = "$dend" ] && break; d=$(date -u -d "$d +1 day" +%F); done
    pt_log "[ari] push leg bounded day-granularity $PT_FROM..$dend (no inventory hits to chain from)"
  fi
  pt_log "[ari] push leg: apps=$apps patterns=$pats"
  pt_note "- CHANNEL_PUSH leg: apps=$apps patterns=$pats (chained/bounded; OTA ack behaviour is channel-specific - verify per KB before claiming non-receipt)"
  local app pat b sn
  for app in $apps; do
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      for b in $blobs; do
        sn="t_ari_push_$(pt_sanitize "$app")_${b}_$(pt_sanitize "$pat")"
        pt_run_stage "$sn" "$app $b '$pat'" \
          "pt_fetch '$app' '$b' '$pat' '$PT_RUN_DIR/raw/$sn.out'"
      done
    done < "$pats_file"
  done
}

# R24 (v0.9.5b3): does any scanned inventory hour contain a TARGET event - a target value
# in rate context on a stay date (field-aware, identifier/HTTP noise scrubbed = R12 rules)?
pt_hour_has_target() {
  local f vals dts
  vals="${PT_TARGET_VALUES:-}"; dts="${PT_STAY_DATES:-}"
  [ -n "$vals" ] && [ -n "$dts" ] || return 1
  for f in "$PT_RUN_DIR"/raw/t_ari_inv_*.out; do
    [ -s "$f" ] || continue
    python3 - "$f" "$vals" "$dts" <<'PYTGT' && return 0
import sys, re
f, vals, dts = sys.argv[1], sys.argv[2].split(), sys.argv[3].split()
NOISE = re.compile(r'status"?\s*[:=]\s*"?\d{3}\b|[A-Za-z_]*[Ii][Dd]=\d+|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|roomTypeId=\d+|roomRateRef=\d+')
RATE_CTX = re.compile(r'SET\sRATE|rate|price|amount|value', re.I)
for line in open(f, errors="ignore"):
    if not any(d in line for d in dts): continue
    scrub = NOISE.sub(" ", line)
    if any(re.search(r'(?<![\d.])' + re.escape(v) + r'(?![\d.])', scrub) for v in vals) and RATE_CTX.search(line):
        sys.exit(0)
sys.exit(1)
PYTGT
  done
  return 1
}

# R13 (v0.8.0b5): CloudPMS bridge pushed-values leg - what CloudPMS actually sent, at the chained
# inventory hit hours (pms-cm-bridge/avail-sync by propkey; CloudPMS payloads are S3-only, KB fact)
pt_ari_bridge_values() {
  [ -n "$PT_PROPERTY_ID" ] || { pt_log "[ari] no propkey - bridge values leg skipped"; return 0; }
  local hours="${PT_PUSH_HOURS:-}"
  if [ -z "${hours// /}" ]; then
    pt_log "[ari] no inventory hit hours - bridge values leg skipped (nothing to chain from)"
    pt_note "- BRIDGE_VALUES: skipped (no inventory hit hours to chain from)"
    return 0
  fi
  pt_log "[ari] bridge values leg: pms-cm-bridge/avail-sync by propkey at chained hour(s):$hours"
  pt_note "- BRIDGE_VALUES leg: pms-cm-bridge/avail-sync by propkey=$PT_PROPERTY_ID at chained hour(s):$hours - raw/t_ari_bv_*"
  local h sn
  for h in $hours; do
    sn="t_ari_bv_pms-cm-bridge_avail-sync_${h}"
    pt_run_stage "$sn" "pms-cm-bridge/avail-sync $h propkey" \
      "pt_fetch 'pms-cm-bridge/avail-sync' '$h' '$PT_PROPERTY_ID' '$PT_RUN_DIR/raw/$sn.out'"
  done
  # v0.9.3: bridge online-state probe - was the CloudPMS bridge active for this propkey at the
  # same hours? (overbooking-suspension cases: deactivation for non-payment kills the
  # bridge; state-sync-api goes quiet / logs sync-disabled. KB: PMS_BRIDGE_SYNC_DISABLED)
  pt_note "- BRIDGE_STATE leg: pms-cm-bridge/state-sync-api by propkey at chained hour(s):$hours - raw/t_ari_bridge_* (empty = bridge silent; cross-ref billing-service/events)"
  for h in $hours; do
    sn="t_ari_bridge_pms-cm-bridge_state-sync-api_${h}"
    pt_run_stage "$sn" "pms-cm-bridge/state-sync-api $h propkey (bridge state)" \
      "pt_fetch 'pms-cm-bridge/state-sync-api' '$h' '$PT_PROPERTY_ID' '$PT_RUN_DIR/raw/$sn.out'"
  done
}

# R17 (v0.9.4): BILLING leg - billing-service account-status trace around the booking window.
# Question: was the property Suspended BEFORE the booking, and was there a reactivation
# (before or after)? Transitions explain stale OTA inventory; balances are irrelevant.
pt_ari_billing() {
  if [ -z "$PT_BILLING_FROM" ]; then
    pt_note "- BILLING leg: skipped (PT_BILLING_FROM empty)"
    return 0
  fi
  pt_log "[billing] status-change trace: billing-service/events $PT_BILLING_FROM..$PT_BILLING_TO by propkey=$PT_PROPERTY_ID (transitions only - balances irrelevant)"
  pt_note "- BILLING leg: billing-service/events day-series $PT_BILLING_FROM..$PT_BILLING_TO by propkey=$PT_PROPERTY_ID (suspend/reactivate timeline - empty = purged, mark ELIMINATED not absent); payment-gateway probes on key days by account(s): ${PT_BILLING_ACCOUNTS:-none}"
  local d="$PT_BILLING_FROM" sn a
  while [ "$d" \< "$PT_BILLING_TO" ] || [ "$d" = "$PT_BILLING_TO" ]; do
    sn="t_bil_billing-service_events_${d}"
    pt_run_stage "$sn" "billing-service/events $d propkey" \
      "pt_fetch 'billing-service/events' '$d-*' '$PT_PROPERTY_ID' '$PT_RUN_DIR/raw/$sn.out'"
    d=$(date -u -d "$d +1 day" +%F)
  done
  for d in $PT_BILLING_KEY_DAYS; do
    for a in $PT_BILLING_ACCOUNTS; do
      [ -n "$a" ] || continue
      sn="t_bil_payments_${d}_$(pt_sanitize "$a")"
      pt_run_stage "$sn" "payments/payment-gateway $d $a" \
        "pt_fetch 'payments/payment-gateway' '$d-*' '$a' '$PT_RUN_DIR/raw/$sn.out'"
    done
  done
}

# R19 (v0.9.4b3): ARI presence day-series - was the CloudPMS bridge pushing ARI before/after the
# booking? Day-level HOUR-WILDCARD greps on the BRIDGE logs (per-property, viable). NOT on
# cm/avail-api: day blobs there are live-proven non-viable (7/7 x 1500s timeouts, CASE-00000004).
# CM-side SET persistence stays with the anchored backward hour-series + push leg.
pt_ari_series() {
  local sfrom="${PT_SERIES_FROM:-$PT_FROM}" sto="${PT_SERIES_TO:-$PT_TO}"
  if [ -z "$sfrom" ]; then pt_note "- ARI_SERIES leg: skipped (no window)"; return 0; fi
  if [ -z "$PT_PROPERTY_ID" ]; then pt_note "- ARI_SERIES leg: skipped (no propkey)"; return 0; fi
  pt_log "[series] ARI presence day-series: pms-cm-bridge day-wildcards $sfrom..$sto by propkey=$PT_PROPERTY_ID (before+after booking)"
  pt_note "- ARI_SERIES leg: pms-cm-bridge/avail-sync + state-sync-api day-wildcards $sfrom..$sto by propkey=$PT_PROPERTY_ID - presence/absence per day; avail-api day blobs refused by design (non-viable live)"
  local d="$sfrom" sn
  while [ "$d" \< "$sto" ] || [ "$d" = "$sto" ]; do
    sn="t_ser_bridge-avail-sync_${d}"
    pt_run_stage "$sn" "pms-cm-bridge/avail-sync $d-* propkey" \
      "pt_fetch 'pms-cm-bridge/avail-sync' '$d-*' '$PT_PROPERTY_ID' '$PT_RUN_DIR/raw/$sn.out'"
    sn="t_ser_bridge-state-sync-api_${d}"
    pt_run_stage "$sn" "pms-cm-bridge/state-sync-api $d-* propkey" \
      "pt_fetch 'pms-cm-bridge/state-sync-api' '$d-*' '$PT_PROPERTY_ID' '$PT_RUN_DIR/raw/$sn.out'"
    d=$(date -u -d "$d +1 day" +%F)
  done
  if ! python3 - "$PT_RUN_DIR" "$sfrom" "$sto" <<'PYEOT'
import sys, os, re, glob
from datetime import date, timedelta
run, sfrom, sto = sys.argv[1:4]
ts = re.compile(r'(20\d\d-\d\d-\d\d[T ]\d\d:\d\d:\d\d)')
out = ["", "### ARI presence timeline (pms-cm-bridge, by day)"]
d = date.fromisoformat(sfrom); end = date.fromisoformat(sto)
while d <= end:
    ds = d.isoformat(); cells = [ds]
    for app, short in (("avail-sync", "inv"), ("state-sync-api", "core")):
        fs = glob.glob(os.path.join(run, "raw", "t_ser_bridge-%s_%s.out" % (app, ds)))
        n = 0; first = None; last = None
        if fs and os.path.getsize(fs[0]) > 0:
            with open(fs[0], errors="ignore") as fh:
                for ln in fh:
                    n += 1
                    m = ts.search(ln)
                    if m:
                        if first is None: first = m.group(1)
                        last = m.group(1)
        cells.append("%s=%d%s" % (short, n, (" (%s..%s)" % (first, last)) if first else ""))
    out.append("- " + " ".join(cells))
    d += timedelta(1)
out.append("(0 = no bridge traffic that day = suspension-window candidate; confirm against the BILLING transitions before concluding - absence in one system is not proof)")
open(os.path.join(run, "REPORT.md"), "a").write("\n".join(out) + "\n")
PYEOT
  then
    # R19b (v0.9.5b1): the python timeline once failed silently (raw intact, summary missing,
    # live run) - bash fallback ALWAYS lands the per-day counts in REPORT.md
    pt_log "[series] WARN: python timeline failed - writing fallback counts to REPORT.md"
    {
      echo ""; echo "### ARI presence timeline (pms-cm-bridge, by day) [fallback counts]"
      local dd="$sfrom" f1 f2
      while [ "$dd" \< "$sto" ] || [ "$dd" = "$sto" ]; do
        f1="$PT_RUN_DIR/raw/t_ser_bridge-avail-sync_${dd}.out"
        f2="$PT_RUN_DIR/raw/t_ser_bridge-state-sync-api_${dd}.out"
        echo "- $dd inv=$([ -s "$f1" ] && wc -l < "$f1" || echo 0) core=$([ -s "$f2" ] && wc -l < "$f2" || echo 0)"
        dd=$(date -u -d "$dd +1 day" +%F)
      done
    } >> "$PT_RUN_DIR/REPORT.md"
  fi
}

# R13 (v0.8.0b5): booking XML leg - what the channel actually sent for THIS booking, at the
# booking hour +/-1h (reservation inbound app from KB module, else pool reservation comps)
pt_ari_booking_xml() {
  [ -n "$PT_BOOKING_REF" ] || { pt_log "[ari] no booking ref - booking XML leg skipped"; return 0; }
  local app apps pat h sn bare b_s i
  apps=$(kb "channels.$PT_CHAN.log_apps.reservation_inbound" | tr ' ' '\n' | grep '/')
  [ -z "${apps// /}" ] && apps=$(pt_pool "$PT_CHAN_SYS" 2>/dev/null | grep -iE 'booking-gateway|booking-processor' | head -2 | tr '\n' ' ')
  [ -n "${apps// /}" ] || apps="$PT_CHAN_SYS/booking-gateway"
  bare="${PT_BOOKING_REF##*-}"
  pt_log "[ari] booking XML leg: apps=$apps hours=$PT_AT_DATE-$PT_AT_HOUR+/-1h patterns='$PT_BOOKING_REF' '$bare'"
  pt_note "- BOOKING_XML leg: apps=$apps at booking hour +/-1h, patterns='$PT_BOOKING_REF' + bare '$bare' - raw/t_ari_xml_*"
  b_s=$(date -u -d "$PT_AT_DATE $PT_AT_HOUR:00:00" +%s)
  for app in $apps; do
    for i in -1 0 1; do
      h=$(date -u -d "@$((b_s + i*3600))" +'%F-%H')
      for pat in "$PT_BOOKING_REF" "$bare"; do
        sn="t_ari_xml_$(pt_sanitize "$app")_${h}_$(pt_sanitize "$pat")"
        pt_run_stage "$sn" "$app $h '$pat'" \
          "pt_fetch '$app' '$h' '$pat' '$PT_RUN_DIR/raw/$sn.out'"
      done
    done
  done
}

# ari verdict: gates + attribution + value events + elimination ledger
pt_ari_verdict() {
  python3 - "$PT_RUN_DIR" "$PT_KB_PATH" <<'PYEOF'
import datetime, glob, json, os, re, sys
run, kb_path = sys.argv[1], sys.argv[2]
kb = json.load(open(kb_path))
rows = []
ev = os.path.join(run, "ari_evidence.tsv")
if os.path.exists(ev):
    for line in open(ev).read().splitlines()[1:]:
        p = line.split("\t")
        if len(p) >= 9: rows.append(dict(zip(["ts","kind","originSystem","client","flowToken","roomRateKey","values","dates","app"], p)))
actors = []
af = os.path.join(run, "ari_actors.txt")
if os.path.exists(af): actors = [l.strip() for l in open(af) if l.strip()]
push_lines = []
for f in glob.glob(os.path.join(run, "raw", "t_ari_push_*.out")):
    for line in open(f, encoding="utf-8", errors="replace"):
        if line.strip() and not line.startswith("[fetch]"): push_lines.append(line.rstrip("\n"))
ing_files = [f for f in glob.glob(os.path.join(run, "raw", "t_ari_ing_*.out")) if os.path.getsize(f) > 0]

src_systems = sorted({r["originSystem"] for r in rows if r["originSystem"]})
src_clients = sorted({r["client"] for r in rows if r["client"]})
targets = [r for r in rows if r["kind"] == "TARGET_EVENT"]
first_set = rows[0]["ts"] if rows else ""
manual = any(re.search(r'platform|webcm|extranet', s, re.I) for s in src_systems)
pms_push = any(re.search(r'pms|cloud', s, re.I) for s in src_systems)

G = {}
G["SOURCE"] = bool(src_systems) or bool(actors)
G["INGEST"] = None if manual and not pms_push else bool(ing_files)   # None = N/A
G["CM_PERSIST"] = bool(rows)
G["CHANNEL_PUSH"] = bool(push_lines)
G["OTA_ACK"] = any(re.search(r'\b(200|Success|success|OK)\b', l) for l in push_lines) if push_lines else False

try:
    ledger = [l.split("|") for l in open(os.path.join(run, "ledger.tsv")).read().splitlines() if l.strip()]
except Exception: ledger = []
n_scans = len(ledger)
n_empty = sum(1 for r in ledger if len(r) > 3 and r[3] == "lines=0")
n_hit = n_scans - n_empty

rep = ["", "## ARI VERDICT (synthesized %s)" % datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), ""]
rep.append("### Attribution (who/what set the value)")
if src_systems:
    rep.append("- source system(s) on SET lines: **%s** (client: %s)%s" % (
        ", ".join(src_systems), ", ".join(src_clients) or "?",
        (", first at " + first_set) if first_set else ""))
if actors:
    rep.append("- acting user(s) (portal-property gui-gateway): **%s**" % ", ".join(actors))
if manual and not pms_push:
    rep.append("- reading: value set **manually/bulk in Platform** by the user above - no PMS involvement in this chain")
elif pms_push:
    rep.append("- reading: value arrived via **PMS/CloudPMS push** - the PMS provider's own send log (echoToken/flowToken) is the upstream evidence")
if not rows:
    rep.append("- no SET lines found for this hotel in the window - see elimination ledger (delta-check caveat: a value equal to the current one leaves NO log line)")
rep.append("")
rep.append("### Gates")
order = ["SOURCE", "INGEST", "CM_PERSIST", "CHANNEL_PUSH", "OTA_ACK"]
for g in order:
    v = G[g]
    if v is None: rep.append("- [~] %s - N/A (manual origin: no PMS ingest leg exists)" % g)
    elif v: rep.append("- [x] **%s**" % g)
    else: rep.append("- [ ] %s - no evidence" % g)
rep.append("")
if targets:
    rep.append("### Value events (target value + suspect stay date on the same line)")
    for r in targets[:20]:
        rep.append("- `%s` values=%s dates=%s sys=%s tok=%s" % (r["ts"], r["values"], r["dates"], r["originSystem"] or "?", r["flowToken"] or "-"))
    rep.append("")
rep.append("### Elimination ledger")
rep.append("- coverage: %d stage(s) run, %d empty, %d with hits" % (n_scans, n_empty, n_hit))
if not rows:
    rep.append("- CM_PERSIST empty: avail-api swept day-granularity both regions for the hotel uuid across %s..%s; delta-check means an unchanged value leaves no line - empty is consistent with 'value set outside this window' OR 'value equal to previous'" % ("FROM", "TO"))
if not push_lines:
    rep.append("- CHANNEL_PUSH empty: no channel-side lines for the swept identifiers in window - either no push happened (check mapping/derived-rate settings) or identifiers don't join (fill PT_CHANNEL_HOTEL_UUID)")
rep.append("")
open(os.path.join(run, "REPORT.md"), "a").write("\n".join(rep) + "\n")
print("\n".join(rep))

nxt = ["# NEXT ACTIONS (ari mode)", ""]
n = 0
if manual and actors:
    n += 1
    nxt.append("%d. **Manual change confirmed**: %s set the value(s) in Platform%s. Provide the customer the audit lines (ts, user, values, dates) from REPORT.md; no PMS or integration was involved." % (n, ", ".join(actors), (" at " + first_set) if first_set else ""))
elif manual:
    n += 1
    nxt.append("%d. **Manual change indicated** but no user email joined: re-run with a wider window or pull the gui-gateway line manually for the flowToken(s) listed in ari_evidence.tsv" % n)
if pms_push:
    n += 1
    nxt.append("%d. **PMS push origin**: the upstream proof is the PMS provider's send log - ask the PMS for the echoToken/message id of the update covering these dates; the INGEST evidence (if any) is in raw/t_ari_ing_*" % n)
if G["CHANNEL_PUSH"] and targets:
    n += 1
    nxt.append("%d. **Customer-facing answer**: the value CM holds and pushed matches the SOURCE event(s) above - answer who/what/when from the Attribution section; the multiplier math only explains the channel-displayed amount, not the base rate origin" % n)
if not G["CHANNEL_PUSH"]:
    n += 1
    nxt.append("%d. **Push gap**: CM holds the value but no channel push was found - check channel mapping + derived rate/multiplier config, and consider a manual CM -> channel re-push (touch) for the affected dates" % n)
if not rows:
    n += 1
    nxt.append("%d. **No SET evidence**: widen PT_FROM/PT_TO (values may predate the window) or provide PT_RATE_CODE/roomRateKey to narrow; remember an unchanged re-send leaves no line (delta-check)" % n)
if n == 0:
    nxt.append("- chain complete; no chained action required")
open(os.path.join(run, "NEXT_ACTIONS.md"), "w").write("\n".join(nxt) + "\n")
print("\n".join(nxt))

json.dump({"mode": "ari", "reached": [g for g in order if G[g]], "missing": [g for g in order if G[g] is False],
           "na": [g for g in order if G[g] is None], "attributions": {"systems": src_systems, "clients": src_clients, "actors": actors},
           "value_events": len(targets), "failure_codes": {}, "terminal": None,
           "hits": len(rows) + len(push_lines), "context_files": 0},
          open(os.path.join(run, "verdict.json"), "w"), indent=1)
PYEOF
}

pt_ari() {
  [ -n "$PT_HOTEL_UUID" ] || [ -n "$PT_PROPERTY_ID" ] || { echo "[ari] FATAL: set PT_HOTEL_UUID (cm hotel uuid) or PT_PROPERTY_ID (propkey)"; return 2; }
  echo "[ari] case=$PT_CASE window=$PT_FROM..$PT_TO at=${PT_AT:-none} values='$PT_TARGET_VALUES' dates='$PT_STAY_DATES' src=$PT_SOURCE_SYSTEM"
  pt_note "# ARI MODE v${PT_VERSION} - case $PT_CASE"
  pt_note "- hotel=$PT_HOTEL_UUID propkey=$PT_PROPERTY_ID membership=$PT_MEMBERSHIP hotelier=$PT_HOTELIER_ID channel=${PT_CHANNEL:-none} booking=${PT_BOOKING_REF:-none}"
  pt_note "- targets: values='$PT_TARGET_VALUES' stay_dates='$PT_STAY_DATES' rate_code=$PT_RATE_CODE room_code=$PT_ROOM_TYPE_CODE"
  pt_ari_inputs_env
  # channel resolution for the push leg (catalog-free when KB knows the code)
  [ -n "$PT_CHANNEL" ] && { pt_resolve; pt_ari_inputs_env; }
  # preflight on cm (control token proves empty results are trustworthy)
  if [ "$PT_NO_PREFLIGHT" != "1" ]; then
    pt_preflight "cm" || pt_note "- (continuing despite preflight failure; empty inventory sweeps UNVERIFIED)"
  fi
  # SOURCE + CM_PERSIST: avail-api, ANCHORED HOUR SERIES (R10 v0.8.0b3)
  # Guardrail (maintainer, 2026-10-31): first pass = claimed hour +/-PT_FANOUT_HOURS in
  # PT_REGION only. If the claimed event is not there, sweep day-by-day BACKWARD from the
  # anchor day to PT_FROM (5-7 days), hour-at-a-time series per day (wrap from the anchor
  # hour, descending), same hotel/region - then STOP and state facts. No forward slide,
  # no unbounded widening: expansion beyond the window is the user's decision, not the tool's.
  # Live lesson (CASE-00000004): day blobs on avail-api are NON-VIABLE (7/7 x 1500s timeouts);
  # 194 scans x ~9min over 9.5h returned ZERO because the search key was the channel-side
  # uuid - the inventory leg MUST use the CM hotel uuid; the channel uuid gets one
  # elimination probe at the claimed hour and is otherwise a push-leg key.
  local day app sn h region hh hit_hours="" inv_regions=""
  case "${PT_REGION:-both}" in
    ra|rb) inv_regions="$PT_REGION";;
    *) inv_regions="ra rb";;
  esac
  ari_inv_scan() { # region hour-prefix [pattern]
    local app="cm/avail-api-$1" h="$2" pat="${3:-$PT_HOTEL_UUID}"
    if [ -z "$pat" ]; then
      pt_log "[ari] inventory scan skipped - no hotel uuid key (UNVERIFIED; supply PT_HOTEL_UUID from the CM admin GUI)"
      return 0
    fi
    sn="t_ari_inv_$(pt_sanitize "$app")_$h"
    [ -n "${3:-}" ] && sn="t_ari_probe_$(pt_sanitize "$app")_$h"
    pt_run_stage "$sn" "$app $h '$pat'" \
      "pt_fetch '$app' '$h' '$pat' '$PT_RUN_DIR/raw/$sn.out'"
  }
  ari_inv_any_hit() { # -> 0 when any inv .out (any swept region) has content
    local f
    for f in "$PT_RUN_DIR"/raw/t_ari_inv_cm_avail-api-*_*.out; do
      [ -f "$f" ] && [ -s "$f" ] && grep -q . "$f" 2>/dev/null && return 0
    done
    return 1
  }
  ari_inv_hit_hours() { # -> hour prefixes (YYYY-MM-DD-HH) with content, any swept region
    local f
    for f in "$PT_RUN_DIR"/raw/t_ari_inv_cm_avail-api-*_*.out; do
      [ -f "$f" ] && [ -s "$f" ] && grep -q . "$f" 2>/dev/null && basename "$f" .out | sed 's/^t_ari_inv_cm_avail-api-[a-z]*_//'
    done
  }
  pt_wrap_hours() { # anchor-hour-first descending wrap: AT, AT-1, ..., AT+1 (24 entries)
    local a=$((10#$1)) i
    for i in $(seq 0 23); do printf '%02d\n' $(( (a - i + 48) % 24 )); done
  }
  # R11 (v0.8.0b4) anchor semantics (maintainer, 2026-10-31):
  #  booking mode (default): PT_AT is the booking/OTA XML timestamp (UTC) - the causative
  #    update PRECEDES it, so sweep BACKWARD ONLY: AT..00 on the anchor day, then days
  #    back to PT_FROM. No forward scans, no fan-out guessing.
  #  day mode: CX gave the update DAY - full-day wrap series on that day, +/-1 day drift.
  pt_log "[ari] anchor_mode=${PT_ANCHOR_MODE:-booking} at=$PT_AT_DATE-$PT_AT_HOUR region(s)=$inv_regions - backward-only, bounded to $PT_FROM"
  if [ "${PT_ANCHOR_MODE:-booking}" = "day" ]; then
    local dd
    for dd in 0 -1 1; do
      day=$(date -u -d "$PT_AT_DATE $dd day" +%F 2>/dev/null) || continue
      [ "$day" \< "$PT_FROM" ] && continue
      [ -n "$PT_TO" ] && [ "$day" \> "$PT_TO" ] && continue
      for region in $inv_regions; do
        for hh in $(pt_wrap_hours "$PT_AT_HOUR"); do
          ari_inv_scan "$region" "$day-$hh"
          ari_inv_any_hit && break 2
        done
      done
      ari_inv_any_hit && break
    done
  else
    # R24 (v0.9.5b3): rate-mismatch breaks on a TARGET hour (target value in rate context on
    # a stay date) - the booking hour is always hot with consumption traffic and masks the
    # earlier rate SET (CASE-00000005 run stopped at the booking hour, value events=0).
    local break_on="${PT_BREAK_ON:-auto}"
    [ "$break_on" = "auto" ] && { [ "$PT_GOAL" = "rate-mismatch" ] && break_on="target" || break_on="any"; }
    pt_log "[ari] sweep break_on=$break_on"
    day="$PT_AT_DATE"
    while :; do
      local hlist
      if [ "$day" = "$PT_AT_DATE" ]; then hlist=$(seq -w "$PT_AT_HOUR" -1 00); else hlist=$(seq -w 23 -1 00); fi
      for region in $inv_regions; do
        for hh in $hlist; do
          ari_inv_scan "$region" "$day-$hh"
          if [ "$break_on" = "target" ]; then
            pt_hour_has_target && { pt_log "[ari] TARGET hour found at $day-$hh - stopping sweep"; break 2; }
            pt_log "[ari] $day-$hh: context/consumption only - continuing backward"
          else
            ari_inv_any_hit && break 2   # per-hour early break: a live inv scan is ~8min
          fi
        done
      done
      { [ "$break_on" = "target" ] && pt_hour_has_target; } && break
      { [ "$break_on" != "target" ] && ari_inv_any_hit; } && break
      [ "$day" = "$PT_FROM" ] && break
      day=$(date -u -d "$day -1 day" +%F)
    done
  fi
  # elimination probe: ONE claimed-hour scan for the channel-side uuid (fact: key check)
  if [ -n "$PT_CHANNEL_HOTEL_UUID" ] && [ "$PT_CHANNEL_HOTEL_UUID" != "$PT_HOTEL_UUID" ]; then
    for region in $inv_regions; do ari_inv_scan "$region" "$PT_AT_DATE-$PT_AT_HOUR" "$PT_CHANNEL_HOTEL_UUID"; done
  fi
  if ari_inv_any_hit; then
    hit_hours=$(ari_inv_hit_hours | sort -u | tr '\n' ' ')
    pt_log "[ari] inventory evidence hour(s): $hit_hours"
  else
    pt_log "[ari] no inventory lines $PT_FROM..$PT_AT_DATE ($inv_regions) - claim UNCONFIRMED in window; sweep stopped per guardrail (widening is the user's call)"
  fi
  pt_note "- inventory sweep: anchor_mode=${PT_ANCHOR_MODE:-booking} from $PT_AT_DATE-$PT_AT_HOUR backward to $PT_FROM, region(s)=$inv_regions, key=$PT_HOTEL_UUID; stopped per guardrail - no auto-expansion."
  # push-leg chaining: hit hour(s) +/-1h; fallback = bounded day blobs PT_FROM..PT_AT_DATE
  PT_PUSH_HOURS=""
  if [ -n "${hit_hours// /}" ]; then
    local b_s i
    for h in $hit_hours; do
      b_s=$(date -u -d "${h:0:10} ${h:11:2}:00:00" +%s 2>/dev/null) || continue
      for i in -1 0 1; do PT_PUSH_HOURS="$PT_PUSH_HOURS $(date -u -d "@$((b_s + i*3600))" +'%F-%H')"; done
    done
    PT_PUSH_HOURS=$(echo $PT_PUSH_HOURS | tr ' ' '\n' | sort -u | tr '\n' ' ')
  fi
  pt_run_stage ari_filter "classify inventory SET evidence" "pt_ari_filter"
  pt_run_stage ari_attribute "platform attribution (gui-gateway -> user email)" "pt_ari_attribute"
  pt_run_stage ari_ingest "PMS/CloudPMS ingest leg (if push origin)" "pt_ari_ingest"
  pt_run_stage ari_push "channel push leg (CM -> OTA)" "pt_ari_push"
  pt_run_stage ari_push_lgcy "LGCY ChannelRelay ARI push leg (legacy-stack partitions)" "pt_ari_push_lgcy"
  pt_run_stage ari_lgcy_report "LGCY ARI push report" "pt_ari_lgcy_report"
  pt_run_stage ari_bridge_values "CloudPMS bridge pushed values (propkey)" "pt_ari_bridge_values"
  pt_run_stage ari_billing "billing-service status trace (suspend/reactivate timeline)" "pt_ari_billing"
  pt_run_stage ari_series "ARI presence day-series (bridge, before+after booking)" "pt_ari_series"
  pt_run_stage ari_booking_xml "booking XML pull (channel source)" "pt_ari_booking_xml"
  pt_run_stage ari_booking_xml_lgcy "LGCY booking XML fallback" "pt_ari_booking_xml_lgcy"
  pt_run_stage ari_verdict "ari gates + attribution + next actions" "pt_ari_verdict"
  [ -n "$PT_GOAL" ] && [ "$PT_GOAL" != "custom" ] && \
    pt_run_stage ari_goal_verdict "goal verdict matrix ($PT_GOAL)" "pt_goal_verdict"; true
  # R8 (v0.8.0b2): KB write-back - record the run and confirm push-leg apps that produced evidence
  if grep -q . "$PT_RUN_DIR"/raw/t_ari_push_*.out 2>/dev/null; then pt_kb_write "-" $(pt_ari_push_apps); fi
  pt_run_stage crossref "cross-run property correlation" "pt_crossref"
  echo "[ari] done - report: $PT_RUN_DIR/REPORT.md"
}

# ---- guiattrib mode (R15, v0.8.0b6): attribute a GUI config change to a user -----
# Proven live 2026-04-23 (PROPERTY-BETA rate-multiplier, propkey <redacted-propkey>): a GUI audit
# "Rate modification applied" entry maps to a gui-gateway mutation + link-api PUT at the
# same UTC minute. Facts baked in (all verified against prod logs):
#  - the channel-settings save IS logged: gui-gateway "Mutation setChannelProperty" (with
#    .email on the line) + same-flowToken PUT /api/properties/<propkey>/channel-links/<uuid>
#    -> 200 in hub-channel-link/link-api (the persisted write) + GET read-backs,
#    then Mutation dispatchSyncEvent -> job-runner "Get channel hotel recon".
#  - the design-doc name <design-doc operation name> NEVER appears in
#    logs, and the string "rateModification" appears NOWHERE (raw any-field greps empty
#    across gui-gateway / link-api / entity-api): never name-grep for the factor. The
#    email-filtered mutation sweep (gui_sweep stage) is the catch-all that surfaces
#    "Mutation setChannelProperty" regardless of the operation's logged name.
#  - mutation VARIABLES (the factor value, old->new) are DB-only: not in S3 at INFO.
#    fgrep the value on the mutation token to confirm empty; NOTE grep "0.87" is a
#    REGEX (. matches anything) - always fgrep decimal values.
#  - actor email + client IP live on the same token's gui-gateway "graphql server operation
#    was successful" line (.email / .ipAddress); GUI reads show in platform-session/api with the email.
pt_guiattrib() {
  [ -n "$PT_GUI_DATE" ] && [ -n "$PT_GUI_HOUR" ] || { pt_log "[gui] PT_GUI_DATE + PT_GUI_HOUR (UTC) required - skipped"; return 0; }
  local dh="$PT_GUI_DATE-$PT_GUI_HOUR"
  local region="${PT_REGION:-ra}"; [ "$region" = "both" ] && region="ra"
  pt_note ""; pt_note "## GUI attribution ($dh UTC)"
  { for v in PT_GUI_DATE PT_GUI_HOUR PT_GUI_USER PT_PROPERTY_ID PT_CHANNEL_HOTEL_UUID PT_MEMBERSHIP; do eval "echo $v=\${$v:-}"; done; } > "$PT_RUN_DIR/guiattrib_inputs.env"

  # 1. link-api burst by channel hotel uuid (GUI channel-config traffic flows here)
  local burst="$PT_RUN_DIR/raw/gui_channelapi_$dh.out"
  if [ -n "$PT_CHANNEL_HOTEL_UUID" ]; then
    pt_run_stage gui_burst "link-api $dh by channelPropertyUuid" \
      "pt_fetch 'hub-channel-link/link-api' '$dh' '$PT_CHANNEL_HOTEL_UUID' '$burst'"
    python3 -c 'import json,sys
for l in open(sys.argv[1], errors="replace"):
    try: t = json.loads(l).get("flowToken")
    except Exception: continue
    if t: print(t)' "$burst" 2>/dev/null | sort | uniq -c | sort -rn > "$PT_RUN_DIR/gui_tokens.txt"   # python, not jq: no extra dependency
    pt_note "- link-api burst: $(wc -l < "$burst" | tr -d ' ') lines, $(wc -l < "$PT_RUN_DIR/gui_tokens.txt" | tr -d ' ') tokens (gui_tokens.txt)"
  else
    pt_log "[gui] no PT_CHANNEL_HOTEL_UUID - burst skipped"; pt_note "- link-api burst: SKIPPED (no channelPropertyUuid)"
  fi

  # 2+3. per-token dissect (link-api request lines) + portal-property correlation (actor)
  local tok sn i=0
  for tok in $(awk '{print $2}' "$PT_RUN_DIR/gui_tokens.txt" 2>/dev/null | head -8); do
    i=$((i + 1)); sn="gui_tok_$i"
    pt_run_stage "$sn" "link-api token ${tok:0:8}" \
      "pt_qfetch 'hub-channel-link/link-api' '$dh' 's.flowToken = \"$tok\"' '$PT_RUN_DIR/raw/$sn.out'"
    pt_run_stage "${sn}_pp" "portal-property token ${tok:0:8}" \
      "pt_qfetch 'portal-property/*' '$dh' 's.flowToken = \"$tok\"' '$PT_RUN_DIR/raw/${sn}_pp.out'"
  done

  # 4. email-filtered mutation sweep (the catch-all: lists ALL of the user's ops incl.
  #    "Mutation setChannelProperty" - the channel-settings save, per the 2026-04-23 proof)
  [ -n "$PT_GUI_USER" ] && pt_run_stage gui_sweep "gui-gateway ops by $PT_GUI_USER" \
    "pt_qfetch 'portal-property/gui-gateway' '$dh' 's.email = \"$PT_GUI_USER\"' '$PT_RUN_DIR/raw/gui_sweep.out'"

  # 5. platform session reads (GUI session activity carrying the actor email)
  [ -n "$PT_PROPERTY_ID" ] && pt_run_stage gui_session "platform session $dh" \
    "pt_qfetch 'platform-session/api' '$dh' 's.propertyId = \"$PT_PROPERTY_ID\"' '$PT_RUN_DIR/raw/gui_session.out'"

  # 6. entity-api audit write (Core writes the row the GUI audit renders)
  [ -n "$PT_MEMBERSHIP" ] && pt_run_stage gui_core "entity-api audit write ($region)" \
    "pt_qfetch 'cm/entity-api-$region' '$dh' 's.message LIKE \"%$PT_MEMBERSHIP%\"' '$PT_RUN_DIR/raw/gui_core.out'"

  # 7. summarize -> GUIACTORS.md
  python3 - "$PT_RUN_DIR" <<'PYGUIEOF'
import json, re, glob, os, sys
run = sys.argv[1]
def jl(p):
    try: return [json.loads(l) for l in open(p, errors="replace") if l.strip().startswith("{")]
    except FileNotFoundError: return []
rows = []
for f in sorted(glob.glob(os.path.join(run, "raw", "gui_tok_*_pp.out"))):
    tok = email = ip = comp = mut = ts = None
    for o in jl(f):
        tok = tok or o.get("flowToken")
        comp = o.get("kubernetes", {}).get("labels", {}).get("component") or comp
        m = o.get("msg") or ""
        if o.get("email"): email = o["email"]
        if o.get("ipAddress"): ip = o["ipAddress"]
        if m.startswith("Mutation"): mut = m
        if "operation was successful" in m: ts = o.get("@timestamp")
    if tok: rows.append((tok, comp, email, ip, mut, ts))
out = ["# GUI attribution - per-token actor table", "",
       "| flowToken | component | actor email | client IP | mutation | success ts (UTC) |",
       "|---|---|---|---|---|---|"]
for r in rows: out.append("| %s | %s | %s | %s | %s | %s |" % tuple(x or "-" for x in r))
sweep = jl(os.path.join(run, "raw", "gui_sweep.out"))
muts = sorted({(o.get("msg") or "") for o in sweep if (o.get("msg") or "").startswith("Mutation")})
out += ["", "## mutations by GUI user in the hour (email sweep)"]
out += ["- " + m for m in muts] or ["- (none / sweep skipped)"]
core = jl(os.path.join(run, "raw", "gui_core.out"))
hits = [o for o in core if re.search(r"rate.?modification", json.dumps(o), re.I)]
out += ["", "## entity-api audit writes matching rate modification"]
out += ["- %s %s" % (o.get("@timestamp"), (o.get("message") or o.get("msg") or "")[:300]) for o in hits] or ["- (none found)"]
open(os.path.join(run, "GUIACTORS.md"), "w").write("\n".join(out) + "\n")
print("[gui] GUIACTORS.md: %d tokens, %d user mutations, %d core audit hits" % (len(rows), len(muts), len(hits)))
PYGUIEOF
  pt_note "- per-token actor table: GUIACTORS.md (email + client IP + mutation per flowToken)"
}

# R22 (v0.9.5b1): goal verdict matrix - reads ari verdict.json gates, emits GOAL_VERDICT.md.
pt_goal_verdict() {
  [ -s "$PT_RUN_DIR/verdict.json" ] || { pt_log "[goal] no verdict.json - goal verdict skipped"; return 0; }
  python3 - "$PT_RUN_DIR" "$PT_GOAL" <<'PYGV'
import sys, os, json
run, goal = sys.argv[1:3]
v = json.load(open(os.path.join(run, "verdict.json")))
# verdict.json carries "reached" (list of lit gates); older builds may carry a "gates" dict.
reached = set(v.get("reached", []))
g = v.get("gates") if isinstance(v.get("gates"), dict) else {}
on = lambda k: k in reached or bool(g.get(k))
lines = ["# GOAL VERDICT - %s" % goal, ""]
if goal == "overbooking":
    if on("CM_PERSIST") and on("CHANNEL_PUSH") and on("OTA_ACK"):
        lines += ["**NOT_OVERBOOKING** - CM held the value, the booking consumed it, and CM pushed the result to the OTA with an ack.",
                  "- Chain: booking XML (raw/t_ari_xml_*) -> CM inventory SET/consume (raw/t_ari_inv_*) -> OTA push + ack (raw/t_ari_push_*)",
                  "- Customer position: the OTA sold what CM held; dispute fails on the audit trail."]
    elif on("CM_PERSIST") and not on("CHANNEL_PUSH"):
        lines += ["**PUSH_FAILURE** - CM state changed but no OTA-bound push was found in window.",
                  "- Next: verify mapping/derived settings; re-run with PT_CHANNEL_HOTEL_UUID filled if blank."]
    elif not on("CM_PERSIST") and on("SOURCE"):
        lines += ["**STALE_INVENTORY / PMS_SIDE** - source events exist but CM never persisted a matching SET in window.",
                  "- Next: pms-cm-bridge values leg + billing suspension series (raw/t_ser_*, raw/t_ari_billing_*)"]
    else:
        lines += ["**UNVERIFIED** - evidence chain incomplete; see REPORT.md gates and UNVERIFIED items (never read empty as absent)."]
elif goal == "rate-mismatch":
    if on("SOURCE") and on("CM_PERSIST"):
        lines += ["**VALUE_ATTRIBUTED** - origin + CM persistence proven; answer who/what/when from the Attribution section."]
    elif on("SOURCE") and not on("CM_PERSIST"):
        lines += ["**NOT_PERSISTED_IN_CM** - source seen, CM SET not found in window (delta-check: unchanged values leave no line - widen window)."]
    else:
        lines += ["**ORIGIN_NOT_FOUND** - no source events in window; widen PT_FROM or run guiattrib for the GUI-audit date."]
elif goal == "billing-trace":
    lines += ["See REPORT.md billing transitions + ARI presence timeline; correlate suspension dates with bridge-absence days."]
else:
    lines += ["See REPORT.md / NEXT_ACTIONS.md - trace/fidelity verdict governs this goal."]
open(os.path.join(run, "GOAL_VERDICT.md"), "w").write("\n".join(lines) + "\n")
print("[goal] GOAL_VERDICT.md:", lines[2][:110] if len(lines) > 2 else lines[-1][:110])
PYGV
  pt_note "- goal verdict ($PT_GOAL): GOAL_VERDICT.md"
}

# R22 (v0.9.5b1): goal playbooks - PT_GOAL composes PT_TASKS and enforces an input contract
# BEFORE any scan (fail-fast with the exact fill list; no more mid-run blank/garbage inputs).
pt_goal_resolve() {
  # retention horizons (ops policy 2026-10-21): S3 s3-prod archive ~18 months; OpenSearch 7d; log-server ~2d
  local horizon
  horizon=$(date -u -d "-540 days" +%F 2>/dev/null)
  if [ -n "$horizon" ] && [ -n "$PT_FROM" ] && [ "$PT_FROM" \< "$horizon" ]; then
    echo "[retention] WARN: PT_FROM=$PT_FROM is beyond the ~18-month S3 archive horizon ($horizon) - empty scans there are EXPECTED (purged), never evidence of absence. OpenSearch=7d, log-server~2d."
  fi
  [ -n "$PT_GOAL" ] && [ "$PT_GOAL" != "custom" ] || return 0
  local req="" missing="" v val
  case "$PT_GOAL" in
    overbooking)
      PT_TASKS="ari"
      req="PT_CHANNEL PT_AT PT_FROM PT_TO PT_PROPERTY_ID PT_HOTEL_UUID PT_STAY_DATES";;
    missing-reservation)
      PT_TASKS="trace"
      req="PT_REF PT_AT PT_FROM PT_TO PT_CHANNEL";;
    rate-mismatch)
      PT_TASKS="ari"
      req="PT_CHANNEL PT_AT PT_FROM PT_TO PT_TARGET_VALUES PT_STAY_DATES PT_HOTEL_UUID";;
    delivery-failure)
      PT_TASKS="trace fidelity"
      req="PT_REF PT_AT PT_FROM PT_TO";;
    billing-trace)
      PT_TASKS="ari"
      req="PT_PROPERTY_ID PT_BILLING_FROM PT_BILLING_TO";;
    bridge-flush)
      PT_TASKS="bridgeflush"
      req="PT_PROPERTY_ID PT_CLOUDPMS_PROPERTY_ID PT_AT PT_FROM PT_TO PT_REGION";;
    *) echo "[goal] unknown PT_GOAL='$PT_GOAL' (overbooking|missing-reservation|rate-mismatch|delivery-failure|billing-trace|bridge-flush|custom)"; return 0;;
  esac
  echo "[goal] PT_GOAL=$PT_GOAL -> tasks='$PT_TASKS'"
  for v in $req; do
    eval "val=\"\${$v:-}\""
    [ -z "$val" ] && missing="$missing $v"
  done
  if [ "$PT_GOAL" = "overbooking" ] && [ -z "${PT_REF:-}" ] && [ -z "${PT_BOOKING_REF:-}" ]; then
    missing="$missing PT_REF|PT_BOOKING_REF"
  fi
  if [ -n "$missing" ]; then
    echo "[goal] PREFLIGHT INPUT CONTRACT - MISSING required anchors:$missing"
    if [ "$PT_ALLOW_PARTIAL" != "1" ]; then
      echo "[goal] REFUSING to run with gaps. Fill the blanks and re-paste (or set PT_ALLOW_PARTIAL=1; every gap lands in the REPORT as UNVERIFIED, never as absence)."
      exit 2
    fi
    echo "[goal] PT_ALLOW_PARTIAL=1 - proceeding with gaps (UNVERIFIED)"
  else
    echo "[goal] PREFLIGHT INPUT CONTRACT - all required anchors present"
  fi
}

# ---- R27 (v0.9.7): bridge-flush goal - CM/Platform -> CloudPMS flush failure tracer ----------
# EVIDENCE-DRIVEN by design (case CASE-00000006): inputs are propkey + CloudPMS numeric id + window.
# The tool ASSUMES NOTHING about which sub-leg fails or which room rate blocks: leg A
# discovers flush triggers + per-request sub-leg statuses (cloudpms/main), leg B confirms the
# error class (hub-sync-api), leg C enumerates every room-rate PUT outcome
# (cloudpms/entity-api) so the culprit and the fail-fast pattern are DERIVED from the logs.
pt_bridgeflush_hours_scan() { # app pattern stageprefix -> hour files + state/<pfx>_hours.txt
  local app="$1" pat="$2" pfx="$3"
  local day="$PT_AT_DATE" hh hlist h sn safe
  : > "$PT_RUN_DIR/state/${pfx}_hours.txt"
  while :; do
    if [ "$day" = "$PT_AT_DATE" ]; then hlist=$(seq -w "$PT_AT_HOUR" -1 00); else hlist=$(seq -w 23 -1 00); fi
    local dayhit=0
    for hh in $hlist; do
      h="$day-$hh"; safe=$(pt_sanitize "${app}_$h")
      sn="${pfx}_$safe"
      pt_run_stage "$sn" "$app $h '$pat'" \
        "pt_fetch '$app' '$h' '$pat' '$PT_RUN_DIR/raw/$sn.out'"
      if [ -s "$PT_RUN_DIR/raw/$sn.out" ]; then echo "$h" >> "$PT_RUN_DIR/state/${pfx}_hours.txt"; dayhit=1; fi
    done
    [ "$dayhit" = 1 ] && break    # all flush hours on the hit day collected; stop (no older days)
    [ "$day" = "$PT_FROM" ] && break
    day=$(date -u -d "$day -1 day" +%F)
  done
}

pt_bridgeflush_triggers() {
  local pat
  if [ -n "$PT_CLOUDPMS_PROPERTY_ID" ]; then pat="properties/$PT_CLOUDPMS_PROPERTY_ID/flush"; else pat="$PT_PROPERTY_ID"; fi
  pt_log "[bridgeflush] trigger scan: cloudpms/main-$PT_REGION from $PT_AT_DATE-$PT_AT_HOUR backward, pattern '$pat'"
  pt_bridgeflush_hours_scan "cloudpms/main-$PT_REGION" "$pat" "t_bfl_trig"
  # request_id follow-ups: sub-leg statuses live on SEPARATE lines keyed by request_id
  : > "$PT_RUN_DIR/state/bfl_tokens.txt"
  local f tok sn h n=0
  for f in "$PT_RUN_DIR"/raw/t_bfl_trig_*.out; do
    [ -s "$f" ] || continue
    grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "$f" | tr 'A-F' 'a-f' >> "$PT_RUN_DIR/state/bfl_tokens.txt"
  done
  sort -u "$PT_RUN_DIR/state/bfl_tokens.txt" -o "$PT_RUN_DIR/state/bfl_tokens.txt"
  while read -r tok; do
    [ -n "$tok" ] || continue; n=$((n+1)); [ $n -gt 6 ] && { pt_log "[bridgeflush] token cap 6 reached"; break; }
    for h in $(cat "$PT_RUN_DIR/state/t_bfl_trig_hours.txt"); do
      sn="t_bfl_req_${tok}_$h"
      pt_run_stage "$sn" "cloudpms/main-$PT_REGION $h request $tok" \
        "pt_fetch 'cloudpms/main-$PT_REGION' '$h' '$tok' '$PT_RUN_DIR/raw/$sn.out'"
    done
  done < "$PT_RUN_DIR/state/bfl_tokens.txt"
}

pt_bridgeflush_chained() { # app pfx label - chained to discovered flush hours
  local app="$1" pfx="$2" label="$3"
  local hoursf="$PT_RUN_DIR/state/t_bfl_trig_hours.txt"
  if [ ! -s "$hoursf" ]; then
    pt_log "[bridgeflush] $label: skipped (no flush hours discovered)"
    pt_note "- $label: skipped - no flush triggers found in window (chained leg has nothing to anchor to)"
    return 0
  fi
  local h sn safe
  for h in $(cat "$hoursf"); do
    safe=$(pt_sanitize "${app}_$h"); sn="${pfx}_$safe"
    pt_run_stage "$sn" "$app $h propkey" \
      "pt_fetch '$app' '$h' '$PT_PROPERTY_ID' '$PT_RUN_DIR/raw/$sn.out'"
  done
}

pt_bridgeflush_syncapi() { pt_bridgeflush_chained "pms-cm-bridge/hub-sync-api" "t_bfl_sync" "SYNC_API"; }
pt_bridgeflush_coreapi() { pt_bridgeflush_chained "cloudpms/entity-api" "t_bfl_core" "CORE_API"; }

# classification: ONE python pass over raw -> state/bfl_analysis.json (all facts derived)
pt_bridgeflush_classify() {
  python3 - "$PT_RUN_DIR" "$PT_PROPERTY_ID" <<'PYCLS'
import glob, json, os, re, sys
run, propkey = sys.argv[1], sys.argv[2]
raw = lambda p: sorted(glob.glob(os.path.join(run, "raw", p)))
UUID = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
USER = re.compile(r'(?:user|email|username|actor)["\s:=]+([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+)', re.I)
STATUS = re.compile(r'\s([1-5]\d\d)\s')
flushes = {}
# triggers: overall status + user
for f in raw("t_bfl_trig_*.out"):
    hour = f.rsplit("_", 1)[-1].replace(".out", "")
    for line in open(f, errors="ignore"):
        if "flush" not in line: continue
        for t in UUID.findall(line):
            d = flushes.setdefault(t, {"token": t, "hours": set(), "user": None, "overall": set(), "sublegs": {}})
            d["hours"].add(hour)
            m = STATUS.search(line)
            if m: d["overall"].add(m.group(1))
            u = USER.search(line)
            if u and not d["user"]: d["user"] = u.group(1)
# per-request lines: sub-leg statuses
for f in raw("t_bfl_req_*.out"):
    base = os.path.basename(f)
    tok = base.split("_")[3]
    d = flushes.get(tok)
    if not d:
        d = flushes.setdefault(tok, {"token": tok, "hours": set(), "user": None, "overall": set(), "sublegs": {}})
    for line in open(f, errors="ignore"):
        m = STATUS.search(line)
        st = m.group(1) if m else None
        if not st: continue
        u = USER.search(line)
        if u and not d["user"]: d["user"] = u.group(1)
        if "type=inventory" in line or "type%3Dinventory" in line.lower(): d["sublegs"].setdefault("inventory", set()).add(st)
        elif "type=core" in line or "type%3Dcore" in line.lower(): d["sublegs"].setdefault("core", set()).add(st)
        elif "hub-pms-sync" in line: d["sublegs"].setdefault("hub-pms-sync", set()).add(st)
        if "resync_pms_link" in line: d["overall"].add(st)
# hub-sync error class
sync = {"lines": 0, "update_failed_400": 0, "flush_failed": 0, "tokens": set(), "other_msgs": []}
for f in raw("t_bfl_sync_*.out"):
    for line in open(f, errors="ignore"):
        sync["lines"] += 1
        if "setRoomRate failed" in line and "400" in line: sync["update_failed_400"] += 1
        elif "setRoomRate failed" in line: sync["update_failed_400"] += 0
        if "Flushing property data failed" in line: sync["flush_failed"] += 1
        for t in UUID.findall(line): sync["tokens"].add(t)
        if "setRoomRate failed" not in line and "Flushing property data failed" not in line and len(sync["other_msgs"]) < 5:
            m = re.search(r'"msg"\s*:\s*"([^"]{1,120})"', line)
            if m: sync["other_msgs"].append(m.group(1))
# entity-api PUT enumeration
RATE = re.compile(r'(?:PUT|POST|PATCH)\s+(?:https?://\S+)?/properties/' + re.escape(propkey) + r'/room-types/([A-Za-z0-9_-]+)/room-rates/([A-Za-z0-9_-]+)\S*"?\s+(\d{3})\b')
TYPE = re.compile(r'(?:PUT|POST|PATCH)\s+(?:https?://\S+)?/properties/' + re.escape(propkey) + r'/room-types/([A-Za-z0-9_-]+)\S*"?\s+(\d{3})\b')
rate_puts, type_puts = {}, {}
for f in raw("t_bfl_core_*.out"):
    for line in open(f, errors="ignore"):
        m = RATE.search(line)
        if m:
            key = m.group(1) + "/" + m.group(2)
            rate_puts.setdefault(key, {}).setdefault(m.group(3), 0)
            rate_puts[key][m.group(3)] += 1
            continue
        m = TYPE.search(line)
        if m:
            type_puts.setdefault(m.group(1), {}).setdefault(m.group(2), 0)
            type_puts[m.group(1)][m.group(2)] += 1
culprit = sorted([k for k, v in rate_puts.items() if any(s.startswith(("4", "5")) for s in v)])
ok_rates = sorted([k for k, v in rate_puts.items() if not any(s.startswith(("4", "5")) for s in v)])
# derived failing sub-leg: majority of flushes with a 5xx on that leg
legfail = {}
for d in flushes.values():
    for leg, sts in d["sublegs"].items():
        if any(s.startswith("5") for s in sts): legfail[leg] = legfail.get(leg, 0) + 1
# v0.9.7b1 (calibration, real cloudpms/main 2026-11-02.txt): Rails logs NO request-completion
# doc for the flush GET - overall stays empty on real data; derive it from sub-legs.
for d in flushes.values():
    if not d["overall"] and d["sublegs"]:
        _sts = [s for v in d["sublegs"].values() for s in v]
        if _sts:
            d["overall"] = {"500"} if any(s.startswith("5") for s in _sts) else set(_sts)
failing_subleg = None
if legfail:
    top = sorted(legfail.items(), key=lambda kv: -kv[1])
    failing_subleg = top[0][0] if len(top) == 1 or top[0][1] > top[1][1] else "AMBIGUOUS:" + ",".join(legfail)
out = {
    "flushes": [{**d, "hours": sorted(d["hours"]), "overall": sorted(d["overall"]),
                 "sublegs": {k: sorted(v) for k, v in d["sublegs"].items()}} for d in flushes.values()],
    "sync": {**sync, "tokens": sorted(sync["tokens"])},
    "rate_puts": rate_puts, "type_puts": type_puts,
    "culprit_ids": culprit, "ok_rate_count": len(ok_rates),
    "failing_subleg": failing_subleg,
    "token_chain": sorted(sync["tokens"] & set(flushes.keys())),
}
json.dump(out, open(os.path.join(run, "state", "bfl_analysis.json"), "w"), indent=1)
print("[bridgeflush] classify: flushes=%d failing_subleg=%s culprits=%s ok_rates=%d" % (
    len(out["flushes"]), failing_subleg, culprit, len(ok_rates)))
PYCLS
}

pt_bridgeflush_origin() {
  local an="$PT_RUN_DIR/state/bfl_analysis.json"
  [ -s "$an" ] || { pt_log "[bridgeflush] no analysis - origin leg skipped"; return 0; }
  local culprits
  culprits=$(python3 -c "import json;print(' '.join(json.load(open('$an')).get('culprit_ids',[])))" 2>/dev/null)
  if [ -z "${culprits// /}" ]; then
    pt_log "[bridgeflush] no culprit derived - origin leg skipped"
    pt_note "- ORIGIN: skipped (no blocking room rate derived from entity-api evidence)"
    return 0
  fi
  local hours; hours=$(cat "$PT_RUN_DIR/state/t_bfl_trig_hours.txt" 2>/dev/null)
  if [ "$PT_FLUSH_ORIGIN_DAY" = "1" ]; then
    local d hh hours=""
    for d in $(cut -d- -f1-3 "$PT_RUN_DIR/state/t_bfl_trig_hours.txt" | sort -u); do
      for hh in $(seq -w 23 -1 00); do hours="$hours $d-$hh"; done
    done
  fi
  pt_note "- ORIGIN leg: platform apps by DERIVED culprit ids ($culprits) at flush hours${PT_FLUSH_ORIGIN_DAY:+}$([ "$PT_FLUSH_ORIGIN_DAY" = "1" ] && echo ' + full flush day' || echo ' (bounded; set PT_FLUSH_ORIGIN_DAY=1 for the full day)')"
  local pair id rt rr h sn app
  for pair in $culprits; do
    rr="${pair#*/}"
    for app in portal-property/gui-gateway portal-property/job-runner; do
      for h in $hours; do
        sn="t_bfl_origin_$(pt_sanitize "${app}_${h}_${rr}")"
        pt_run_stage "$sn" "$app $h culprit $rr" \
          "pt_fetch '$app' '$h' '$rr' '$PT_RUN_DIR/raw/$sn.out'"
      done
    done
  done
}

pt_bridgeflush_verdict() {
  python3 - "$PT_RUN_DIR" "$PT_PROPERTY_ID" "$PT_KB_PATH" <<'PYV'
import glob, json, os, sys
run, propkey, kbpath = sys.argv[1], sys.argv[2], sys.argv[3]
an = json.load(open(os.path.join(run, "state", "bfl_analysis.json")))
origin_hits = [f for f in glob.glob(os.path.join(run, "raw", "t_bfl_origin_*.out")) if os.path.getsize(f) > 0]
flushes, sync = an["flushes"], an["sync"]
culprits, okn = an["culprit_ids"], an["ok_rate_count"]
subleg = an["failing_subleg"]
G = {
    "FLUSH_TRIGGERED": len(flushes) > 0,
    "SUBLEG_ISOLATED": subleg is not None and not str(subleg).startswith("AMBIGUOUS"),
    "CM_PMS_SYNC_400": sync["update_failed_400"] > 0,
    "CORE_BLOCKER_DERIVED": len(culprits) >= 1,
    "FAIL_FAST_SINGLE": len(culprits) == 1 and okn >= 2,
    "TOKEN_CHAIN": len(an["token_chain"]) > 0,
    "ACTOR_CAPTURED": any(d.get("user") for d in flushes),
    "ORIGIN_FOUND": len(origin_hits) > 0,
}
sigs, pitfalls = [], []
try:
    kb = json.load(open(kbpath))
    lf = kb.get("bridge_flush", {})
    sigs = lf.get("validation_signatures", [])
    pitfalls = lf.get("pitfalls", [])
except Exception:
    pass
L = []
L.append("")
L.append("## BRIDGE-FLUSH VERDICT (derived from evidence; inputs were propkey + window only)")
L.append("")
L.append("### Gates")
for k, v in G.items():
    L.append("- [%s] %s%s" % ("x" if v else " ", k, "" if v else " - no evidence"))
L.append("")
L.append("### Flush runs (%d)" % len(flushes))
for d in flushes:
    legs = " ".join("%s=%s" % (k, "/".join(v)) for k, v in sorted(d["sublegs"].items()))
    L.append("- %s overall=%s user=%s | %s" % (d["token"], "/".join(d["overall"]) or "?",
                                              d.get("user") or "?", legs or "no sub-leg lines"))
L.append("")
if not flushes:
    L.append("**No flush triggers in window** - elimination fact within the swept hours only. Widen PT_FROM/PT_TO or confirm a flush was actually clicked.")
elif subleg != "hub-pms-sync":
    L.append("### PLAYBOOK BRANCH: failing sub-leg is **%s**, NOT hub-pms-sync" % subleg)
    L.append("- The hub-pms-sync 400 playbook does NOT apply. Evidence points at the '%s' leg; investigate that hop (raw/t_bfl_req_* carries the failing lines)." % subleg)
else:
    L.append("### Failing sub-leg: hub-pms-sync (inventory/core 204)")
    L.append("- hub-sync: setRoomRate-failed-400 lines=%d, flush wrappers=%d, tokens chained to cloudpms/main=%s" % (
        sync["update_failed_400"], sync["flush_failed"], ", ".join(an["token_chain"]) or "NONE"))
    if culprits:
        L.append("- **Blocking room rate (DERIVED): %s**" % ", ".join(culprits))
        for c in culprits:
            rt, rr = c.split("/", 1)
            L.append("  - GET http://cloudpms-entity-api/properties/%s/room-types/%s/room-rates/%s  (400 body is logged nowhere - inspect values directly)" % (propkey, rt, rr))
        if G["FAIL_FAST_SINGLE"]:
            L.append("- Fail-fast pattern CONFIRMED: %d distinct room rates updated 200, exactly 1 rejected - one invalid rate blocks the whole property flush." % okn)
        elif len(culprits) > 1:
            L.append("- MULTI-BLOCKER: %d distinct room rates rejected - not the classic single-blocker; fix all listed." % len(culprits))
        if an["type_puts"]:
            t200 = [k for k, v in an["type_puts"].items() if "200" in v]
            if t200: L.append("- Room-TYPE updates 200 while room-RATE 400s (type endpoints healthy: %s) - rate-level validation, not a type problem." % ", ".join(t200[:5]))
        if sigs:
            L.append("")
            L.append("### Validation signature checklist (KB bridge_flush - compare the GET against these)")
            for s in sigs:
                L.append("- %s: %s [%s]" % ("/".join(s.get("fields", [])), s.get("rule", "?"), s.get("reference", "")))
    else:
        L.append("- hub-sync 400s seen but NO failing PUT isolated in cloudpms/entity-api at the chained hours - partial evidence; check raw/t_bfl_core_* and widen hours.")
    if origin_hits:
        L.append("- ORIGIN: %d platform-side hit(s) for the culprit id - see raw/t_bfl_origin_* (who/when set the invalid values)." % len(origin_hits))
    elif culprits:
        L.append("- ORIGIN: no platform-side lines for the culprit id at flush hours (bounded scan; set PT_FLUSH_ORIGIN_DAY=1 for the full flush day, or trace earlier days manually).")
if pitfalls:
    L.append("")
    L.append("### KB pitfalls")
    for p in pitfalls[:6]: L.append("- %s" % p)
with open(os.path.join(run, "REPORT.md"), "a") as r:
    r.write("\n".join(L) + "\n")
print("\n".join(L[:12]))
PYV
}

pt_bridgeflush() {
  pt_note "- bridge-flush goal: chain cloudpms/main-$PT_REGION -> pms-cm-bridge/hub-sync-api -> cloudpms/entity-api; inputs = propkey+CloudPMS id+window; culprit DERIVED from logs (R27)"
  pt_run_stage bridgeflush_triggers "cloudpms/main flush triggers + per-request sub-leg status" "pt_bridgeflush_triggers"
  pt_run_stage bridgeflush_syncapi "hub-sync-api error confirmation (chained)" "pt_bridgeflush_syncapi"
  pt_run_stage bridgeflush_coreapi "cloudpms/entity-api room-rate PUT enumeration (chained)" "pt_bridgeflush_coreapi"
  pt_run_stage bridgeflush_classify "evidence classification (derived facts)" "pt_bridgeflush_classify"
  pt_run_stage bridgeflush_origin "culprit origin scan (platform apps, derived ids)" "pt_bridgeflush_origin"
  pt_run_stage bridgeflush_verdict "bridge-flush verdict (fail-fast / blocker / signatures)" "pt_bridgeflush_verdict"
}

# ---- main: task loader ---------------------------------------------------------
pt_main() {
  pt_goal_resolve
  echo "== PMS TOOL PASTE v${PT_VERSION} - case=$PT_CASE tasks='$PT_TASKS' mode=$PT_MODE goal='${PT_GOAL:-custom}' =="
  for task in $PT_TASKS; do
    case "$task" in
      trace) pt_trace;;
      fidelity) pt_fidelity;;
      ari)      pt_ari;;
      guiattrib) pt_guiattrib;;
      kb-test) pt_kb_test;;
      bridgeflush) pt_bridgeflush;;
      *) echo "[tasks] unknown task '$task' (trace|fidelity|kb-test|ari|guiattrib|bridgeflush)";;
    esac
  done
  echo "== DONE $(date -u +%FT%TZ) - results: $PT_RUN_DIR =="
  echo "fetch: cd ~/pms_tools/runs && zip -r ${PT_CASE}.zip '$PT_CASE' -x '__MACOSX*'"
}

# ---- fire: lock -> detached/foreground -----------------------------------------
# ---- run-mode gate: existing run dir -> resume / wipe / isolated suffix ------
pt_gate_run_dir() {
  [ -d "$PT_RUN_DIR" ] || return 0
  local finished=0 partial=0
  [ -f "$PT_RUN_DIR/verdict.json" ] && finished=1
  ls "$PT_RUN_DIR/state/"*.done >/dev/null 2>&1 && partial=1
  { [ "$finished" -eq 0 ] && [ "$partial" -eq 0 ]; } && return 0
  local mode default ans=""
  if [ "$finished" -eq 1 ]; then mode="$PT_ON_FINISHED"; default="suffix"; else mode="$PT_ON_EXISTS"; default="resume"; fi
  if [ "$mode" = "ask" ]; then
    if [ -t 0 ]; then
      if [ "$finished" -eq 1 ]; then
        read -t 30 -p "run dir FINISHED ($PT_RUN_DIR). [w]ipe+rerun / [s]uffix new isolated run? (default s, 30s): " ans || true
      else
        read -t 30 -p "run dir PARTIAL ($PT_RUN_DIR). [r]esume / [w]ipe / [s]uffix? (default r, 30s): " ans || true
      fi
      case "$ans" in [Ww]*) mode="wipe";; [Ss]*) mode="suffix";; [Rr]*) mode="resume";; *) mode="$default";; esac
    else
      mode="$default"
    fi
  fi
  case "$mode" in
    wipe)   echo "[run] wiping $PT_RUN_DIR"; rm -rf "$PT_RUN_DIR";;
    suffix) local i=2 base_dir="$PT_RUN_DIR" base_case="$PT_CASE"
            while [ -d "$base_dir-v$i" ]; do i=$((i + 1)); done
            PT_CASE="$base_case-v$i"; PT_RUN_DIR="$base_dir-v$i"
            echo "[run] isolating results -> $PT_RUN_DIR (previous run kept for crosscheck)";;
    resume) echo "[run] resuming $PT_RUN_DIR (finished stages are skipped)";;
  esac
  mkdir -p "$PT_RUN_DIR/raw" "$PT_RUN_DIR/state"
}

pt_fire() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$PT_RUN_DIR/.lock"
    if ! flock -n 9; then
      echo "PMS TOOL: another runner is ACTIVE on $PT_CASE (lock $PT_RUN_DIR/.lock)."
      echo "Check: lsof $PT_RUN_DIR/detached_*.log - kill the old bash PID(s) first. Not starting."
      return 1
    fi
  fi
  pt_gate_run_dir
  if [ "$PT_MODE" = "run" ] && [ "$PT_DETACH" = "1" ]; then
    local _log="$PT_RUN_DIR/detached_$(date -u +%Y%m%dT%H%M%SZ).log"
    ( echo "[kb] $(kb schema_version) @ $PT_KB_PATH (PT_KB_FILE=$PT_KB_FILE) channels=[$(kb_list channels)] pms=[$(kb_list pms)]"; [ -z "$(kb channel_codes._note)" ] && echo "[kb] WARN: loaded KB has NO channel_codes - prefix resolution DISABLED, blind discovery possible. Deploy a current connector_kb.json."; pt_main ) >"$_log" 2>&1 &
    local _pid=$!
    disown 2>/dev/null || true
    echo "PMS TOOL PASTE v${PT_VERSION} detached: pid=$_pid"
    echo "log: $_log"
    echo "monitor: tail -f '$_log'"
    echo "SSH drops will not stop it. Re-paste this file to resume finished stages."
  else
    pt_main
  fi
}
pt_fire

# ############################################################################
#  UNIFIED INVESTIGATOR v0.9.5b3-paste (BETA) - R20 KB app paths authoritative for channel sys (OTA5- -> cm-ota5, never channels-hub); R19 series; R18 empty-pattern refusal; R17 billing: = b7 + KB v0.9.0: pms.CloudPMS module (pms-cm-bridge/state-sync-api delivery, FD method sweeps, deferred-jobs allocation, mail-relay confirmations), OTA3 module verified to component level (CASE-00000004), PMS_BRIDGE_SYNC_DISABLED signature. trace mode = the booking-delivery path.
  #  v0.9.7b2 (2026-11-02): resolve convention fallback (cm-<prefix>, pool-verified) + sys-sweep suppressed on name-match guesses (wrong-system burn, case CASE-00000002). v0.9.7b1: leg-A calibration on real cloudpms/main - derive overall status from sub-legs (Rails logs no flush completion doc). v0.9.7: R27 bridge-flush goal - evidence-driven CM->CloudPMS flush failure tracer (sub-leg isolation, entity-api PUT enumeration, DERIVED culprit room rate, fail-fast detection, signature checklist). v0.9.6: R22 LGCY ChannelRelay ARI leg + CUR skip. v0.9.5b3: R24 goal-aware sweep break (rate-mismatch sweeps past booking-consumption hours to the value SET), R25 multi-word push patterns preserved, R26 mapping-api in push pool (cm-channelrelay has no inventory comp). v0.9.5b2: R23 PT_SKIP_LEGS stage skipper; R21 refusals mark done (no re-paste retry loop). v0.9.5b1: R22 PT_GOAL playbooks (overbooking|missing-reservation|rate-mismatch|delivery-failure|billing-trace) with fail-fast input contract + goal verdict matrix; R21 weak-numeric pattern guard (<=5 digits refused, 6-7 warned); R19b series REPORT fallback; retention horizon stamp (~18mo S3). b7 (2026-11-01): guiattrib fact correction - setChannelProperty IS the logged mutation + link-api PUT is the persisted write; variables DB-only; fgrep-not-grep for decimals. b6: R15 guiattrib mode - flowToken-correlated GUI actor attribution (gui-gateway email/IP, dispatchSyncEvent recon chain, entity-api audit write). b5: R13 evidence legs - CloudPMS bridge pushed values (chained hours, propkey) + booking XML pull (booking hour +/-1h, full ref + bare code). b4: R11 backward-only series (+day mode), R12 field-aware value matching (129990!=999, status:200!=200). b3: R10 bounded hour-series + PT_REGION selector + channel-uuid elimination probe
  #    + push-leg hit-hour chaining (claimed moment -> backward sweep to PT_FROM, then STOP: facts, no
  #    auto-expansion); R9 capped fetches (no 1GB dumps); R5' continue fix. b2: anchor-first, R8/R1a/R6.
 #  b2 (2026-10-31): R7 anchor-first ari inventory leg (hour blobs; full-day scans timed out live at 1500s x7),
  #    R8 ari KB write-back, R1a stale PT_KB_PATH guard, R5' bare-system resolve fix, R6 component-scoped preflight.
#  NEW: PT_TASKS="ari" - value attribution + ARI push tracing (both CM directions). Answers: who/what set
#   a rate/availability/restriction value, when, source (manual user via gui-gateway email | PMS push via originSystem),
#   what CM persisted, what was pushed to the channel, and the OTA ack. Driven by KB v0.2.0 ari_paths/attribution.
#  GATES (ari): SOURCE -> INGEST (N/A for manual origin) -> CM_PERSIST -> CHANNEL_PUSH -> OTA_ACK.
#  METHOD: day-granularity sweeps over PT_FROM..PT_TO (7-day default when CX gives no anchor); avail-api
#   BOTH regions by hotel uuid; gui-gateway by SET-line flowToken for the user email; CloudPMS ingest via
#   pms-cm-bridge/avail-sync by propkey; push leg per channel (pool-discovered inventory comps, fallback
#   sys/avail-gateway). Blind hop hub-xbridge/ari-relay NEVER swept (KB design fact). Delta-check caveat:
#   an unchanged value leaves NO avail-api line (empty SET evidence != not delivered).
#  UNCHANGED: 'trace', 'fidelity', 'kb-test' tasks of v0.7.9.1 run exactly as before (all inputs/knobs kept).
#  KB: external connector_kb.json in $PT_KB_DIR (not embedded); self-updating via pt_kb_write.
# ############################################################################

