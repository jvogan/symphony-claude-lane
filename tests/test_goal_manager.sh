#!/usr/bin/env bash
# test_goal_manager.sh — isolated goal-manager (goal layer) tests.
#
# Uses a fake curl that answers Linear GraphQL from per-test fixtures; no real
# Linear mutation. Mirrors test_release_manager.sh: dry-run safety, apply command
# shape, the dedup/budget/streak guards, fail-closed reads, prompt SIGTERM, the
# live lock, and the GraphQL-unused-variable lint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

unset AUTONOMY_ROOT _SYMPHONY_CLAUDE_LANE_ENV_LOADED
# shellcheck disable=SC1091
source "$ROOT/env.sh"

PASS=0
FAIL=0
FAILED=()
ok(){ echo "  PASS  $*"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL  $*" >&2; FAIL=$((FAIL+1)); FAILED+=("$*"); }
banner(){ echo ""; echo "=== $* ==="; }

CLEANUP_ACTIONS=()
register_cleanup(){ CLEANUP_ACTIONS+=("$*"); }
run_cleanup() {
  local rc="$?"
  for (( i=${#CLEANUP_ACTIONS[@]}-1; i>=0; i-- )); do
    eval "${CLEANUP_ACTIONS[$i]}" >/dev/null 2>&1 || true
  done
  if (( FAIL > 0 )); then
    echo ""; echo "FAILED:"; printf '  - %s\n' "${FAILED[@]}"; exit 1
  fi
  exit "$rc"
}
trap run_cleanup EXIT INT TERM

banner "Setup"
TMP="$(mktemp -d -t goal-manager-test.XXXXXX)"
register_cleanup "rm -rf '$TMP'"
export CLAUDE_RUNS_ROOT="$TMP/runs"
mkdir -p "$CLAUDE_RUNS_ROOT"

# Pin a Linear key so require_linear passes; the fake curl never authenticates.
export LINEAR_API_KEY="stub-key"

GM="$ROOT/bin/goal-manager"
export FAKE_PROJECT_JSON="$TMP/project.json"      # the project(id) snapshot
export CURL_LOG="$TMP/curl.log"
export FAKE_LABEL_EMPTY="${FAKE_LABEL_EMPTY:-}"   # set non-empty to force label-not-found

STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/curl" <<'CURL'
#!/usr/bin/env bash
# No set -e: the arg scan uses short-circuits that return non-zero on no-match.
data=""; prev=""
for a in "$@"; do if [[ "$prev" == "--data" ]]; then data="$a"; fi; prev="$a"; done
q="$(jq -r '.query' <<<"$data" 2>/dev/null || echo "")"
log(){ printf 'OP:%s\n' "$1" >> "${CURL_LOG:?}"; }
case "$q" in
  *"projectCreate"*)   log projectCreate;   printf '%s' '{"data":{"projectCreate":{"project":{"id":"proj-1","url":"https://linear.app/x/project/proj-1"}}}}' ;;
  *"projectUpdate"*)   log projectUpdate;   printf '%s' '{"data":{"projectUpdate":{"success":true}}}' ;;
  *"project(id"*)      log projectRead;     cat "${FAKE_PROJECT_JSON:?}" ;;
  *"issueLabelCreate"*) log issueLabelCreate; printf '%s' '{"data":{"issueLabelCreate":{"issueLabel":{"id":"lbl-new"}}}}' ;;
  *"issueLabels(filter"*)
       log issueLabelsRead
       if [[ -n "${FAKE_LABEL_EMPTY:-}" ]]; then printf '%s' '{"data":{"issueLabels":{"nodes":[]}}}'
       else printf '%s' '{"data":{"issueLabels":{"nodes":[{"id":"lbl-1","name":"x"}]}}}'; fi ;;
  *"issueCreate"*)     log issueCreate;     printf '%s' '{"data":{"issueCreate":{"issue":{"id":"iss-new","identifier":"TEAM-100","url":"https://linear.app/x/issue/TEAM-100"}}}}' ;;
  *"issueUpdate"*)     log issueUpdate;     printf '%s' '{"data":{"issueUpdate":{"success":true}}}' ;;
  *"issues(filter"*)   log issuesRead
       # Simulate the workspace index lagging a just-created ticket (returns empty)
       # when FAKE_ISSUES_EMPTY is set, so snapshot-based uuid resolution is exercised.
       if [[ -n "${FAKE_ISSUES_EMPTY:-}" ]]; then printf '%s' '{"data":{"issues":{"nodes":[]}}}'
       else printf '%s' '{"data":{"issues":{"nodes":[{"id":"iss-uuid-9"}]}}}'; fi ;;
  *"teams(filter"*)    log teamsRead;       printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}' ;;
  *"team(id"*)         log teamStatesRead;  printf '%s' '{"data":{"team":{"states":{"nodes":[{"id":"st-done","name":"Done","type":"completed"},{"id":"st-todo","name":"Todo","type":"unstarted"}]}}}}' ;;
  *"commentCreate"*)   log commentCreate;   printf '%s' '{"data":{"commentCreate":{"success":true}}}' ;;
  *)                   log unknown;         printf '%s' '{"data":{}}' ;;
