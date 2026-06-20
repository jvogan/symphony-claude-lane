#!/usr/bin/env bash
# test_release_manager.sh — isolated release-manager lane tests.
#
# Uses a fake gh binary; no real GitHub or Linear mutation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
        cat "${GH_STUB_LIST:?}"
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
