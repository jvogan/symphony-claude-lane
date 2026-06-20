#!/usr/bin/env bash
# test_release_manager.sh — isolated release-manager lane tests.
#
# Uses a fake gh binary; no real GitHub or Linear mutation.
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
TMP="$(mktemp -d -t release-manager-test.XXXXXX)"
register_cleanup "rm -rf '$TMP'"
export CLAUDE_RUNS_ROOT="$TMP/runs"
mkdir -p "$CLAUDE_RUNS_ROOT"
# Pin the metrics file into the sandbox even when a test omits --metrics-file, so
# apply tests never write to the operator's real RELEASE_MANAGER_METRICS_FILE.
export RELEASE_MANAGER_METRICS_FILE="$CLAUDE_RUNS_ROOT/release-metrics.jsonl"

REPO="$TMP/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@example.test
git -C "$REPO" config user.name Test
echo "# release manager test" > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm initial
git -C "$REPO" remote add origin https://github.com/example/release-manager-test.git
ok "temporary repo ready"

STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR"
export GH_STUB_LOG="$TMP/gh.log"
export GH_STUB_LIST="$TMP/pr-list.json"
export GH_STUB_LIST_MERGED="$TMP/pr-list-merged.json"
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
        echo "example/release-manager-test"
      else
        echo '{"nameWithOwner":"example/release-manager-test"}'
      fi
      exit 0
    fi
    ;;
  pr)
    case "${2:-}" in
      list)
        if [[ "$*" == *"--state merged"* ]]; then
          cat "${GH_STUB_LIST_MERGED:?}"
        else
          cat "${GH_STUB_LIST:?}"
        fi
        exit 0
        ;;
      edit)
        exit 0
        ;;
      merge)
        exit 0
        ;;
      view)
        echo '{"state":"MERGED","mergedAt":"2026-06-20T00:00:00Z","mergeCommit":{"oid":"abc123"},"url":"https://github.com/example/release-manager-test/pull/42"}'
        exit 0
        ;;
    esac
    ;;
  run)
    if [[ "${2:-}" == "list" ]]; then
      echo '[{"databaseId":1,"headSha":"abc123","status":"completed","conclusion":"success","url":"https://github.com/example/release-manager-test/actions/runs/1","createdAt":"2026-06-20T00:01:00Z"}]'
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

# Fake curl for Linear GraphQL (release-manager calls curl directly, not via an
# override var). Branches on the GraphQL query in --data; the comments query
# reads $FAKE_LINEAR_COMMENTS so each test parameterizes the rebase-marker
# history (or simulates a fetch failure). Dormant for --no-linear tests.
cat > "$STUB_DIR/curl" <<'CURL'
#!/usr/bin/env bash
# No `set -e`: the arg-scan uses `[[ ]] && x`, which returns non-zero on the
# first non-match and would abort the stub under set -e.
data=""; prev=""
for a in "$@"; do if [[ "$prev" == "--data" ]]; then data="$a"; fi; prev="$a"; done
q="$(jq -r '.query' <<<"$data" 2>/dev/null || echo "")"
case "$q" in
  *"issues(filter"*)       printf '%s' '{"data":{"issues":{"nodes":[{"id":"uuid-44","identifier":"DEMO-4244","state":{"name":"In Review"}}]}}}' ;;
  *"comments(first:250)"*) cat "${FAKE_LINEAR_COMMENTS:?}" ;;
  *"teams(filter"*)        printf '%s' '{"data":{"teams":{"nodes":[{"states":{"nodes":[{"id":"state-todo","name":"Todo"}]}}]}}}' ;;
  *"commentCreate"*)       printf '%s' '{"data":{"commentCreate":{"success":true}}}' ;;
  *"issueUpdate"*)         printf '%s' '{"data":{"issueUpdate":{"success":true}}}' ;;
  *)                       printf '%s' '{"data":{}}' ;;
esac
CURL
chmod +x "$STUB_DIR/curl"
export PATH="$STUB_DIR:$PATH"
ok "fake curl (Linear) ready"