esac
CURL
chmod +x "$STUB_DIR/curl"
export PATH="$STUB_DIR:$PATH"
ok "fake curl (Linear) ready"

# ---- fixture builders -------------------------------------------------------

# goalstate_block STATUS BUDGET_TASKS BUDGET_PASSES NO_NEW_WORK_HALT [PLANNERS_MINTED]
goalstate_block() {
  local json b64
  json="$(jq -nc --arg s "$1" --argjson bt "$2" --argjson bp "$3" --argjson nh "$4" --argjson pm "${5:-0}" \
    '{v:1,status:$s,name:"Test goal",north_star:"north star text",acceptance:"acc",team_key:"TEAM",budget_tasks:$bt,budget_passes:$bp,no_new_work_halt:$nh,task_label:"lane:claude",planners_minted:$pm}')"
  b64="$(printf '%s' "$json" | openssl base64 -A)"
  printf '%s\n%s\n%s' '<!-- goal-state -->' "$b64" '<!-- /goal-state -->'
}

# raw_goalstate_block JSON  — build a block from arbitrary JSON (for forgery/injection tests)
raw_goalstate_block() {
  printf '%s\n%s\n%s' '<!-- goal-state -->' "$(printf '%s' "$1" | openssl base64 -A)" '<!-- /goal-state -->'
}

# work_issue IDENT TITLE TYPE  /  planner_issue IDENT TYPE EXTRA_LABEL
work_issue()    { jq -nc --arg i "$1" --arg t "$2" --arg ty "$3" --arg c "${4:-2026-01-01}" \
  '{id:$i,identifier:$i,title:$t,createdAt:$c,state:{name:$ty,type:$ty},labels:{nodes:[]}}'; }
planner_issue() { jq -nc --arg i "$1" --arg ty "$2" --arg extra "${3:-}" --arg c "${4:-2026-02-01}" \
  '{id:$i,identifier:$i,title:("planner "+$i),createdAt:$c,state:{name:$ty,type:$ty},
    labels:{nodes:( [{name:"goal:planner"}] + (if $extra=="" then [] else [{name:$extra}] end) )}}'; }

# write_project CONTENT_BLOCK ISSUES_JSON_ARRAY   (or "ERR" block to fail reads)
# The state block lives in the project's `content` field (description is 255-char
# capped in the real API), so the fixture mirrors that.
write_project() {
  if [[ "$1" == "ERR" ]]; then printf '%s' '{"errors":[{"message":"boom"}]}' > "$FAKE_PROJECT_JSON"; return; fi
  jq -nc --arg c "$1" --argjson iss "$2" \
    '{data:{project:{id:"proj-1",name:"Test goal",content:$c,issues:{nodes:$iss}}}}' > "$FAKE_PROJECT_JSON"
}

