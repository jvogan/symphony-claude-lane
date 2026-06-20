#!/usr/bin/env bash
# test_launcher_recovery.sh — rebase-recovery rendering tests for the reference
# launcher (skills/symphony-claude-lane/assets/claude-worker.reference.sh).
#
# Hermetic: NEVER touches real claude/tmux/gh/curl/Linear or the network. The
# launcher fetches Linear via `curl` directly and only does `command -v` on
# claude/tmux/jq/python3/curl/git, so we stub `curl` (Linear) and drop fake
# `claude`/`tmux` on PATH (never executed by the dry-run path). We exercise the
# launcher's REAL dry-run / prompt-render path (`--dry-run`) and capture the
# rendered prompt by intercepting the bare `grep` the dry-run runs against the
# rendered temp file (it greps the file for <issue_body> boundaries BEFORE
# deleting it), so what we assert on is the launcher's own render_prompt_file
# output — not a re-implementation of the substitution.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Hermetic: prevent an operator-exported AUTONOMY_ROOT from making env.sh source
# an upstream file inside the test process.
unset AUTONOMY_ROOT _SYMPHONY_CLAUDE_LANE_ENV_LOADED
# shellcheck disable=SC1091
source "$ROOT/env.sh"

LAUNCHER="$ROOT/skills/symphony-claude-lane/assets/claude-worker.reference.sh"

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
[[ -f "$LAUNCHER" ]] || { bad "launcher not found at $LAUNCHER"; exit 1; }

TMP="$(mktemp -d -t launcher-recovery-test.XXXXXX)"
register_cleanup "rm -rf '$TMP'"

# Point all launcher-derived roots into the sandbox so nothing touches the
# operator's real workspaces/runs.
export CLAUDE_WORKSPACES_ROOT="$TMP/workspaces"
export CLAUDE_RUNS_ROOT="$TMP/runs"
mkdir -p "$CLAUDE_WORKSPACES_ROOT" "$CLAUDE_RUNS_ROOT"

# A tmp git repo with an origin remote (the launcher requires <repo>/.git and,
# in real rebase-recovery mode, fetches origin/<branch> — but the dry-run path
# exits before any git network call, so a bare local repo + remote URL suffice).
REPO="$TMP/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@example.test
git -C "$REPO" config user.name Test
echo "# launcher recovery test" > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm initial
git -C "$REPO" remote add origin https://github.com/example/launcher-recovery-test.git
ok "temporary repo ready"

# Capture the REAL grep path BEFORE we prepend our stub dir, so the fake grep can
# delegate to it for the launcher's own boundary validation.
REAL_GREP="$(command -v grep)"

STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR"

# Fake claude / tmux: the launcher only does `command -v` on these in its
# preflight; the --dry-run path exits long before it would ever EXECUTE them.
# They exist purely to satisfy the preflight loop.
for binname in claude tmux; do
  cat > "$STUB_DIR/$binname" <<'STUB'
#!/usr/bin/env bash
echo "FATAL: stub $0 should never be executed by the dry-run path: $*" >&2
exit 99
STUB
  chmod +x "$STUB_DIR/$binname"
done