cat > "$GH_STUB_LIST" <<'JSON'
[
  {
    "number": 42,
    "title": "DEMO-4242 release manager happy path",
    "url": "https://github.com/example/release-manager-test/pull/42",
    "headRefName": "agent/demo-4242-fix",
    "baseRefName": "main",
    "isDraft": false,
    "mergeStateStatus": "CLEAN",
    "reviewDecision": "APPROVED",
    "labels": [{"name":"release:ready"}],
    "statusCheckRollup": [{"conclusion":"SUCCESS"}]
  },
  {
    "number": 43,
    "title": "DEMO-4243 pending checks",
    "url": "https://github.com/example/release-manager-test/pull/43",
    "headRefName": "agent/demo-4243-pending",
    "baseRefName": "main",
    "isDraft": false,
    "mergeStateStatus": "CLEAN",
    "reviewDecision": "APPROVED",
    "labels": [{"name":"release:ready"}],
    "statusCheckRollup": [{"status":"IN_PROGRESS"}]
  }
]
JSON

# DIRTY (merge-conflict) fixture for conflict-recovery tests. Same PR shape but
# mergeStateStatus=DIRTY so pr_is_ready returns reason 'merge_state=DIRTY'.
GH_STUB_LIST_DIRTY="$TMP/pr-list-dirty.json"
cat > "$GH_STUB_LIST_DIRTY" <<'JSON'
[
  {
    "number": 44,
    "title": "DEMO-4244 dirty merge conflict",
    "url": "https://github.com/example/release-manager-test/pull/44",
    "headRefName": "agent/demo-4244-conflict",
    "baseRefName": "main",
    "isDraft": false,
    "mergeStateStatus": "DIRTY",
    "reviewDecision": "APPROVED",
    "labels": [{"name":"release:ready"}],
    "statusCheckRollup": [{"conclusion":"SUCCESS"}]
  }
]
JSON

# Merged fixture for --reconcile-deploys. Carries ONLY release:queued (lacks
# release:merged), so under --no-linear it counts as lacking deploy evidence.
# mergeCommit.oid matches the run-list stub's headSha so the deploy poll hits.
cat > "$GH_STUB_LIST_MERGED" <<'JSON'
[
  {
    "number": 45,
    "title": "DEMO-4245 merged awaiting deploy",
    "url": "https://github.com/example/release-manager-test/pull/45",
    "headRefName": "agent/demo-4245-deploy",
    "baseRefName": "main",
    "labels": [{"name":"release:queued"}],
    "mergeCommit": {"oid":"abc123"}
  }
]
JSON

banner "Dry-run"
: > "$GH_STUB_LOG"
out="$("$ROOT/bin/release-manager" --repo "$REPO" --github-repo example/release-manager-test --dry-run --no-linear 2>&1)"
echo "$out" | sed 's/^/    /'
grep -q "READY #42" <<<"$out" && ok "dry-run surfaces ready PR" || bad "dry-run did not surface ready PR"
grep -q "SKIP  #43  checks=pending" <<<"$out" && ok "dry-run skips pending checks" || bad "dry-run did not skip pending checks"
if grep -q "pr merge" "$GH_STUB_LOG"; then
  bad "dry-run called gh pr merge"
else
  ok "dry-run did not call gh pr merge"
fi
if grep -q "pr edit" "$GH_STUB_LOG"; then
  bad "dry-run called gh pr edit (label mutation)"
else
  ok "dry-run did not call gh pr edit"
fi
dry_locks="$(find "$CLAUDE_RUNS_ROOT" -maxdepth 1 -name '.release-manager.lock-*.d' -type d 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$dry_locks" == "0" ]]; then
  ok "dry-run acquired no lock (acquire_lock is apply-only)"
else
  bad "dry-run created $dry_locks lock dir(s)"
fi

banner "Apply with stub"
: > "$GH_STUB_LOG"
out="$("$ROOT/bin/release-manager" --repo "$REPO" --github-repo example/release-manager-test --apply --no-linear --strategy squash --max 1 2>&1)"
echo "$out" | sed 's/^/    /'
grep -q "pr edit 42" "$GH_STUB_LOG" && ok "apply transitions labels via gh pr edit" || bad "apply did not edit PR labels"
grep -q "pr merge 42" "$GH_STUB_LOG" && grep -q -- "--squash" "$GH_STUB_LOG" && ok "apply calls gh pr merge --squash" || bad "apply merge command shape wrong"
if grep -q "release:merged" "$GH_STUB_LOG"; then
  bad "no-wait apply promoted PR to release:merged without merge evidence"
else
  ok "no-wait apply leaves PR queued until merge evidence exists"
fi