# ---- offline validation -----------------------------------------------------
banner "Usage + offline validation"
# Capture-then-grep: under pipefail a `$GM ... | grep` pipeline reports $GM's
# non-zero exit even when grep matches, so we capture (swallowing the expected
# non-zero) and grep the variable.
rc=0; "$GM" >/dev/null 2>&1 || rc=$?; [[ "$rc" -eq 2 ]] && ok "no-args exits 2" || bad "no-args wrong exit ($rc)"
rc=0; "$GM" --help >/dev/null 2>&1 || rc=$?; [[ "$rc" -eq 0 ]] && ok "--help exits 0" || bad "--help nonzero ($rc)"
o="$("$GM" frobnicate 2>&1 || true)";                                          grep -q "unknown command" <<<"$o" && ok "bogus command rejected" || bad "bogus command not rejected"
o="$("$GM" next-planner 2>&1 || true)";                                        grep -q "requires --goal" <<<"$o" && ok "missing --goal rejected" || bad "missing --goal not rejected"
o="$("$GM" add-tasks --goal P --planner-ticket 'bad!' --no-tasks 2>&1 || true)"; grep -q "TEAM-123" <<<"$o" && ok "bad planner-ticket rejected" || bad "bad planner-ticket not rejected"
o="$(env LINEAR_API_KEY= "$GM" status --goal P 2>&1 || true)";                 grep -q "LINEAR_API_KEY is required" <<<"$o" && ok "no key fails closed" || bad "no key not rejected"

# ---- status -----------------------------------------------------------------
banner "status: derived counts + terminal flag"
ISS="$(jq -nc --argjson a "$(work_issue TEAM-1 'task one' unstarted)" \
                --argjson b "$(work_issue TEAM-2 'task two' completed)" \
                --argjson c "$(planner_issue TEAM-9 started)" '[$a,$b,$c]')"
write_project "$(goalstate_block active 20 10 2)" "$ISS"
out="$("$GM" status --goal proj-1 2>&1)"
echo "$out" | sed 's/^/    /'
echo "$out" | jq -e '.counts.total_tasks==2 and .counts.open_tasks==1 and .counts.done_tasks==1' >/dev/null 2>&1 \
  && ok "status counts work tickets correctly" || bad "status counts wrong"
echo "$out" | jq -e '.counts.pending_planners==1 and (.counts.pending_planner_ids|index("TEAM-9"))' >/dev/null 2>&1 \
  && ok "status surfaces pending planner" || bad "status missed pending planner"
echo "$out" | jq -e '.status=="active" and .terminal==false' >/dev/null 2>&1 \
  && ok "active goal is not terminal" || bad "active goal flagged terminal"
echo "$out" | jq -e '.north_star=="north star text"' >/dev/null 2>&1 \
  && ok "status decodes north_star from the base64 state block" || bad "status did not decode state block"

banner "status: terminal when no-work streak hits the halt threshold"
ISS="$(jq -nc --argjson p1 "$(planner_issue TEAM-10 completed goal:nowork 2026-02-01)" \
                --argjson p2 "$(planner_issue TEAM-11 canceled goal:nowork 2026-02-02)" '[$p1,$p2]')"
write_project "$(goalstate_block active 20 10 2)" "$ISS"
"$GM" status --goal proj-1 2>/dev/null | jq -e '.counts.nowork_streak==2 and .terminal==true' >/dev/null 2>&1 \
  && ok "nowork streak >= halt -> terminal" || bad "streak terminal not detected"

banner "status: terminal when planner-pass budget is spent"
ISS="$(jq -nc --argjson p1 "$(planner_issue TEAM-10 completed goal:planned 2026-02-01)" \
                --argjson p2 "$(planner_issue TEAM-11 completed goal:planned 2026-02-02)" '[$p1,$p2]')"
write_project "$(goalstate_block active 20 2 5)" "$ISS"
"$GM" status --goal proj-1 2>/dev/null | jq -e '.counts.planner_passes==2 and .terminal==true' >/dev/null 2>&1 \
  && ok "passes >= budget_passes -> terminal" || bad "pass-budget terminal not detected"

banner "status: explicit status!=active is terminal"
write_project "$(goalstate_block "done" 20 10 2)" "[]"
"$GM" status --goal proj-1 2>/dev/null | jq -e '.status=="done" and .terminal==true' >/dev/null 2>&1 \
  && ok "status=done -> terminal" || bad "done not terminal"

