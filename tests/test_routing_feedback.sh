#!/usr/bin/env bash
# test_routing_feedback.sh — isolated routing-feedback analyzer tests.
#
# routing-feedback is a READ-ONLY, fully-offline analyzer. These tests build a
# temporary CLAUDE_RUNS_ROOT with meta.env fixtures and a temporary profile,
# then assert:
#   - per-model n and pass-rate appear
#   - duration aggregation appears (and null durations don't crash)
#   - a profile lacking schema_version (or with schema_version: 3) triggers the
#     advisory-only warning and emits no concrete suggestions
#   - the tool writes NOTHING to the profile (mtime + content unchanged)
#   - the tool makes no network call (runs with no LINEAR_API_KEY, exits 0; the
#     source contains no curl)
#
# No real Linear, GitHub, or network access. Pure-bash with tmp fixtures.
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

RF="$ROOT/bin/routing-feedback"

# mtime (epoch seconds) helper. GNU stat uses `-c %Y`; BSD/macOS uses `-f %m`.
# Try the GNU form first, because on GNU `stat -f` means "filesystem status" (not
# format) and would treat `%m` as a path operand, printing volatile filesystem data
# instead of an mtime. Accept only a pure integer, so any misparsed output falls
# through rather than masquerading as a timestamp (which made unchanged files look
# modified and flaked the read-only check in CI).
mtime_of(){
  local m
  m="$(stat -c %Y "$1" 2>/dev/null)"
  [[ "$m" =~ ^[0-9]+$ ]] || m="$(stat -f %m "$1" 2>/dev/null)"
  [[ "$m" =~ ^[0-9]+$ ]] || m=0
  printf '%s\n' "$m"
}

banner "Setup"
TMP="$(mktemp -d -t routing-feedback-test.XXXXXX)"
register_cleanup "rm -rf '$TMP'"
export CLAUDE_RUNS_ROOT="$TMP/runs"
mkdir -p "$CLAUDE_RUNS_ROOT"

mkrun() {
  # mkrun ID  -- then KEY='value' lines on stdin
  local id="$1" dir
  dir="$CLAUDE_RUNS_ROOT/$id"
  mkdir -p "$dir"
  cat > "$dir/meta.env"
}

# opus #1: completed, 5 min, kind:ui
mkrun DEMO-1 <<'META'
issue_id='DEMO-1'
model='claude-opus-4-7'
model_tier='opus'
status='completed'
exit_reason='normal'
start_time='2026-06-19T00:00:00Z'
end_time='2026-06-19T00:05:00Z'
routing='label'
labels='kind:ui'
META

# opus #2: failed, 15 min, kind:ui
mkrun DEMO-2 <<'META'
issue_id='DEMO-2'
model='claude-opus-4-7'
model_tier='opus'
status='failed'
exit_reason='blocker'
start_time='2026-06-19T00:00:00Z'
end_time='2026-06-19T00:15:00Z'
routing='label'
labels='kind:ui'
META

# opus #3: completed, 3 min, kind:docs
mkrun DEMO-3 <<'META'
issue_id='DEMO-3'
model='claude-opus-4-7'
model_tier='opus'
status='completed'
exit_reason='normal'
start_time='2026-06-19T00:00:00Z'
end_time='2026-06-19T00:03:00Z'
routing='label'
labels='kind:docs'
META

# sonnet: completed, UNPARSEABLE end_time -> duration must be null, no crash
mkrun DEMO-4 <<'META'
issue_id='DEMO-4'
model='claude-sonnet-4-6'
model_tier='sonnet'
status='completed'
exit_reason='normal'
start_time='2026-06-19T00:00:00Z'
end_time='not-a-real-timestamp'
routing='label'
labels='kind:docs'
META

# no model recorded -> attribution coverage "unknown" bucket; still in n
mkrun DEMO-5 <<'META'
issue_id='DEMO-5'
model=''
status='running'
exit_reason=''
start_time='2026-06-19T00:00:00Z'
end_time=''
routing='task-characteristic'
labels=''
META
ok "temporary runs + meta.env fixtures ready"

# Valid profile (schema_version: 2).
PROFILE_OK="$TMP/claude-lane.yaml"
cat > "$PROFILE_OK" <<'YAML'
schema_version: 2
routing_strategy: task-characteristic
always_route_to_claude:
  - kind:ui
  - kind:docs
always_route_to_codex:
  - kind:infra
prefer_claude_when:
  - requires_browser_verification
prefer_codex_when:
  - bounded_implementation
YAML