# Fake curl for the launcher's Linear GraphQL fetch. The launcher passes the
# query via `-d <json>`; we return a single non-terminal issue carrying the
# default routing label (lane:claude) so the routing guard passes without
# --allow-unrouted.
#
# NOTE: we deliberately put a SECOND label AFTER lane:claude. The launcher's
# csv_contains has a real bug (see productionBugs) where the LAST element of the
# label CSV never matches — `printf '%s' | tr ',' '\n'` emits no trailing
# newline and bash `read` returns non-zero on the final unterminated line, so
# the loop body is skipped for the last label. Placing lane:claude NOT last lets
# the real routing guard pass via its working path, keeping the guard active.
export FAKE_ISSUE_TITLE="Recover the conflicted PR"
cat > "$STUB_DIR/curl" <<'CURL'
#!/usr/bin/env bash
# No `set -e`: the arg scan uses `[[ ]]` tests that return non-zero on no-match.
data=""; prev=""
for a in "$@"; do if [[ "$prev" == "-d" || "$prev" == "--data" ]]; then data="$a"; fi; prev="$a"; done
q="$(jq -r '.query' <<<"$data" 2>/dev/null || echo "")"
case "$q" in
  *"issues(filter"*)
    jq -nc --arg t "${FAKE_ISSUE_TITLE:-Recover the conflicted PR}" \
      '{data:{issues:{nodes:[{id:"uuid-1",identifier:"DEMO-77",title:$t,description:"Body line.",state:{name:"In Progress"},project:{name:"Demo"},assignee:{id:"",email:"",name:""},labels:{nodes:[{name:"lane:claude"},{name:"area:ui"}]}}]}}}'
    ;;
  *)
    printf '%s' '{"data":{}}'
    ;;
esac
CURL
chmod +x "$STUB_DIR/curl"

# Fake grep: the launcher's dry-run runs `grep -q <pat> <rendered-tmp-file>` to
# validate the <issue_body> boundary, BEFORE deleting the temp file. We snapshot
# that file (the last argument) into CAPTURE_PROMPT so we can assert on the
# launcher's REAL rendered output, then delegate to the real grep so the
# launcher's own validation behaves identically.
export CAPTURE_PROMPT="$TMP/captured-prompt.md"
cat > "$STUB_DIR/grep" <<CAPGREP
#!/usr/bin/env bash
set -euo pipefail
# Last positional arg is the file the launcher is validating.
_last=""
for _a in "\$@"; do _last="\$_a"; done
if [[ -f "\$_last" ]]; then
  cp -f "\$_last" "${CAPTURE_PROMPT}" 2>/dev/null || true
fi
exec "${REAL_GREP}" "\$@"
CAPGREP
chmod +x "$STUB_DIR/grep"

# Fake gh for the --no-linear GitHub-only path. Handles `gh auth status` (the
# launcher probes it outside --dry-run) and `gh issue view N --json …` (the task
# source for --github-issue). Returns an OPEN issue carrying lane:claude (NOT
# last in the array — same csv_contains trailing-element caveat as the curl stub)
# so the label routing guard passes. Never touches the network.
cat > "$STUB_DIR/gh" <<'GH'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then exit 0; fi
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
  jq -nc '{title:"Fix the GH issue nav",body:"Issue body from GitHub. Make it responsive.",state:"OPEN",labels:[{name:"lane:claude"},{name:"area:ui"}]}'
  exit 0
fi
echo "fake gh: unhandled invocation: $*" >&2
exit 1
GH
chmod +x "$STUB_DIR/gh"

export PATH="$STUB_DIR:$PATH"
# LINEAR_API_KEY must be set for the DEFAULT-mode preflight; value is irrelevant
# (curl is stubbed). The --no-linear cases below deliberately UNSET it to prove
# the GitHub-only path needs no Linear key.
export LINEAR_API_KEY=stub-key
ok "fake curl + gh + claude/tmux + grep-capture ready"

# Helper: run the launcher's dry-run and reset the capture file first.
run_dry() {
  : > "$CAPTURE_PROMPT"
  "$LAUNCHER" "$@"
}

# ---------------------------------------------------------------------------
banner "1. Rebase-recovery render (--rebase-recovery)"
: > "$CAPTURE_PROMPT"
PR_URL_VAL="https://github.com/example/launcher-recovery-test/pull/77"
CONFLICT_VAL="src/app.tsx both modified at hunk 3"
dry_out="$(run_dry DEMO-77 "$REPO" --dry-run --rebase-recovery \
  --pr-url "$PR_URL_VAL" --conflict-detail "$CONFLICT_VAL" 2>&1)" || {
    bad "rebase-recovery dry-run exited non-zero"; echo "$dry_out" | sed 's/^/    /'; }