# ---- dry-run safety ---------------------------------------------------------
banner "Dry-run performs NO Linear mutations"
ISS="$(jq -nc --argjson a "$(work_issue TEAM-1 'existing' unstarted)" '[$a]')"
write_project "$(goalstate_block active 20 10 2)" "$ISS"
TASKS="$TMP/wave.json"; printf '%s' '[{"title":"brand new task","description":"do it"}]' > "$TASKS"
: > "$CURL_LOG"
{ "$GM" add-tasks --goal proj-1 --tasks-file "$TASKS" 2>&1 || true; } | sed 's/^/    /'
{ "$GM" next-planner --goal proj-1 2>&1 || true; } | sed 's/^/    /'
if grep -qE 'OP:(issueCreate|projectUpdate|issueUpdate|issueLabelCreate|commentCreate)' "$CURL_LOG"; then
  bad "dry-run issued a mutating GraphQL op"; grep '^OP:' "$CURL_LOG" | sort -u | sed 's/^/    /'
else
  ok "dry-run made only read queries (no mutations)"
fi
dry_locks="$(find "$CLAUDE_RUNS_ROOT" -maxdepth 1 -name '.goal-manager.lock-*.d' -type d 2>/dev/null | wc -l | tr -d ' ')"
[[ "$dry_locks" == "0" ]] && ok "dry-run acquired no lock" || bad "dry-run created $dry_locks lock dir(s)"

# ---- add-tasks: dedup / budget / cap ---------------------------------------
banner "add-tasks: dedups against existing titles (case/space-insensitive)"
ISS="$(jq -nc --argjson a "$(work_issue TEAM-1 'Add Login Form' unstarted)" '[$a]')"
write_project "$(goalstate_block active 20 10 2)" "$ISS"
TASKS="$TMP/wave-dupe.json"; printf '%s' '[{"title":"  add login   form "},{"title":"a genuinely new task"}]' > "$TASKS"
: > "$CURL_LOG"
out="$("$GM" add-tasks --goal proj-1 --tasks-file "$TASKS" --apply 2>&1)"
echo "$out" | sed 's/^/    /'
creates="$(grep -c 'OP:issueCreate' "$CURL_LOG" || true)"
grep -q "dedup skip" <<<"$out" && [[ "$creates" == "1" ]] && ok "dedup skips the duplicate, creates only the new task" \
  || bad "dedup wrong (creates=$creates)"

banner "add-tasks: hard budget cap refuses creation beyond budget_tasks"
ISS="$(jq -nc --argjson a "$(work_issue TEAM-1 't1' unstarted)" --argjson b "$(work_issue TEAM-2 't2' unstarted)" '[$a,$b]')"
write_project "$(goalstate_block active 2 10 2)" "$ISS"   # budget_tasks=2, already 2 tasks
TASKS="$TMP/wave-budget.json"; printf '%s' '[{"title":"over budget task"}]' > "$TASKS"
: > "$CURL_LOG"
out="$("$GM" add-tasks --goal proj-1 --tasks-file "$TASKS" --apply 2>&1)"
echo "$out" | sed 's/^/    /'
if grep -q "budget reached" <<<"$out" && ! grep -q 'OP:issueCreate' "$CURL_LOG"; then
  ok "budget cap blocks creation (no issueCreate)"
else
  bad "budget cap did not block creation"
fi

banner "add-tasks: --max-per-wave caps creations this pass"
write_project "$(goalstate_block active 50 10 2)" "[]"
TASKS="$TMP/wave-many.json"; printf '%s' '[{"title":"w1"},{"title":"w2"},{"title":"w3"}]' > "$TASKS"
: > "$CURL_LOG"
out="$("$GM" add-tasks --goal proj-1 --tasks-file "$TASKS" --max-per-wave 1 --apply 2>&1)"
echo "$out" | sed 's/^/    /'
creates="$(grep -c 'OP:issueCreate' "$CURL_LOG" || true)"
[[ "$creates" == "1" ]] && grep -q "per-wave cap" <<<"$out" && ok "max-per-wave caps to 1 create" || bad "max-per-wave wrong (creates=$creates)"