# Profile lacking schema_version.
PROFILE_NOVER="$TMP/claude-lane-nover.yaml"
cat > "$PROFILE_NOVER" <<'YAML'
routing_strategy: task-characteristic
always_route_to_claude:
  - kind:ui
YAML

# Profile with schema_version: 3.
PROFILE_V3="$TMP/claude-lane-v3.yaml"
cat > "$PROFILE_V3" <<'YAML'
schema_version: 3
always_route_to_claude:
  - kind:ui
YAML
ok "temporary profiles ready (schema 2, no-schema, schema 3)"

banner "Valid schema: per-model + duration aggregation + suggestions"
out="$("$RF" --runs "$CLAUDE_RUNS_ROOT" --profile "$PROFILE_OK" --min-samples 2 2>&1)"
echo "$out" | sed 's/^/    /'

grep -Eq "claude-opus-4-7[[:space:]]+n=3" <<<"$out" \
  && ok "per-model line shows opus n=3" || bad "per-model opus n line missing"
grep -Eq "claude-sonnet-4-6[[:space:]]+n=1" <<<"$out" \
  && ok "per-model line shows sonnet n=1" || bad "per-model sonnet n line missing"
# opus: 2 completed of 3, but only completed+failed count to den (2/3 wait):
# DEMO-1 completed, DEMO-2 failed, DEMO-3 completed -> pass=2 fail=1 den=3 -> 66%
grep -Eq "claude-opus-4-7.*pass-rate=66% \(2/3\)" <<<"$out" \
  && ok "per-model opus pass-rate=66% (2/3)" || bad "per-model opus pass-rate wrong"
# Duration aggregation present: opus durations are 300s and 180s (DEMO-2 failed
# still has a valid duration of 900s) -> median over [180,300,900]=300.
grep -Eq "claude-opus-4-7.*median_s=300.*p90_s=" <<<"$out" \
  && ok "duration aggregation (median_s/p90_s) appears" || bad "duration aggregation missing"
# Null duration must not crash and must be reflected as n/a for sonnet.
grep -Eq "claude-sonnet-4-6.*median_s=n/a" <<<"$out" \
  && ok "unparseable end_time yields null duration (median_s=n/a), no crash" \
  || bad "null-duration handling wrong"
# exit_reason histogram present.
grep -q "exit_reasons:" <<<"$out" \
  && ok "exit_reason histogram present" || bad "exit_reason histogram missing"
# Attribution coverage: 5 scanned, 4 with model, 1 unknown.
grep -Eq "runs scanned: 5[[:space:]]+with model: 4[[:space:]]+unknown model: 1" <<<"$out" \
  && ok "attribution coverage line correct (5/4/1)" || bad "attribution coverage line wrong"
# Characteristic aggregation present (kind:ui & kind:docs map to route:claude).
grep -Eq "By task-characteristic" <<<"$out" \
  && grep -Eq "route:claude[[:space:]]+n=" <<<"$out" \
  && ok "per-characteristic aggregation appears" || bad "per-characteristic aggregation missing"
# Suggestion fires for opus (66% < 70%, n=3 >= min-samples 2) and cites counts.
grep -Eq 'model "claude-opus-4-7" has low pass-rate \(66%, n=3' <<<"$out" \
  && ok "suggestion flags low-pass-rate model with counts" || bad "expected opus suggestion missing"
# Codex-blindness note present in suggestions.
grep -q "Codex-side outcomes are NOT captured" <<<"$out" \
  && ok "Codex-blindness note present" || bad "Codex-blindness note missing"

banner "min-samples gate suppresses small cells"
# With --min-samples 4, opus (n=3) is below threshold -> no opus suggestion.
out_hi="$("$RF" --runs "$CLAUDE_RUNS_ROOT" --profile "$PROFILE_OK" --min-samples 4 2>&1)"
if grep -Eq 'model "claude-opus-4-7" has low pass-rate' <<<"$out_hi"; then
  bad "min-samples 4 should suppress opus suggestion (n=3)"
else
  ok "min-samples gate suppresses cells below threshold"
fi

banner "Schema gate: missing schema_version -> advisory-only"
out_nover="$("$RF" --runs "$CLAUDE_RUNS_ROOT" --profile "$PROFILE_NOVER" --min-samples 1 2>&1)"
echo "$out_nover" | sed 's/^/    /'
grep -Eq "WARNING.*schema_version missing.*ADVISORY-ONLY" <<<"$out_nover" \
  && ok "missing schema_version prints advisory-only warning" || bad "missing-schema warning absent"
if grep -Eq 'has low pass-rate' <<<"$out_nover"; then
  bad "missing-schema run still emitted concrete suggestions"
else
  ok "missing-schema run emits no concrete suggestions"
