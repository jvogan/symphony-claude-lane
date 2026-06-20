#!/usr/bin/env bash
# test_release_manager_doctor.sh — isolated release-manager-doctor preflight tests.
#
# Exercises the GitHub-only-aware logic in bin/release-manager-doctor:
#   - Section 2 "Environment": RELEASE_MANAGER_* PASS lines, and the IMPORTANT
#     regression guard that a not-yet-created CLAUDE_RUNS_ROOT with a writable
#     parent is PASS (not a day-one FAIL).
#   - Section 3 "GitHub": the "Allow auto-merge" check (WARN when OFF under a
#     queue/auto strategy) and the release:* label-existence check.
#   - Section 4 "Merge queue / serialization": owner-type gating (personal repos
#     can't use Merge Queue), merge_queue detection via the consolidated
#     /rules/branches endpoint, and the strict-checks REBASE-STORM warning.
#
# Hermetic: never touches real gh/curl/Linear/tmux/claude. A scenario-driven fake
# gh is wired in via RELEASE_MANAGER_GH_BIN and PATH. Scenario knobs (env vars):
#   FAKE_OWNER   = Organization | User
#   FAKE_QUEUE   = yes | no            (merge_queue rule present in /rules/branches)
#   FAKE_STRICT  = true | false | none (required_status_checks strict policy)
#   FAKE_AUTOMERGE = true | false      (repo autoMergeAllowed)
#   FAKE_LABELS  = all | missing       (release:* label existence)
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
TMP="$(mktemp -d -t release-manager-doctor-test.XXXXXX)"
register_cleanup "rm -rf '$TMP'"

# Point runs/metrics into the sandbox so Section 2/6 checks stay hermetic.
export CLAUDE_RUNS_ROOT="$TMP/runs"
mkdir -p "$CLAUDE_RUNS_ROOT"
export RELEASE_MANAGER_METRICS_FILE="$CLAUDE_RUNS_ROOT/release-metrics.jsonl"

REPO="$TMP/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@example.test
git -C "$REPO" config user.name Test
echo "# release manager doctor test" > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm initial
# Doctor resolves the slug from origin via parse_origin_slug -> example/rmdoctor-test.
git -C "$REPO" remote add origin https://github.com/example/rmdoctor-test.git
ok "temporary repo ready"

STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR"
export GH_STUB_LOG="$TMP/gh.log"
: > "$GH_STUB_LOG"

# Scenario-driven fake gh. Emulates the calls the doctor actually makes:
#   repo view <slug> --json nameWithOwner                      (read probe)
#   repo view <slug> --json isInOrganization,visibility,autoMergeAllowed,squashMergeAllowed
#   label list -R <slug> --limit N --json name -q .[].name
#   api repos/<slug>/rules/branches/<base>                     (effective rules array)
#   api repos/<slug>/branches/<base>/protection                (classic fallback; 404)
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"

owner="${FAKE_OWNER:-Organization}"
queue="${FAKE_QUEUE:-yes}"
strict="${FAKE_STRICT:-none}"
automerge="${FAKE_AUTOMERGE:-true}"
labels="${FAKE_LABELS:-all}"

if [[ "${1:-}" == "auth" ]]; then exit 0; fi

if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  if [[ "$*" == *"-q .nameWithOwner"* ]]; then echo "example/rmdoctor-test"; exit 0; fi
  in_org=true; [[ "$owner" == "User" ]] && in_org=false
  jq -nc --argjson in_org "$in_org" --argjson am "$automerge" \
    '{nameWithOwner:"example/rmdoctor-test", isInOrganization:$in_org, visibility:"PUBLIC", autoMergeAllowed:$am, squashMergeAllowed:true}'
  exit 0
fi

if [[ "${1:-}" == "label" && "${2:-}" == "list" ]]; then
  if [[ "$labels" == "missing" ]]; then
    printf '%s\n' "release:ready"     # queued/merged/failed deliberately absent
  else
    printf '%s\n' "release:ready" "release:queued" "release:merged" "release:failed" "lane:claude"
  fi
  exit 0
fi