# ---- add-tasks: records the pass + closes the planner ticket ----------------
banner "add-tasks --planner-ticket: created>0 closes planner tagged goal:planned"
write_project "$(goalstate_block active 50 10 2)" "[]"
TASKS="$TMP/wave-ok.json"; printf '%s' '[{"title":"real work item"}]' > "$TASKS"
: > "$CURL_LOG"
out="$("$GM" add-tasks --goal proj-1 --tasks-file "$TASKS" --planner-ticket TEAM-9 --apply 2>&1)"
echo "$out" | sed 's/^/    /'
if grep -q 'OP:issueCreate' "$CURL_LOG" && grep -q 'OP:commentCreate' "$CURL_LOG" && grep -q 'OP:issueUpdate' "$CURL_LOG"; then
  ok "wave created, pass-marker comment posted, planner ticket closed"
else
  bad "planner pass not recorded/closed"; grep '^OP:' "$CURL_LOG" | sort | uniq -c | sed 's/^/    /'
fi
grep -q "closed TEAM-9 \[goal:planned\]" <<<"$out" && ok "planner closed tagged goal:planned" || bad "planner not tagged planned"

banner "records the pass via the SNAPSHOT uuid when the issues-by-number index lags (live regression)"
# Planner TEAM-9 is in the project snapshot, but the workspace issues(filter:number)
# index returns empty (eventual consistency right after creation). The pass must
# still record + close the planner by resolving its uuid from the snapshot.
ISS="$(jq -nc --argjson p "$(planner_issue TEAM-9 unstarted)" '[$p]')"
write_project "$(goalstate_block active 50 10 2 1)" "$ISS"
: > "$CURL_LOG"
out="$(FAKE_ISSUES_EMPTY=1 "$GM" add-tasks --goal proj-1 --no-tasks --planner-ticket TEAM-9 --apply 2>&1)"
echo "$out" | sed 's/^/    /'
if grep -q "closed TEAM-9" <<<"$out" && grep -q 'OP:issueUpdate' "$CURL_LOG"; then
  ok "pass recorded + planner closed via snapshot uuid despite a lagging index"
else
  bad "snapshot-uuid resolution failed (index-lag regression)"
fi

banner "add-tasks --no-tasks: records a no-work pass, closes planner tagged goal:nowork"
write_project "$(goalstate_block active 50 10 2)" "[]"
: > "$CURL_LOG"
out="$("$GM" add-tasks --goal proj-1 --no-tasks --planner-ticket TEAM-9 --apply 2>&1)"
echo "$out" | sed 's/^/    /'
if ! grep -q 'OP:issueCreate' "$CURL_LOG" && grep -q "closed TEAM-9 \[goal:nowork\]" <<<"$out"; then
  ok "no-work pass creates nothing and tags planner goal:nowork"
else
  bad "no-work pass wrong"
fi

# ---- next-planner: mint / halt / skip ---------------------------------------
banner "next-planner: mints the next planner when active + budget + no outstanding slot"
# 1 completed pass, planners_minted=1 -> outstanding=0 -> may mint pass 2.
ISS="$(jq -nc --argjson p1 "$(planner_issue TEAM-10 completed goal:planned 2026-02-01)" '[$p1]')"
write_project "$(goalstate_block active 20 10 2 1)" "$ISS"
: > "$CURL_LOG"
out="$("$GM" next-planner --goal proj-1 --apply 2>&1)"
echo "$out" | sed 's/^/    /'
grep -q 'OP:issueCreate' "$CURL_LOG" && grep -q "minted planner" <<<"$out" && ok "next-planner mints (pass 2)" || bad "next-planner did not mint"
grep -q "halting goal" <<<"$out" && bad "next-planner halted instead of minting" || ok "next-planner did not halt the goal"

banner "next-planner: durable mint gate blocks a double-mint under Linear list lag (#3)"
# A planner was minted (planners_minted=1) but is NOT yet visible in the issues list
# (eventual consistency). The derived pending count is 0, but the durable
# reserved-minus-completed gate must still block a second mint.
write_project "$(goalstate_block active 20 10 2 1)" "[]"
: > "$CURL_LOG"
out="$("$GM" next-planner --goal proj-1 --apply 2>&1)"
echo "$out" | sed 's/^/    /'
if grep -q "outstanding" <<<"$out" && ! grep -q 'OP:issueCreate' "$CURL_LOG"; then
  ok "durable gate blocks mint while a reserved planner is not yet visible"
else
  bad "durable gate failed — double-mint possible under lag"
fi