echo "$dry_out" | sed 's/^/    /'

if [[ -s "$CAPTURE_PROMPT" ]]; then
  ok "captured rendered prompt from launcher dry-run"
  rendered="$(cat "$CAPTURE_PROMPT")"

  if ! grep -q '{{' "$CAPTURE_PROMPT"; then
    ok "no leftover {{ placeholders in rebase-recovery render"
  else
    bad "rebase-recovery render left {{ placeholders"
    grep -n '{{' "$CAPTURE_PROMPT" | sed 's/^/    /'
  fi

  grep -q 'Rebase recovery task' "$CAPTURE_PROMPT" \
    && ok "rebase block present (Rebase recovery heading)" \
    || bad "rebase block missing the 'Rebase recovery task' heading"

  # force-with-lease is the load-bearing safety instruction (step 4 of the
  # block). NOTE: this string ALSO appears once OUTSIDE the block (the
  # completion protocol's rebase follow-up note), so it is only a valid
  # PRESENCE assertion here, not an absence one — see the fresh-render banner.
  grep -q 'force-with-lease' "$CAPTURE_PROMPT" \
    && ok "rebase block present (force-with-lease instruction)" \
    || bad "rebase block missing force-with-lease instruction"

  # A phrase that lives ONLY inside the rebase block body.
  grep -q 'rebase the existing branch onto the latest base' "$CAPTURE_PROMPT" \
    && ok "rebase block body present (block-exclusive phrase)" \
    || bad "rebase block body missing its block-exclusive phrase"

  grep -Fq "$PR_URL_VAL" "$CAPTURE_PROMPT" \
    && ok "PR_URL value rendered into prompt" \
    || bad "PR_URL value not found in rendered prompt"

  grep -Fq "$CONFLICT_VAL" "$CAPTURE_PROMPT" \
    && ok "CONFLICT_DETAIL value rendered into prompt" \
    || bad "CONFLICT_DETAIL value not found in rendered prompt"

  # TASK_MODE flips to rebase-recovery and is rendered into the block.
  grep -q 'Task mode: `rebase-recovery`' "$CAPTURE_PROMPT" \
    && ok "TASK_MODE rendered as rebase-recovery" \
    || bad "TASK_MODE not rendered as rebase-recovery"

  if ! grep -q 'BEGIN rebase-recovery' "$CAPTURE_PROMPT" \
     && ! grep -q 'END rebase-recovery' "$CAPTURE_PROMPT"; then
    ok "BEGIN/END rebase-recovery delimiter comments stripped"
  else
    bad "BEGIN/END rebase-recovery delimiter comments remain in render"
  fi
else
  bad "did not capture a rendered prompt (capture file empty)"
fi

# The dry-run plan itself should reflect rebase-recovery (reuse branch, delete
# sentinel) rather than fresh worktree creation.
grep -q "Task mode:              rebase-recovery" <<<"$dry_out" \
  && ok "dry-run plan reports task mode rebase-recovery" \
  || bad "dry-run plan did not report rebase-recovery task mode"
grep -q "Would reuse branch:" <<<"$dry_out" \
  && ok "dry-run plan reuses branch (rebase-recovery)" \
  || bad "dry-run plan did not reuse branch"
grep -q "Would delete sentinel:" <<<"$dry_out" \
  && ok "dry-run plan deletes stale sentinel (rebase-recovery)" \
  || bad "dry-run plan did not mention sentinel deletion"

# ---------------------------------------------------------------------------
banner "2. Fresh render (no --rebase-recovery)"
: > "$CAPTURE_PROMPT"
fresh_out="$(run_dry DEMO-77 "$REPO" --dry-run 2>&1)" || {
  bad "fresh dry-run exited non-zero"; echo "$fresh_out" | sed 's/^/    /'; }
echo "$fresh_out" | sed 's/^/    /'