banner "Apply with merge + deploy wait"
: > "$GH_STUB_LOG"
out="$("$ROOT/bin/release-manager" --repo "$REPO" --github-repo example/release-manager-test --apply --no-linear --strategy queue --max 1 --wait-merge --wait-deploy-workflow deploy.yml --wait-seconds 2 --interval 1 2>&1)"
echo "$out" | sed 's/^/    /'
grep -q "pr view 42" "$GH_STUB_LOG" && ok "wait-merge polls PR view" || bad "wait-merge did not poll PR view"
grep -q "run list" "$GH_STUB_LOG" && ok "deploy wait polls workflow runs" || bad "deploy wait did not poll workflow runs"

banner "Metrics JSONL emitted on apply"
: > "$GH_STUB_LOG"
METRICS_APPLY="$TMP/metrics-apply.jsonl"
rm -f "$METRICS_APPLY"
out="$("$ROOT/bin/release-manager" --repo "$REPO" --github-repo example/release-manager-test --apply --no-linear --strategy queue --max 1 --wait-merge --wait-deploy-workflow deploy.yml --wait-seconds 2 --interval 1 --metrics-file "$METRICS_APPLY" 2>&1)"
echo "$out" | sed 's/^/    /'
if [[ -f "$METRICS_APPLY" ]]; then
  ok "apply writes metrics file"
else
  bad "apply did not write metrics file"
fi
if [[ -f "$METRICS_APPLY" ]] && jq -e '.number and .conclusion' "$METRICS_APPLY" >/dev/null 2>&1; then
  ok "metrics line has number and conclusion"
else
  bad "metrics line missing number/conclusion"
  [[ -f "$METRICS_APPLY" ]] && sed 's/^/    /' "$METRICS_APPLY"
fi
if [[ -f "$METRICS_APPLY" ]] && jq -e 'select(.number == 42 and .conclusion == "deployed")' "$METRICS_APPLY" >/dev/null 2>&1; then
  ok "metrics conclusion=deployed for merged+deployed PR"
else
  bad "metrics did not record deployed conclusion for PR 42"
fi

banner "Metrics not written under dry-run"
METRICS_DRY="$TMP/metrics-dry.jsonl"
rm -f "$METRICS_DRY"
out="$("$ROOT/bin/release-manager" --repo "$REPO" --github-repo example/release-manager-test --dry-run --no-linear --metrics-file "$METRICS_DRY" 2>&1)"
echo "$out" | sed 's/^/    /'
if [[ -f "$METRICS_DRY" ]]; then
  bad "dry-run wrote a metrics file"
  sed 's/^/    /' "$METRICS_DRY"
else
  ok "dry-run writes no metrics file"
fi

banner "Conflict: --on-conflict fail (default) skips DIRTY PR"
: > "$GH_STUB_LOG"
export GH_STUB_LIST="$GH_STUB_LIST_DIRTY"
out="$("$ROOT/bin/release-manager" --repo "$REPO" --github-repo example/release-manager-test --apply --no-linear --strategy squash --max 1 2>&1)"
echo "$out" | sed 's/^/    /'
grep -q "SKIP  #44  merge_state=DIRTY" <<<"$out" && ok "default on-conflict=fail skips DIRTY PR" || bad "default on-conflict did not skip DIRTY PR"
if grep -q "pr merge 44" "$GH_STUB_LOG"; then
  bad "on-conflict=fail merged a DIRTY PR"
else
  ok "on-conflict=fail did not merge DIRTY PR"
fi
if grep -q "release:rebase" "$GH_STUB_LOG"; then
  bad "on-conflict=fail added release:rebase label"
else
  ok "on-conflict=fail did not add release:rebase label"
fi

banner "Conflict: --on-conflict redispatch fail-closed without Linear"
: > "$GH_STUB_LOG"
out="$("$ROOT/bin/release-manager" --repo "$REPO" --github-repo example/release-manager-test --apply --no-linear --on-conflict redispatch --strategy squash --max 1 2>&1)"
echo "$out" | sed 's/^/    /'
grep -q "SKIP  #44  merge_state=DIRTY" <<<"$out" && ok "redispatch fail-closed: DIRTY PR skipped when --no-linear" || bad "redispatch did not fail-closed to SKIP without Linear"
grep -q "Linear unusable" <<<"$out" && ok "redispatch logs fail-closed reason" || bad "redispatch did not log fail-closed reason"
if grep -q "release:rebase" "$GH_STUB_LOG"; then
  bad "redispatch added release:rebase label without Linear"
else
  ok "redispatch did not add release:rebase label without Linear"
