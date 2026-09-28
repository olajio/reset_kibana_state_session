#!/usr/bin/env bash
#
# End-to-end check for reset_kibana_state_session.sh against a mock Kibana and
# a stub `aws secretsmanager get-secret-value`. No real AWS or Kibana needed.
#
#   ./tests/run_tests.sh

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
SCRIPT="$REPO_DIR/reset_kibana_state_session.sh"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reset-kibana-tests.XXXXXX")"
MOCK_PID=""
FAILURES=0

cleanup() {
    [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

check_contains() {  # check_contains <label> <file> <pattern>
    if grep -Fq -- "$3" "$2"; then pass "$1"; else
        fail "$1 (expected to find: $3)"
        printf '    --- output ---\n'; sed 's/^/    /' "$2"
    fi
}

check_absent() {  # check_absent <label> <file> <pattern>
    if grep -Fq -- "$3" "$2"; then
        fail "$1 (did not expect: $3)"
        printf '    --- output ---\n'; sed 's/^/    /' "$2"
    else pass "$1"; fi
}

# --------------------------------------------------------------------------
# Mock Kibana
# --------------------------------------------------------------------------
printf 'Starting mock Kibana...\n'
python3 "$TEST_DIR/mock_kibana.py" > "$WORK_DIR/port" 2>"$WORK_DIR/mock.log" &
MOCK_PID=$!
for _ in $(seq 1 50); do
    [[ -s "$WORK_DIR/port" ]] && break
    sleep 0.1
done
PORT="$(tr -d '[:space:]' < "$WORK_DIR/port")"
[[ -n "$PORT" ]] || { printf 'mock Kibana did not start\n'; cat "$WORK_DIR/mock.log"; exit 1; }
KIBANA_BASE="http://127.0.0.1:$PORT"
printf 'Mock Kibana on %s\n\n' "$KIBANA_BASE"

# --------------------------------------------------------------------------
# Stub `aws` on PATH. Returns a secret for the expected names only.
# --------------------------------------------------------------------------
mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/aws" <<AWS_STUB
#!/usr/bin/env bash
# Stub: only \`secretsmanager get-secret-value --secret-id <name>\` is supported.
secret_id=""
prev=""
for arg in "\$@"; do
    [[ "\$prev" == "--secret-id" ]] && secret_id="\$arg"
    prev="\$arg"
done
case "\$secret_id" in
    federal_store|agency_va_store|agency_dos_store)
        printf '%s' '{"kibana_url":"$KIBANA_BASE","kibana_username":"kibana_admin","kibana_password":"p@ss\"w\\\\ord"}'
        ;;
    agency_broken_store)
        printf '%s' '{"kibana_username":"kibana_admin","kibana_password":"nope"}'  # no URL
        ;;
    *)
        echo "An error occurred (ResourceNotFoundException): Secrets Manager can't find the specified secret." >&2
        exit 255
        ;;
esac
AWS_STUB
chmod +x "$WORK_DIR/bin/aws"
export PATH="$WORK_DIR/bin:$PATH"

export NO_COLOR=1

# --------------------------------------------------------------------------
printf 'Test: --help\n'
"$SCRIPT" --help > "$WORK_DIR/help.out" 2>&1
check_contains "help mentions the setting" "$WORK_DIR/help.out" 'state:storeInSessionStorage'
check_contains "help renders the agency secret template" "$WORK_DIR/help.out" 'agency_<agency>_store'

printf '\nTest: unknown option exits 2\n'
if "$SCRIPT" --bogus > "$WORK_DIR/bogus.out" 2>&1; then
    fail "unknown option should fail"
else
    [[ $? -eq 2 ]] || true
    check_contains "unknown option reported" "$WORK_DIR/bogus.out" 'unknown option: --bogus'
fi

printf '\nTest: secret name derivation (via a missing secret error)\n'
"$SCRIPT" --yes cdm-nope > "$WORK_DIR/nope.out" 2>&1 || true
check_contains "cdm-nope -> agency_nope_store" "$WORK_DIR/nope.out" "secret 'agency_nope_store'"