if [[ "${1:-}" == "api" ]]; then
  shift
  api_path=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jq|-q) shift 2 ;;
      --jq=*) shift ;;
      -*) shift ;;
      *) [[ -z "$api_path" ]] && api_path="$1"; shift ;;
    esac
  done
  case "$api_path" in
    */rules/branches/*)
      rules='[]'
      [[ "$queue" == "yes" ]] && rules='[{"type":"merge_queue"}]'
      if [[ "$strict" == "true" ]]; then
        rules="$(jq -nc --argjson r "$rules" '$r + [{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true}}]')"
      elif [[ "$strict" == "false" ]]; then
        rules="$(jq -nc --argjson r "$rules" '$r + [{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false}}]')"
      fi
      printf '%s' "$rules"
      exit 0
      ;;
    */branches/*/protection)
      # Classic branch protection fallback: simulate "not protected" (404).
      printf '%s' '{"message":"Branch not protected"}'
      exit 1
      ;;
    repos/*)
      # Bare repo metadata: doctor reads auto-merge via `gh api repos/<slug> --jq .allow_auto_merge`.
      printf '%s' "$automerge"
      exit 0
      ;;
  esac
  echo "unexpected gh api path: $api_path" >&2
  exit 7
fi

echo "unexpected gh args: $*" >&2
exit 7
STUB
chmod +x "$STUB_DIR/gh"
export RELEASE_MANAGER_GH_BIN="$STUB_DIR/gh"
export PATH="$STUB_DIR:$PATH"
ok "fake gh ready"

# Fake curl so Section 5 (Linear) never reaches the network.
export LINEAR_API_KEY="stub-doctor-key"
cat > "$STUB_DIR/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s' '{"data":{"viewer":{"id":"u_stub","name":"Doctor Stub"}}}'
CURL
chmod +x "$STUB_DIR/curl"
ok "fake curl (Linear) ready"

DOCTOR="$ROOT/bin/release-manager-doctor"

# run_doctor -> populates globals: out (combined stdout+stderr), rc. Extra args
# are passed through as VAR=value env overrides for the scenario knobs.
run_doctor() {
  : > "$GH_STUB_LOG"
  set +e
  out="$(env "$@" "$DOCTOR" --repo "$REPO" 2>&1)"
  rc=$?
  set -e
}

# ---------------------------------------------------------------------------
banner "1. Healthy org repo + merge queue + auto-merge"
run_doctor FAKE_OWNER=Organization FAKE_QUEUE=yes FAKE_AUTOMERGE=true FAKE_LABELS=all FAKE_STRICT=none
echo "$out" | sed 's/^/    /'
grep -q "PASS  example/rmdoctor-test is organization-owned" <<<"$out" \
  && ok "org-owned repo recognized" || bad "org-owned repo not recognized"
grep -q "PASS  GitHub Merge Queue configured for example/rmdoctor-test" <<<"$out" \
  && ok "merge queue detected via /rules/branches" || bad "merge queue not detected"
grep -q "PASS  Allow auto-merge enabled" <<<"$out" \
  && ok "auto-merge enabled recognized" || bad "auto-merge enabled not recognized"
grep -q "PASS  label exists: release:ready" <<<"$out" \
  && ok "release:ready label existence checked" || bad "label existence not checked"
(( rc == 0 )) && ok "doctor exits 0 on healthy org repo" || bad "doctor exited $rc on healthy repo"
if grep -q "  FAIL  " <<<"$out"; then bad "healthy run produced a FAIL line"; grep "  FAIL  " <<<"$out" | sed 's/^/    /'; else ok "healthy run produced no FAIL lines"; fi

# ---------------------------------------------------------------------------
banner "2. Personal repo + no queue + strict checks -> REBASE-STORM warning"
run_doctor FAKE_OWNER=User FAKE_QUEUE=no FAKE_STRICT=true FAKE_AUTOMERGE=false FAKE_LABELS=all
echo "$out" | sed 's/^/    /'
grep -q "WARN  example/rmdoctor-test is personal-account-owned" <<<"$out" \
  && ok "personal repo: merge queue flagged unavailable" || bad "personal repo not flagged"
grep -q "REBASE-STORM RISK" <<<"$out" \
  && ok "strict + no-queue escalates to REBASE-STORM warning" || bad "strict + no-queue did NOT warn about the storm"
grep -q "WARN  Allow auto-merge is OFF" <<<"$out" \
  && ok "auto-merge OFF under queue strategy warned" || bad "auto-merge OFF not warned"
(( rc == 0 )) && ok "doctor still exits 0 (warns, no FAIL)" || bad "doctor exited $rc (should warn-not-fail)"
if grep -q "  FAIL  " <<<"$out"; then bad "personal/strict run produced a FAIL line"; grep "  FAIL  " <<<"$out" | sed 's/^/    /'; else ok "personal/strict run produced no FAIL lines"; fi

# ---------------------------------------------------------------------------
banner "3. Personal repo + no queue + strict OFF -> plain serial warning (no storm)"
run_doctor FAKE_OWNER=User FAKE_QUEUE=no FAKE_STRICT=false FAKE_AUTOMERGE=true FAKE_LABELS=all
echo "$out" | sed 's/^/    /'
grep -q "no merge queue for example/rmdoctor-test" <<<"$out" \
  && ok "no-queue serial warning present" || bad "no-queue serial warning missing"
grep -q "strict up-to-date checks: false" <<<"$out" \
  && ok "strict=false surfaced in the serial warning" || bad "strict=false not surfaced"
if grep -q "REBASE-STORM RISK" <<<"$out"; then bad "strict OFF wrongly raised the storm warning"; else ok "strict OFF does NOT raise the storm warning"; fi
(( rc == 0 )) && ok "doctor exits 0 (strict off, serial)" || bad "doctor exited $rc"

# ---------------------------------------------------------------------------
banner "4. Missing release:* labels -> WARN"
run_doctor FAKE_OWNER=Organization FAKE_QUEUE=yes FAKE_AUTOMERGE=true FAKE_LABELS=missing FAKE_STRICT=none
echo "$out" | grep -E "label (exists|missing)" | sed 's/^/    /'
grep -q "WARN  label missing: release:queued" <<<"$out" \
  && ok "missing release:queued label warned" || bad "missing label not warned"
grep -q "PASS  label exists: release:ready" <<<"$out" \
  && ok "present label still passes" || bad "present label not recognized"
(( rc == 0 )) && ok "missing-label run exits 0 (warn, not fail)" || bad "missing-label run exited $rc"

# ---------------------------------------------------------------------------
banner "5. Section 2 — RELEASE_MANAGER_* env PASS"
run_doctor FAKE_OWNER=Organization FAKE_QUEUE=yes
for var in RELEASE_MANAGER_ON_CONFLICT RELEASE_MANAGER_REBASE_PR_LABEL RELEASE_MANAGER_REBASE_STATE RELEASE_MANAGER_MAX_REBASE_ATTEMPTS RELEASE_MANAGER_METRICS_FILE; do
  grep -q "PASS  $var=" <<<"$out" && ok "Section 2 prints PASS for $var" || bad "Section 2 missing PASS for $var"
done
grep -q "PASS  RELEASE_MANAGER_ON_CONFLICT=fail" <<<"$out" \
  && ok "RELEASE_MANAGER_ON_CONFLICT value echoed (fail)" || bad "RELEASE_MANAGER_ON_CONFLICT value not echoed"

# ---------------------------------------------------------------------------
banner "6. CLAUDE_RUNS_ROOT not-yet-created is PASS (day-one FAIL regression guard)"
# The HIGH bug: a fresh clone that never ran the lane has no runs/ dir, and the
# doctor used to hard-FAIL on it. A missing-but-creatable dir (writable parent)
# must now be PASS.
FRESH_RUNS="$TMP/runs-not-made-yet"
[[ ! -e "$FRESH_RUNS" ]] || rm -rf "$FRESH_RUNS"
set +e
out="$(env FAKE_OWNER=Organization FAKE_QUEUE=yes CLAUDE_RUNS_ROOT="$FRESH_RUNS" RELEASE_MANAGER_METRICS_FILE="$FRESH_RUNS/release-metrics.jsonl" "$DOCTOR" --repo "$REPO" 2>&1)"
rc=$?
set -e
echo "$out" | grep -E "CLAUDE_RUNS_ROOT" | sed 's/^/    /'
grep -q "PASS  CLAUDE_RUNS_ROOT not created yet" <<<"$out" \
  && ok "not-yet-created runs root is PASS (no day-one FAIL)" || bad "not-yet-created runs root did not PASS"
if grep -q "FAIL  CLAUDE_RUNS_ROOT" <<<"$out"; then bad "runs root still hard-FAILs when uncreated"; else ok "runs root does not hard-FAIL when uncreated"; fi
# The dir must NOT have been created as a side effect (doctor is read-only here).
[[ ! -e "$FRESH_RUNS" ]] && ok "doctor did not create the runs dir (read-only)" || { bad "doctor created the runs dir as a side effect"; register_cleanup "rm -rf '$FRESH_RUNS'"; }

banner "Summary"
echo "  PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