fi
if grep -q "pr merge 44" "$GH_STUB_LOG"; then
  bad "redispatch merged a DIRTY PR"
else
  ok "redispatch did not merge DIRTY PR"
fi

banner "Conflict: redispatch happy-path (0 prior attempts) sends rebase signal"
: > "$GH_STUB_LOG"
FAKE_COMMENTS_EMPTY="$TMP/comments-empty.json"
printf '%s' '{"data":{"issue":{"comments":{"nodes":[]}}}}' > "$FAKE_COMMENTS_EMPTY"
METRICS_RD="$TMP/metrics-redispatch.jsonl"; rm -f "$METRICS_RD"
out="$(LINEAR_API_KEY=stub FAKE_LINEAR_COMMENTS="$FAKE_COMMENTS_EMPTY" "$ROOT/bin/release-manager" --repo "$REPO" --github-repo example/release-manager-test --apply --on-conflict redispatch --strategy squash --max 1 --metrics-file "$METRICS_RD" 2>&1)"
echo "$out" | sed 's/^/    /'
grep -q "CONFLICT #44" <<<"$out" && ok "redispatch surfaces CONFLICT" || bad "redispatch did not surface CONFLICT"
if grep -q "pr edit 44" "$GH_STUB_LOG" && grep -q -- "--add-label release:rebase" "$GH_STUB_LOG" && grep -q -- "--remove-label release:ready" "$GH_STUB_LOG"; then
  ok "redispatch adds release:rebase and removes release:ready"
else
  bad "redispatch label transition wrong"
fi
if grep -q "pr merge 44" "$GH_STUB_LOG"; then bad "redispatch merged a DIRTY PR (happy path)"; else ok "redispatch did not merge DIRTY PR (happy path)"; fi
if [[ -f "$METRICS_RD" ]] && jq -e 'select(.number==44 and .conclusion=="rebase_requested")' "$METRICS_RD" >/dev/null 2>&1; then
  ok "redispatch metrics conclusion=rebase_requested"
else
  bad "redispatch metrics missing rebase_requested"; [[ -f "$METRICS_RD" ]] && sed 's/^/    /' "$METRICS_RD"
fi

banner "Conflict: redispatch exhausts retry budget -> release:failed"
: > "$GH_STUB_LOG"
FAKE_COMMENTS_EXHAUSTED="$TMP/comments-exhausted.json"
printf '%s' '{"data":{"issue":{"comments":{"nodes":[{"body":"<!-- release-manager-rebase -->\nmanaged_by: release-manager"},{"body":"<!-- release-manager-rebase -->\nmanaged_by: release-manager"}]}}}}' > "$FAKE_COMMENTS_EXHAUSTED"
METRICS_EX="$TMP/metrics-exhausted.jsonl"; rm -f "$METRICS_EX"
out="$(LINEAR_API_KEY=stub FAKE_LINEAR_COMMENTS="$FAKE_COMMENTS_EXHAUSTED" "$ROOT/bin/release-manager" --repo "$REPO" --github-repo example/release-manager-test --apply --on-conflict redispatch --strategy squash --max 1 --metrics-file "$METRICS_EX" 2>&1)"
echo "$out" | sed 's/^/    /'
if grep -q "pr edit 44" "$GH_STUB_LOG" && grep -q -- "--add-label release:failed" "$GH_STUB_LOG"; then
  ok "exhausted redispatch fails the PR (release:failed)"
else
  bad "exhausted redispatch did not fail the PR"
fi
if grep -q -- "--add-label release:rebase" "$GH_STUB_LOG"; then
  bad "exhausted redispatch still added release:rebase"
else
  ok "exhausted redispatch did not re-add release:rebase"
fi
if [[ -f "$METRICS_EX" ]] && jq -e 'select(.number==44 and .conclusion=="rebase_exhausted")' "$METRICS_EX" >/dev/null 2>&1; then
  ok "exhausted metrics conclusion=rebase_exhausted"
else
  bad "exhausted metrics missing rebase_exhausted"; [[ -f "$METRICS_EX" ]] && sed 's/^/    /' "$METRICS_EX"
fi