printf '\nTest: dry run changes nothing\n'
"$SCRIPT" --dry-run cdm-va > "$WORK_DIR/dry.out" 2>&1
check_contains "dry run finds master"           "$WORK_DIR/dry.out" 'would-reset'
check_contains "dry run reports default space"  "$WORK_DIR/dry.out" 'already-false'
check_contains "dry run mentions cdm-va secret" "$WORK_DIR/dry.out" "secret 'agency_va_store'"
check_absent  "dry run does not claim a reset"  "$WORK_DIR/dry.out" 'reset ('

printf '\nTest: real run resets every space\n'
"$SCRIPT" --yes --report-csv "$WORK_DIR/report.csv" cdm-va > "$WORK_DIR/run.out" 2>&1
check_contains "master reset"      "$WORK_DIR/run.out" 'cdm-va/master: state:storeInSessionStorage reset (true -> false)'
check_contains "analytics reset"   "$WORK_DIR/run.out" 'cdm-va/analytics: state:storeInSessionStorage reset (true -> false)'
check_contains "no failures"       "$WORK_DIR/run.out" 'done - no failures'
check_contains "csv header"        "$WORK_DIR/report.csv" 'deployment,space_id,space_name,value_before,action,detail'
check_contains "csv row for master" "$WORK_DIR/report.csv" '"cdm-va","master","Master","true","reset"'

printf '\nTest: second run is idempotent\n'
"$SCRIPT" --yes cdm-va > "$WORK_DIR/again.out" 2>&1
check_contains "master already false" "$WORK_DIR/again.out" 'cdm-va/master: already false'
check_contains "spaces already false: 3" "$WORK_DIR/again.out" 'spaces already false  : 3'

printf '\nTest: space filters\n'
"$SCRIPT" --yes --spaces master --dry-run cdm-va > "$WORK_DIR/filter.out" 2>&1
check_contains "analytics skipped" "$WORK_DIR/filter.out" 'not selected by --spaces'

printf '\nTest: deployments file is read by default\n'
cat > "$WORK_DIR/deployments.txt" <<'LIST'
# comment
cdm-va

cdm-dos   # trailing comment
LIST
"$SCRIPT" --yes --file "$WORK_DIR/deployments.txt" --dry-run > "$WORK_DIR/file.out" 2>&1
check_contains "read 2 deployments" "$WORK_DIR/file.out" 'read 2 deployment(s)'
check_contains "processed cdm-dos"  "$WORK_DIR/file.out" "secret 'agency_dos_store'"

printf '\nTest: cdm-fed maps to federal_store\n'
"$SCRIPT" --yes --dry-run cdm-fed > "$WORK_DIR/fed.out" 2>&1
check_contains "fed secret name" "$WORK_DIR/fed.out" "secret 'federal_store'"

printf '\nTest: deployment with an unusable secret fails, later ones still run\n'
"$SCRIPT" --yes --dry-run cdm-broken cdm-fed > "$WORK_DIR/mixed.out" 2>&1 && \
    fail "mixed run should exit non-zero" || pass "mixed run exits non-zero"
check_contains "broken deployment reported" "$WORK_DIR/mixed.out" 'no Kibana URL in secret'
check_contains "cdm-fed still processed"    "$WORK_DIR/mixed.out" "secret 'federal_store'"

printf '\nTest: credentials never appear in the output\n'
check_absent "password not logged (run)"  "$WORK_DIR/run.out" 'p@ss'
check_absent "password not logged (dry)"  "$WORK_DIR/dry.out" 'p@ss'

printf '\nTest: --reset-to-default removes the override\n'
"$SCRIPT" --yes --force --reset-to-default cdm-va > "$WORK_DIR/default.out" 2>&1
check_contains "override removed" "$WORK_DIR/default.out" 'unset(default false)'

printf '\n'
if ((FAILURES == 0)); then
    printf '\033[32mAll checks passed.\033[0m\n'
else
    printf '\033[31m%d check(s) failed.\033[0m\n' "$FAILURES"
    exit 1
fi
