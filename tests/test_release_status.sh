#!/usr/bin/env bash
# test_release_status.sh — isolated release-status (read-only snapshot) tests.
#
# Uses a fake gh binary; asserts the tool surfaces lane counts + a time-to-main
# summary, and makes NO mutating gh call (no pr merge / pr edit / api -X).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Hermetic: prevent an operator-exported AUTONOMY_ROOT from making env.sh source
# an upstream file inside the test process.
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
TMP="$(mktemp -d -t release-status-test.XXXXXX)"
register_cleanup "rm -rf '$TMP'"
export CLAUDE_RUNS_ROOT="$TMP/runs"
mkdir -p "$CLAUDE_RUNS_ROOT"
# Pin the metrics file under the tmp runs root so the test is hermetic even if
# the operator's environment exports RELEASE_MANAGER_METRICS_FILE elsewhere.
export RELEASE_MANAGER_METRICS_FILE="$CLAUDE_RUNS_ROOT/release-metrics.jsonl"

REPO="$TMP/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@example.test
git -C "$REPO" config user.name Test
echo "# release status test" > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm initial
git -C "$REPO" remote add origin https://github.com/example/release-status-test.git
ok "temporary repo ready"

# createdAt fixtures relative to now so age assertions are deterministic.
NOW="$(date +%s)"
iso() { # epoch -> ISO8601 Zulu, portable across BSD/GNU date
  if date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
  fi
}
READY_OLD="$(iso $(( NOW - 2 * 3600 )))"   # 2h ago
READY_NEW="$(iso $(( NOW - 30 * 60 )))"    # 30m ago
QUEUED_OLD="$(iso $(( NOW - 26 * 3600 )))" # ~1d ago

STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR"
export GH_STUB_LOG="$TMP/gh.log"
export GH_FIX_READY="$TMP/ready.json"
export GH_FIX_QUEUED="$TMP/queued.json"
export GH_FIX_MERGED="$TMP/merged.json"
export GH_FIX_FAILED="$TMP/failed.json"

cat > "$GH_FIX_READY" <<JSON
[
  {"number":42,"title":"DEMO-4242 ready old","url":"https://github.com/example/release-status-test/pull/42","createdAt":"$READY_OLD"},
  {"number":44,"title":"DEMO-4244 ready new","url":"https://github.com/example/release-status-test/pull/44","createdAt":"$READY_NEW"}
]
JSON
cat > "$GH_FIX_QUEUED" <<JSON
[
  {"number":50,"title":"DEMO-5050 queued","url":"https://github.com/example/release-status-test/pull/50","createdAt":"$QUEUED_OLD"}
]
JSON
echo '[]' > "$GH_FIX_MERGED"
echo '[]' > "$GH_FIX_FAILED"

cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
case "${1:-}" in
  auth)
    exit 0
    ;;
  repo)
    if [[ "${2:-}" == "view" ]]; then
      if [[ "$*" == *"-q .nameWithOwner"* ]]; then
        echo "example/release-status-test"
      else
        echo '{"nameWithOwner":"example/release-status-test"}'
      fi
      exit 0
    fi
    ;;
  pr)
    if [[ "${2:-}" == "list" ]]; then
      case "$*" in
        *"--label release:ready"*)  cat "${GH_FIX_READY:?}" ;;
        *"--label release:queued"*) cat "${GH_FIX_QUEUED:?}" ;;
        *"--label release:merged"*) cat "${GH_FIX_MERGED:?}" ;;
        *"--label release:failed"*) cat "${GH_FIX_FAILED:?}" ;;
        *) echo '[]' ;;
      esac
      exit 0
    fi
    ;;
esac
echo "unexpected gh args: $*" >&2
exit 7
STUB
chmod +x "$STUB_DIR/gh"
export RELEASE_MANAGER_GH_BIN="$STUB_DIR/gh"
ok "fake gh ready"

# Hand-written metrics fixture: 3 merged-class records with non-null
# time_to_main_s (100/300/500) + 1 queued record with null.
METRICS="$CLAUDE_RUNS_ROOT/release-metrics.jsonl"
cat > "$METRICS" <<'JSONL'
{"ts":1781800000,"repo":"example/release-status-test","number":42,"conclusion":"merged","time_to_main_s":100}
{"ts":1781800100,"repo":"example/release-status-test","number":43,"conclusion":"queued","time_to_main_s":null}
{"ts":1781800200,"repo":"example/release-status-test","number":44,"conclusion":"merged","time_to_main_s":500}
{"ts":1781800300,"repo":"example/release-status-test","number":45,"conclusion":"deployed","time_to_main_s":300}
JSONL
ok "metrics fixture ready"

banner "Snapshot with metrics"
: > "$GH_STUB_LOG"
out="$("$ROOT/bin/release-status" --repo "$REPO" --github-repo example/release-status-test 2>&1)"
echo "$out" | sed 's/^/    /'

grep -Eq '^  ready    2  \(oldest 2h\)' <<<"$out" \
  && ok "ready count + oldest age surface" \
  || bad "ready section wrong"
grep -Eq '^  queued   1  \(oldest 1d\)' <<<"$out" \
  && ok "queued count + oldest age surface" \
  || bad "queued section wrong"
grep -Eq '^  merged   ' <<<"$out" \
  && ok "merged section present" \
  || bad "merged section missing"
grep -Eq '^  failed   0' <<<"$out" \
  && ok "failed count surfaces (0)" \
  || bad "failed section wrong"

# 4 merged-class records (merged + deployed). p50 of [100,300,500] = 300,
# p90 = 500. n is the non-null sample size (3).
grep -Eq '^  time-to-main: n=3 p50=300 p90=500' <<<"$out" \
  && ok "time-to-main p50/p90 line appears" \
  || bad "time-to-main line wrong"

banner "Read-only: no mutating gh calls"
if grep -Eq 'pr merge|pr edit|pr close|api .*-X' "$GH_STUB_LOG"; then
  bad "release-status issued a mutating gh call"
  grep -E 'pr merge|pr edit|pr close|api .*-X' "$GH_STUB_LOG" | sed 's/^/    /'
else
  ok "release-status issued no mutating gh call"
fi
# Positively confirm it only used read-only `pr list` (+ never `repo view`,
# since --github-repo was provided).
if grep -q 'pr list' "$GH_STUB_LOG"; then
  ok "release-status used read-only pr list"
else
  bad "release-status never listed PRs"
fi

banner "Degrades gracefully with no metrics"
: > "$GH_STUB_LOG"
EMPTY_METRICS="$TMP/empty-metrics.jsonl"
out2="$("$ROOT/bin/release-status" --repo "$REPO" --github-repo example/release-status-test --metrics-file "$EMPTY_METRICS" 2>&1)"
echo "$out2" | sed 's/^/    /'
grep -q "no metrics yet" <<<"$out2" \
  && ok "absent metrics file prints 'no metrics yet'" \
  || bad "absent metrics file did not degrade gracefully"
grep -Eq '^  ready    2' <<<"$out2" \
  && ok "lane counts still surface without metrics" \
  || bad "lane counts missing when metrics absent"

banner "Help short-circuits before required-arg checks"
set +e
help_out="$("$ROOT/bin/release-status" --help 2>&1)"
help_rc=$?
set -e
if (( help_rc == 0 )) && grep -q "Read-only snapshot" <<<"$help_out"; then
  ok "--help exits 0 with usage"
else
  bad "--help did not short-circuit cleanly (rc=$help_rc)"
fi

banner "Summary"
echo "  PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