banner "Conflict: redispatch fail-closed when Linear history is unreadable (fail-OPEN regression)"
: > "$GH_STUB_LOG"
FAKE_COMMENTS_ERR="$TMP/comments-error.json"
# HTTP-200-with-errors GraphQL body (no .data): linear_graphql must treat as failure.
printf '%s' '{"errors":[{"message":"rate limited"}]}' > "$FAKE_COMMENTS_ERR"
out="$(LINEAR_API_KEY=stub FAKE_LINEAR_COMMENTS="$FAKE_COMMENTS_ERR" "$ROOT/bin/release-manager" --repo "$REPO" --github-repo example/release-manager-test --apply --on-conflict redispatch --strategy squash --max 1 2>&1)"
echo "$out" | sed 's/^/    /'
grep -q "rebase history unavailable" <<<"$out" && ok "redispatch fail-closed when comment history unreadable" || bad "redispatch did not fail-closed on unreadable history"
if grep -q -- "--add-label release:rebase" "$GH_STUB_LOG"; then
  bad "redispatch sent rebase signal despite unknowable retry count (fail-OPEN regression)"
else
  ok "redispatch sent NO rebase signal when retry count unknowable"
fi
if grep -q -- "--add-label release:failed" "$GH_STUB_LOG"; then
  bad "redispatch failed the PR on a transient Linear error (should skip)"
else
  ok "redispatch left PR untouched on transient Linear error"
fi
export GH_STUB_LIST="$TMP/pr-list.json"

banner "Reconcile deploys requires --wait-deploy-workflow"
set +e
recon_err="$("$ROOT/bin/release-manager" --repo "$REPO" --github-repo example/release-manager-test --apply --no-linear --reconcile-deploys 2>&1)"
recon_rc=$?
set -e
if (( recon_rc != 0 )) && grep -q "requires --wait-deploy-workflow" <<<"$recon_err"; then
  ok "reconcile without --wait-deploy-workflow dies"
else
  bad "reconcile missing --wait-deploy-workflow not rejected (rc=$recon_rc)"
fi

banner "Reconcile merged PR lacking deploy evidence"
: > "$GH_STUB_LOG"
METRICS_RECON="$TMP/metrics-recon.jsonl"
rm -f "$METRICS_RECON"
out="$("$ROOT/bin/release-manager" --repo "$REPO" --github-repo example/release-manager-test --apply --no-linear --reconcile-deploys --wait-deploy-workflow deploy.yml --wait-seconds 2 --interval 1 --max 1 --metrics-file "$METRICS_RECON" 2>&1)"
echo "$out" | sed 's/^/    /'
grep -q -- "--state merged" "$GH_STUB_LOG" && ok "reconcile lists merged PRs" || bad "reconcile did not list merged PRs"
grep -q "RECONCILE #45" <<<"$out" && ok "reconcile surfaces merged PR lacking deploy" || bad "reconcile did not surface candidate PR"
grep -q "run list" "$GH_STUB_LOG" && ok "reconcile polls workflow runs" || bad "reconcile did not poll workflow runs"
if grep -q "pr edit 45" "$GH_STUB_LOG" && grep -q -- "--add-label release:merged" "$GH_STUB_LOG" && grep -q -- "--remove-label release:queued" "$GH_STUB_LOG"; then
  ok "reconcile transitions queued->merged on deploy success"
else
  bad "reconcile label transition wrong"
fi
if [[ -f "$METRICS_RECON" ]] && jq -e 'select(.number == 45 and .conclusion == "deployed")' "$METRICS_RECON" >/dev/null 2>&1; then
  ok "reconcile emits metrics with deployed conclusion"
else
  bad "reconcile did not emit deployed metrics"
  [[ -f "$METRICS_RECON" ]] && sed 's/^/    /' "$METRICS_RECON"
fi

banner "Live lock blocks second release manager"
key="$(printf '%s|%s|%s' "$REPO" "main" "release:ready" | shasum | cut -c1-12)"
lock="$CLAUDE_RUNS_ROOT/.release-manager.lock-$key.d"
mkdir -p "$lock"
sleep 30 &
holder=$!
register_cleanup "kill $holder 2>/dev/null || true"
printf '%s\n' "$holder" > "$lock/pid"
set +e
lock_out="$("$ROOT/bin/release-manager" --repo "$REPO" --github-repo example/release-manager-test --apply --no-linear --strategy squash --max 1 2>&1)"
lock_rc=$?
set -e
if (( lock_rc != 0 )) && grep -q "another release-manager is running" <<<"$lock_out"; then
  ok "live release-manager lock blocks apply"
else
  bad "live lock did not block apply (rc=$lock_rc)"
  echo "$lock_out" | sed 's/^/    /'
fi
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

banner "Summary"
echo "  PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