if [[ -s "$CAPTURE_PROMPT" ]]; then
  if ! grep -q '{{' "$CAPTURE_PROMPT"; then
    ok "no leftover {{ placeholders in fresh render"
  else
    bad "fresh render left {{ placeholders"
    grep -n '{{' "$CAPTURE_PROMPT" | sed 's/^/    /'
  fi

  if ! grep -q 'Rebase recovery task' "$CAPTURE_PROMPT"; then
    ok "rebase block ABSENT in fresh render (no Rebase recovery heading)"
  else
    bad "fresh render still contains the Rebase recovery heading"
  fi

  # The block body's distinctive instruction must also be gone. We assert on a
  # phrase that lives ONLY inside the block — NOT 'force-with-lease', which also
  # appears once in the completion-protocol section OUTSIDE the block and is
  # therefore expected to survive in fresh mode (see template line ~204).
  if ! grep -q 'rebase the existing branch onto the latest base' "$CAPTURE_PROMPT"; then
    ok "fresh render dropped the block-exclusive rebase body phrase"
  else
    bad "fresh render still contains the block-exclusive rebase body phrase"
  fi

  # Delimiters must not survive in fresh mode either.
  if ! grep -q 'rebase-recovery -->' "$CAPTURE_PROMPT"; then
    ok "no rebase-recovery delimiter comments in fresh render"
  else
    bad "fresh render left rebase-recovery delimiter comments"
  fi
else
  bad "did not capture a fresh rendered prompt (capture file empty)"
fi

grep -q "Task mode:              fresh" <<<"$fresh_out" \
  && ok "dry-run plan reports task mode fresh" \
  || bad "dry-run plan did not report fresh task mode"
grep -q "Would create worktree:" <<<"$fresh_out" \
  && ok "fresh dry-run plan creates a worktree" \
  || bad "fresh dry-run plan did not create a worktree"

# ---------------------------------------------------------------------------
banner "3. Injection guard (newline + single-quote rejection)"
# 3a. A newline in --conflict-detail must make the launcher DIE (the newline
# fix: free text cannot inject extra instruction lines into the prompt).
set +e
inj_out="$(run_dry DEMO-77 "$REPO" --dry-run --rebase-recovery \
  --pr-url "$PR_URL_VAL" --conflict-detail $'line1\nINJECT' 2>&1)"
inj_rc=$?
set -e
if (( inj_rc != 0 )) && grep -qi "newline" <<<"$inj_out"; then
  ok "newline in --conflict-detail rejected with a newline message"
else
  bad "newline in --conflict-detail not rejected (rc=$inj_rc)"
  echo "$inj_out" | sed 's/^/    /'
fi
# Defensive: nothing leaked into a rendered prompt for the rejected invocation.
if grep -q 'INJECT' "$CAPTURE_PROMPT" 2>/dev/null; then
  bad "injected line reached the rendered prompt despite rejection"
else
  ok "injected newline content never reached a rendered prompt"
fi

# 3b. A single-quote in --pr-url must be rejected (meta.env / argv safety).
set +e
sq_out="$(run_dry DEMO-77 "$REPO" --dry-run --rebase-recovery \
  --pr-url "https://x/'pull/1" --conflict-detail "ok" 2>&1)"
sq_rc=$?
set -e
if (( sq_rc != 0 )) && grep -qi "single quote" <<<"$sq_out"; then
  ok "single quote in --pr-url rejected"
else
  bad "single quote in --pr-url not rejected (rc=$sq_rc)"
  echo "$sq_out" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