banner "next-planner: halts (status->halted) when no-work streak hits threshold"
ISS="$(jq -nc --argjson p1 "$(planner_issue TEAM-10 completed goal:nowork 2026-02-01)" \
                --argjson p2 "$(planner_issue TEAM-11 completed goal:nowork 2026-02-02)" '[$p1,$p2]')"
write_project "$(goalstate_block active 20 10 2 2)" "$ISS"
: > "$CURL_LOG"
out="$("$GM" next-planner --goal proj-1 --apply 2>&1)"
echo "$out" | sed 's/^/    /'
if grep -q "halting goal" <<<"$out" && grep -q 'OP:projectUpdate' "$CURL_LOG" && ! grep -q 'OP:issueCreate' "$CURL_LOG"; then
  ok "streak halt: status persisted, no new planner minted"
else
  bad "streak halt wrong"
fi

banner "next-planner: halts when planner-pass budget is spent"
ISS="$(jq -nc --argjson p1 "$(planner_issue TEAM-10 completed goal:planned 2026-02-01)" \
                --argjson p2 "$(planner_issue TEAM-11 completed goal:planned 2026-02-02)" '[$p1,$p2]')"
write_project "$(goalstate_block active 20 2 5 2)" "$ISS"   # budget_passes=2, already 2
: > "$CURL_LOG"
out="$("$GM" next-planner --goal proj-1 --apply 2>&1)"
echo "$out" | sed 's/^/    /'
if grep -q "budget spent" <<<"$out" && ! grep -q 'OP:issueCreate' "$CURL_LOG"; then
  ok "pass-budget halt: no new planner minted"
else
  bad "pass-budget halt wrong"
fi

banner "next-planner: never mints a second planner while one is outstanding"
ISS="$(jq -nc --argjson p "$(planner_issue TEAM-9 started)" '[$p]')"
write_project "$(goalstate_block active 20 10 2 1)" "$ISS"   # minted=1, 0 completed -> outstanding
: > "$CURL_LOG"
out="$("$GM" next-planner --goal proj-1 --apply 2>&1)"
echo "$out" | sed 's/^/    /'
if grep -q "outstanding" <<<"$out" && ! grep -q 'OP:issueCreate' "$CURL_LOG"; then
  ok "outstanding planner blocks a duplicate mint"
else
  bad "outstanding-planner guard failed"
fi

# ---- complete ---------------------------------------------------------------
banner "complete: persists status=done and closes the planner ticket"
write_project "$(goalstate_block active 20 10 2)" "[]"
: > "$CURL_LOG"
out="$("$GM" complete --goal proj-1 --reason "acceptance met" --planner-ticket TEAM-9 --apply 2>&1)"
echo "$out" | sed 's/^/    /'
if grep -q 'OP:projectUpdate' "$CURL_LOG" && grep -q "status -> done" <<<"$out" && grep -q 'OP:issueUpdate' "$CURL_LOG"; then
  ok "complete sets done + closes planner"
else
  bad "complete wrong"
fi

# ---- tick heartbeat ---------------------------------------------------------
banner "tick: mints a planner when backlog is low and none pending"
write_project "$(goalstate_block active 20 10 2)" "[]"   # open_tasks=0 <= backlog_min(0)
: > "$CURL_LOG"
out="$("$GM" tick --goal proj-1 --apply 2>&1)"
echo "$out" | sed 's/^/    /'
grep -q "minting next planner" <<<"$out" && grep -q 'OP:issueCreate' "$CURL_LOG" && ok "tick mints when idle" || bad "tick did not mint when idle"

banner "tick: waits (no mint) while a planner is pending dispatch"
ISS="$(jq -nc --argjson p "$(planner_issue TEAM-9 unstarted)" '[$p]')"
write_project "$(goalstate_block active 20 10 2)" "$ISS"
: > "$CURL_LOG"
out="$("$GM" tick --goal proj-1 --apply 2>&1)"
echo "$out" | sed 's/^/    /'
if grep -q "pending dispatch" <<<"$out" && ! grep -q 'OP:issueCreate' "$CURL_LOG"; then
  ok "tick waits on a pending planner"
else
  bad "tick minted despite a pending planner"
fi