fi

banner "Schema gate: schema_version 3 -> advisory-only"
out_v3="$("$RF" --runs "$CLAUDE_RUNS_ROOT" --profile "$PROFILE_V3" --min-samples 1 2>&1)"
echo "$out_v3" | sed 's/^/    /'
grep -Eq "WARNING.*schema_version=3 != 2.*ADVISORY-ONLY" <<<"$out_v3" \
  && ok "schema_version 3 prints advisory-only warning" || bad "schema-3 warning absent"
if grep -Eq 'has low pass-rate' <<<"$out_v3"; then
  bad "schema-3 run still emitted concrete suggestions"
else
  ok "schema-3 run emits no concrete suggestions"
fi

banner "Read-only: profile mtime + content unchanged"
m_before="$(mtime_of "$PROFILE_OK")"
c_before="$(shasum "$PROFILE_OK" | cut -d' ' -f1)"
m_nover_before="$(mtime_of "$PROFILE_NOVER")"
c_nover_before="$(shasum "$PROFILE_NOVER" | cut -d' ' -f1)"
"$RF" --runs "$CLAUDE_RUNS_ROOT" --profile "$PROFILE_OK" --min-samples 1 >/dev/null 2>&1
"$RF" --runs "$CLAUDE_RUNS_ROOT" --profile "$PROFILE_NOVER" --min-samples 1 >/dev/null 2>&1
m_after="$(mtime_of "$PROFILE_OK")"
c_after="$(shasum "$PROFILE_OK" | cut -d' ' -f1)"
m_nover_after="$(mtime_of "$PROFILE_NOVER")"
c_nover_after="$(shasum "$PROFILE_NOVER" | cut -d' ' -f1)"
if [[ "$m_before" == "$m_after" && "$c_before" == "$c_after" ]]; then
  ok "valid profile unchanged (mtime + content)"
else
  bad "valid profile was modified by the analyzer"
fi
if [[ "$m_nover_before" == "$m_nover_after" && "$c_nover_before" == "$c_nover_after" ]]; then
  ok "no-schema profile unchanged (mtime + content)"
else
  bad "no-schema profile was modified by the analyzer"
fi

banner "Offline: no LINEAR_API_KEY, exits 0, no curl in source"
set +e
( unset LINEAR_API_KEY; "$RF" --runs "$CLAUDE_RUNS_ROOT" --profile "$PROFILE_OK" >/dev/null 2>&1 )
rc_offline=$?
set -e
if (( rc_offline == 0 )); then
  ok "runs with no LINEAR_API_KEY and exits 0"
else
  bad "analyzer exited non-zero with no LINEAR_API_KEY (rc=$rc_offline)"
fi
if grep -q "curl" "$RF"; then
  bad "routing-feedback source contains curl (should be fully offline)"
else
  ok "routing-feedback source contains no curl (no network code path)"
fi
# Defense in depth: no Linear endpoint or gh invocation in the source.
if grep -Eq "api\.linear\.app|graphql|(^|[^A-Za-z_])gh " "$RF"; then
  bad "routing-feedback source references Linear/GitHub network endpoints"
else
  ok "routing-feedback source has no Linear/GitHub references"
fi

banner "Default profile resolution via --repo"
# With --repo and no --profile, the default path is <repo>/.orchestration/claude-lane.yaml.
REPO_DIR="$TMP/repo"
mkdir -p "$REPO_DIR/.orchestration"
cp "$PROFILE_OK" "$REPO_DIR/.orchestration/claude-lane.yaml"
out_repo="$("$RF" --runs "$CLAUDE_RUNS_ROOT" --repo "$REPO_DIR" --min-samples 1 2>&1)"
grep -q "$REPO_DIR/.orchestration/claude-lane.yaml" <<<"$out_repo" \
  && ok "--repo resolves default .orchestration/claude-lane.yaml" || bad "--repo default profile path wrong"
if grep -Eq "WARNING.*ADVISORY-ONLY" <<<"$out_repo"; then
  bad "--repo default profile (schema 2) wrongly tripped advisory-only"
else
  ok "--repo default profile (schema 2) passes schema gate"
fi

banner "Empty runs directory"
EMPTY_RUNS="$TMP/empty-runs"
mkdir -p "$EMPTY_RUNS"
out_empty="$("$RF" --runs "$EMPTY_RUNS" --profile "$PROFILE_OK" 2>&1)"
grep -Eq "runs scanned: 0" <<<"$out_empty" \
  && ok "empty runs dir reports 0 scanned without crashing" || bad "empty runs dir handling wrong"

banner "Summary"
echo "  PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