banner "4. Sentinel/worktree guards (NOT reachable in dry-run) — documented SKIP"
# The launcher's --dry-run block (renders prompt -> validates boundary -> prints
# plan -> exit 0) returns BEFORE the stale-sentinel guard and before any
# `git worktree add`. Exercising "fresh dies on a pre-existing sentinel while
# --rebase-recovery does not" therefore requires the NON-dry-run path, which
# spawns tmux + claude and runs real `git fetch origin <branch>` / `git worktree
# add` — impossible to do hermetically here. We assert the structural guarantee
# we CAN verify hermetically: a pre-existing sentinel does NOT perturb the
# dry-run for either mode (the guard is genuinely downstream of the render),
# and the dry-run plan still names the sentinel path it WOULD act on.
mkdir -p "$CLAUDE_RUNS_ROOT/DEMO-77"
SENT="$CLAUDE_RUNS_ROOT/DEMO-77/.symphony-done"
printf '%s' '{"status":"completed"}' > "$SENT"
register_cleanup "rm -f '$SENT'"

set +e
fresh_sent_out="$(run_dry DEMO-77 "$REPO" --dry-run 2>&1)"
fresh_sent_rc=$?
set -e
if (( fresh_sent_rc == 0 )) && ! grep -qi "stale sentinel" <<<"$fresh_sent_out"; then
  ok "fresh dry-run does NOT trip the stale-sentinel guard (guard is post-render)"
else
  bad "fresh dry-run unexpectedly hit the stale-sentinel guard (rc=$fresh_sent_rc)"
  echo "$fresh_sent_out" | sed 's/^/    /'
fi
# Sentinel must be untouched by dry-run (no side effects).
[[ -f "$SENT" ]] \
  && ok "dry-run left the pre-existing sentinel in place (no side effects)" \
  || bad "dry-run deleted the pre-existing sentinel"

set +e
rr_sent_out="$(run_dry DEMO-77 "$REPO" --dry-run --rebase-recovery \
  --pr-url "$PR_URL_VAL" --conflict-detail "ok" 2>&1)"
rr_sent_rc=$?
set -e
if (( rr_sent_rc == 0 )); then
  ok "rebase-recovery dry-run also exits 0 with a pre-existing sentinel"
else
  bad "rebase-recovery dry-run failed with a pre-existing sentinel (rc=$rr_sent_rc)"
  echo "$rr_sent_out" | sed 's/^/    /'
fi
[[ -f "$SENT" ]] \
  && ok "rebase-recovery dry-run also leaves the sentinel untouched" \
  || bad "rebase-recovery dry-run deleted the sentinel (should be deferred to apply)"

# ---------------------------------------------------------------------------
banner "5. GitHub-only render (--no-linear)"
# Prove the producer path works with NO Linear: task from a file or a GitHub
# issue, GitHub-native closeout (PR + release:ready), and no LINEAR_API_KEY.
GH_TASK="$TMP/task.md"
printf '# Make the footer sticky\n\nThe footer should stick to viewport bottom. Keep it responsive.\n' > "$GH_TASK"

# 5a. --task-file, with LINEAR_API_KEY UNSET (proves no Linear key is needed).
: > "$CAPTURE_PROMPT"
set +e
tf_out="$( env -u LINEAR_API_KEY "$LAUNCHER" fix-footer "$REPO" --no-linear --task-file "$GH_TASK" --dry-run 2>&1 )"
tf_rc=$?
set -e
(( tf_rc == 0 )) \
  && ok "--no-linear --task-file dry-run exits 0 without LINEAR_API_KEY" \
  || { bad "--no-linear --task-file dry-run failed (rc=$tf_rc)"; echo "$tf_out" | sed 's/^/    /'; }
grep -q "Routing: operator" <<<"$tf_out" \
  && ok "--task-file task is auto-routed (operator)" \
  || bad "--task-file task not auto-routed"
grep -q "no Linear" <<<"$tf_out" \
  && ok "dry-run plan reports GitHub-only closeout" \
  || bad "dry-run plan did not report GitHub-only closeout"