banner "tick: backlog sufficient -> no planner this pass"
ISS="$(jq -nc --argjson a "$(work_issue TEAM-1 't1' unstarted)" --argjson b "$(work_issue TEAM-2 't2' unstarted)" '[$a,$b]')"
write_project "$(goalstate_block active 20 10 2)" "$ISS"
: > "$CURL_LOG"
out="$("$GM" tick --goal proj-1 --apply --backlog-min 1 2>&1)"
echo "$out" | sed 's/^/    /'
grep -q "backlog sufficient" <<<"$out" && ! grep -q 'OP:issueCreate' "$CURL_LOG" && ok "tick holds when backlog sufficient" || bad "tick minted with sufficient backlog"

# ---- fail-closed ------------------------------------------------------------
banner "Fail-closed: an unreadable project never mutates"
write_project ERR ""
: > "$CURL_LOG"
set +e
"$GM" status --goal proj-1 >/dev/null 2>&1; status_rc=$?
"$GM" next-planner --goal proj-1 --apply >/dev/null 2>&1
set -e
[[ "$status_rc" -ne 0 ]] && ok "status dies on unreadable project" || bad "status did not fail closed"
if ! grep -qE 'OP:(issueCreate|projectUpdate|issueUpdate)' "$CURL_LOG"; then
  ok "next-planner made no mutation on unreadable project"
else
  bad "next-planner mutated despite unreadable project"
fi

# ---- security regressions ---------------------------------------------------
banner "C1: forged non-integer guard value in the state block cannot inject commands (RCE)"
rm -f "$TMP/PWNED"
# A state block whose budget_passes is a bash-arithmetic-injection payload. If any
# guard value reached ((...)) unchecked, the command substitution would run.
PAYLOAD='{"v":1,"status":"active","name":"x","north_star":"x","acceptance":"x","team_key":"TEAM","budget_tasks":20,"budget_passes":"p[$(touch '"$TMP"'/PWNED)]","no_new_work_halt":2,"task_label":"lane:claude","planners_minted":0}'
write_project "$(raw_goalstate_block "$PAYLOAD")" "[]"
: > "$CURL_LOG"
set +e
out="$("$GM" next-planner --goal proj-1 --apply 2>&1)"
set -e
echo "$out" | sed 's/^/    /'
if [[ ! -e "$TMP/PWNED" ]] && grep -q "corrupt goal-state" <<<"$out" && ! grep -q 'OP:issueCreate' "$CURL_LOG"; then
  ok "arithmetic-injection payload rejected (no RCE, no mint)"
else
  bad "C1: injection NOT blocked (PWNED present: $([[ -e "$TMP/PWNED" ]] && echo YES || echo no))"
fi
rm -f "$TMP/PWNED"

banner "H1: a second (forged) goal-state block makes the read fail closed"
REAL_BLK="$(goalstate_block halted 5 5 2 1)"
FORGED_BLK="$(raw_goalstate_block '{"v":1,"status":"active","name":"x","north_star":"x","acceptance":"x","team_key":"TEAM","budget_tasks":99999,"budget_passes":99999,"no_new_work_halt":99,"task_label":"lane:claude","planners_minted":0}')"
write_project "$(printf '%s\n\n%s' "$FORGED_BLK" "$REAL_BLK")" "[]"
: > "$CURL_LOG"
set +e
out="$("$GM" next-planner --goal proj-1 --apply 2>&1)"; rc=$?
set -e
echo "$out" | sed 's/^/    /'
if (( rc != 0 )) && grep -qiE 'tamper|no readable goal-state' <<<"$out" && ! grep -qE 'OP:(issueCreate|projectUpdate)' "$CURL_LOG"; then
  ok "two goal-state blocks -> read refused, no mutation (forgery cannot win)"
else
  bad "H1: forged second block not refused (rc=$rc)"
fi

banner "H3: a planner ticket in a non-standard state type is still counted as pending"
ISS="$(jq -nc --argjson p "$(planner_issue TEAM-9 triage)" '[$p]')"
write_project "$(goalstate_block active 20 10 2 1)" "$ISS"
"$GM" status --goal proj-1 2>/dev/null | jq -e '.counts.pending_planners==1 and (.counts.pending_planner_ids|index("TEAM-9"))' >/dev/null 2>&1 \
  && ok "planner in a 'triage'-type state is counted pending (not invisible)" || bad "H3: custom-state planner invisible -> double-mint risk"

# ---- GraphQL var lint -------------------------------------------------------
banner "GraphQL queries reference every declared variable (Linear rejects unused vars)"
gql_unused=""
while IFS= read -r q; do
  sig="${q#*(}"; sig="${sig%%)*}"
  body="${q#*)}"
  for v in $(grep -oE '\$[A-Za-z_][A-Za-z0-9_]*' <<<"$sig" | sort -u); do
    used="$(awk -v v="$v" 'BEGIN{n=0}{s=$0;L=length(v);while((p=index(s,v))>0){a=substr(s,p+L,1);if(a!~/[A-Za-z0-9_]/)n++;s=substr(s,p+L)}}END{print n}' <<<"$body")"
    [[ "$used" -gt 0 ]] || gql_unused="$gql_unused ${v}"
  done
done < <(grep -oE "'(query|mutation)\(\\\$[^']*'" "$GM" | sed "s/^'//; s/'\$//")
[[ -z "$gql_unused" ]] && ok "every GraphQL query uses all declared variables" || bad "GraphQL declares unused variable(s):$gql_unused"

# ---- live lock --------------------------------------------------------------
banner "Live lock blocks a second goal-manager for the same goal"
write_project "$(goalstate_block active 20 10 2)" "[]"
key="$(printf 'goal|%s' "proj-1" | shasum | cut -c1-12)"
lock="$CLAUDE_RUNS_ROOT/.goal-manager.lock-$key.d"
mkdir -p "$lock"
holder_script="$TMP/goal-manager-lock-holder"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$holder_script"; chmod +x "$holder_script"
"$holder_script" & holder=$!
register_cleanup "kill $holder 2>/dev/null || true"
printf '%s\n' "$holder" > "$lock/pid"
set +e
lock_out="$("$GM" next-planner --goal proj-1 --apply 2>&1)"; lock_rc=$?
set -e
if (( lock_rc != 0 )) && grep -q "another goal-manager is running" <<<"$lock_out"; then
  ok "live goal lock blocks a second writer"
else
  bad "live lock did not block (rc=$lock_rc)"; echo "$lock_out" | sed 's/^/    /'
fi
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
rm -rf "$lock"

# ---- prompt SIGTERM ---------------------------------------------------------
banner "tick --loop exits PROMPTLY on SIGTERM and releases its lock"
ISS="$(jq -nc --argjson a "$(work_issue TEAM-1 't1' unstarted)" --argjson b "$(work_issue TEAM-2 't2' unstarted)" '[$a,$b]')"
write_project "$(goalstate_block active 20 10 2)" "$ISS"
rm -rf "$CLAUDE_RUNS_ROOT"/.goal-manager.lock-*.d 2>/dev/null || true
"$GM" tick --goal proj-1 --apply --loop --interval 20 --backlog-min 1 >/dev/null 2>&1 &
sig_pid=$!
for _ in $(seq 1 30); do ls -d "$CLAUDE_RUNS_ROOT"/.goal-manager.lock-*.d >/dev/null 2>&1 && break || true; sleep 0.1; done
ls -d "$CLAUDE_RUNS_ROOT"/.goal-manager.lock-*.d >/dev/null 2>&1 && ok "loop acquired its lock" || bad "loop never acquired a lock"
kill -TERM "$sig_pid" 2>/dev/null || true
gone=0
for _ in $(seq 1 60); do kill -0 "$sig_pid" 2>/dev/null || { gone=1; break; }; sleep 0.1; done
if [[ "$gone" == "1" ]]; then ok "loop exits within 6s of SIGTERM (not deferred to the 20s interval)"; else bad "loop did not exit promptly"; kill -9 "$sig_pid" 2>/dev/null || true; fi
wait "$sig_pid" 2>/dev/null || true
if ls -d "$CLAUDE_RUNS_ROOT"/.goal-manager.lock-*.d >/dev/null 2>&1; then
  bad "lock not released after SIGTERM"; rm -rf "$CLAUDE_RUNS_ROOT"/.goal-manager.lock-*.d 2>/dev/null || true
else
  ok "lock released after SIGTERM exit"
fi

banner "Summary"
echo "  PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