if [[ -s "$CAPTURE_PROMPT" ]]; then
  if ! grep -q '{{' "$CAPTURE_PROMPT"; then
    ok "no leftover {{ placeholders in GitHub-only render"
  else
    bad "GitHub-only render left {{ placeholders"; grep -n '{{' "$CAPTURE_PROMPT" | sed 's/^/    /'
  fi
  grep -q '<issue_body>' "$CAPTURE_PROMPT" && grep -q '</issue_body>' "$CAPTURE_PROMPT" \
    && ok "GitHub-only render preserves <issue_body> boundary" \
    || bad "GitHub-only render missing <issue_body> boundary"
  grep -Fq "stick to viewport bottom" "$CAPTURE_PROMPT" \
    && ok "task-file body rendered into the prompt" \
    || bad "task-file body not found in rendered prompt"
  grep -q 'release:ready' "$CAPTURE_PROMPT" \
    && ok "GitHub-only prompt instructs adding release:ready" \
    || bad "GitHub-only prompt missing release:ready instruction"
  grep -q 'gh pr create' "$CAPTURE_PROMPT" \
    && ok "GitHub-only prompt uses gh pr create for closeout" \
    || bad "GitHub-only prompt missing gh pr create closeout"
  if ! grep -q 'final Linear comment' "$CAPTURE_PROMPT"; then
    ok "GitHub-only prompt has NO Linear-comment closeout"
  else
    bad "GitHub-only prompt still references a Linear-comment closeout"
  fi
else
  bad "did not capture a GitHub-only rendered prompt (capture file empty)"
fi

# 5b. --github-issue via fake gh, LINEAR_API_KEY UNSET.
: > "$CAPTURE_PROMPT"
set +e
gi_out="$( env -u LINEAR_API_KEY "$LAUNCHER" gh-42 "$REPO" --no-linear --github-issue 42 --dry-run 2>&1 )"
gi_rc=$?
set -e
(( gi_rc == 0 )) \
  && ok "--no-linear --github-issue dry-run exits 0 without LINEAR_API_KEY" \
  || { bad "--no-linear --github-issue dry-run failed (rc=$gi_rc)"; echo "$gi_out" | sed 's/^/    /'; }
grep -q "Fix the GH issue nav" <<<"$gi_out" \
  && ok "--github-issue title fetched via gh" \
  || bad "--github-issue title not fetched"
# lane:claude on the issue → routed via the LABEL guard (not operator).
grep -q "Routing: label" <<<"$gi_out" \
  && ok "--github-issue honors the lane:claude label routing guard" \
  || bad "--github-issue did not route via the label guard"
grep -Fq "Issue body from GitHub" "$CAPTURE_PROMPT" \
  && ok "github issue body rendered into the prompt" \
  || bad "github issue body not rendered"

# 5c. Fail-closed task-source validation.
set +e
none_out="$( env -u LINEAR_API_KEY "$LAUNCHER" slug "$REPO" --no-linear --dry-run 2>&1 )"; none_rc=$?
both_out="$( env -u LINEAR_API_KEY "$LAUNCHER" slug "$REPO" --no-linear --github-issue 1 --task-file "$GH_TASK" --dry-run 2>&1 )"; both_rc=$?
misuse_out="$( "$LAUNCHER" DEMO-1 "$REPO" --github-issue 1 --dry-run 2>&1 )"; misuse_rc=$?
set -e
{ (( none_rc != 0 )) && grep -qi "exactly one of" <<<"$none_out"; } \
  && ok "--no-linear with no task source is rejected" \
  || { bad "--no-linear with no task source not rejected (rc=$none_rc)"; echo "$none_out" | sed 's/^/    /'; }
{ (( both_rc != 0 )) && grep -qi "exactly one of" <<<"$both_out"; } \
  && ok "--no-linear with two task sources is rejected" \
  || { bad "--no-linear with two task sources not rejected (rc=$both_rc)"; echo "$both_out" | sed 's/^/    /'; }
{ (( misuse_rc != 0 )) && grep -qi "require --no-linear" <<<"$misuse_out"; } \
  && ok "--github-issue without --no-linear is rejected" \
  || { bad "--github-issue without --no-linear not rejected (rc=$misuse_rc)"; echo "$misuse_out" | sed 's/^/    /'; }

banner "Summary"
echo "  PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
