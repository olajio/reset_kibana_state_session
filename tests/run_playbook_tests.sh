#!/usr/bin/env bash
#
# End-to-end checks for playbooks/reset_kibana_state_session.yml. Runs the real
# playbook against this machine (standing in for the `appserver`), with a mock
# Kibana and a stub `aws` serving secrets in the real schema (kibana_url +
# awx_manage_kibana_api_key). No AWS, Kibana, AAP or sudo needed.
#
#   ./tests/run_playbook_tests.sh
#
# Needs ansible-core 2.15 or later. To use a particular install:
#
#   ANSIBLE_BIN_DIR=/path/to/venv/bin ./tests/run_playbook_tests.sh
#
# KEEP_TEST_OUTPUT=1 keeps every run's output and the deployed files for
# inspection; the directory is printed at the end.

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
PLAYBOOK="$REPO_DIR/playbooks/reset_kibana_state_session.yml"
ANSIBLE_PLAYBOOK="${ANSIBLE_BIN_DIR:+$ANSIBLE_BIN_DIR/}ansible-playbook"

if ! command -v "$ANSIBLE_PLAYBOOK" >/dev/null 2>&1; then
    printf 'SKIPPED: ansible-playbook not found (install ansible-core, or set ANSIBLE_BIN_DIR)\n'
    exit 0
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reset-kibana-pb-tests.XXXXXX")"
MOCK_PID=""
FAILURES=0
CHECKS=0
RC=0
OUT=""

cleanup() {
    if [[ -n "$MOCK_PID" ]]; then kill "$MOCK_PID" 2>/dev/null || true; fi
    if [[ -n "${KEEP_TEST_OUTPUT:-}" ]]; then
        printf 'Test output kept in %s\n' "$WORK_DIR"
    else
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

pass() { CHECKS=$((CHECKS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() {
    CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1))
    printf '  \033[31mFAIL\033[0m %s\n' "$1"
    if [[ -n "$OUT" && -f "$OUT" ]]; then
        printf '    --- output (last 60 lines) ---\n'; tail -n 60 "$OUT" | sed 's/^/    /'
    fi
}
check_rc()       { if [[ "$RC" == "$2" ]]; then pass "$1"; else fail "$1 (exit $RC, expected $2)"; fi; }
check_contains() { if grep -Fq -- "$2" "$OUT"; then pass "$1"; else fail "$1 (expected to find: $2)"; fi; }
check_absent()   { if grep -Fq -- "$2" "$OUT"; then fail "$1 (did not expect: $2)"; else pass "$1"; fi; }
check_order()    {  # check_order <label> <first> <second>: first appears before second
    local a b
    a="$(grep -nF -m1 -- "$2" "$OUT" | cut -d: -f1)"; b="$(grep -nF -m1 -- "$3" "$OUT" | cut -d: -f1)"
    if [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; then pass "$1"; else fail "$1 ('$2' at ${a:-none}, '$3' at ${b:-none})"; fi
}

# --------------------------------------------------------------------------
# Mock Kibana, secrets, stub aws
# --------------------------------------------------------------------------
printf 'Starting mock Kibana...\n'
python3 "$TEST_DIR/mock_kibana.py" > "$WORK_DIR/port" 2>"$WORK_DIR/mock.log" &
MOCK_PID=$!
for _ in $(seq 1 50); do [[ -s "$WORK_DIR/port" ]] && break; sleep 0.1; done
PORT="$(tr -d '[:space:]' < "$WORK_DIR/port")"
[[ -n "$PORT" ]] || { printf 'mock Kibana did not start\n'; cat "$WORK_DIR/mock.log"; exit 1; }
KIBANA_BASE="http://127.0.0.1:$PORT"

export SECRETS_DIR="$WORK_DIR/secrets"
mkdir -p "$SECRETS_DIR" "$WORK_DIR/bin"
python3 - "$SECRETS_DIR" "$KIBANA_BASE" <<'PY'
import base64, json, os, sys
out, base = sys.argv[1], sys.argv[2]
key = base64.b64encode(b"test-key-id:test-key-secret").decode()
secrets = {
    "federal_store":    {"kibana_url": base, "awx_manage_kibana_api_key": key},
    "agency_va_store":  {"kibana_url": base, "awx_manage_kibana_api_key": key},
    "agency_dos_store": {"kibana_url": base, "awx_manage_kibana_api_key": key},
    "agency_slow_store": {"kibana_url": base + "/slow", "awx_manage_kibana_api_key": key},
}
for name, value in secrets.items():
    with open(os.path.join(out, name + ".json"), "w") as f:
        json.dump(value, f)
PY

cat > "$WORK_DIR/bin/aws" <<'AWS_STUB'
#!/usr/bin/env bash
# Stub for `aws secretsmanager get-secret-value --secret-id NAME ...`; records
# the environment and arguments it was called with.
secret_id='' prev=''
for arg in "$@"; do
    [[ "$prev" == --secret-id ]] && secret_id="$arg"
    prev="$arg"
done
printf 'AWS_REGION=%s AWS_CA_BUNDLE=%s FED_DEPLOYMENT=%s ARGS=%s\n' \
    "${AWS_REGION-unset}" "${AWS_CA_BUNDLE-unset}" "${FED_DEPLOYMENT-unset}" "$*" \
    >> "$SECRETS_DIR/../aws-calls.log"
file="$SECRETS_DIR/$secret_id.json"
if [[ -n "$secret_id" && "$secret_id" != */* && -f "$file" ]]; then
    cat "$file"
else
    echo "An error occurred (ResourceNotFoundException) when calling the GetSecretValue operation: Secrets Manager can't find the specified secret." >&2
    exit 254
fi
AWS_STUB
chmod +x "$WORK_DIR/bin/aws"

# A CA bundle file that exists (the mock is plain HTTP, so it is never used).
CA_BUNDLE=""
for candidate in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do
    if [[ -r "$candidate" ]]; then CA_BUNDLE="$candidate"; break; fi
done
if [[ -z "$CA_BUNDLE" ]]; then CA_BUNDLE="$WORK_DIR/ca.pem"; : > "$CA_BUNDLE"; fi

# --------------------------------------------------------------------------
# Inventory and the variables every run shares
# --------------------------------------------------------------------------
cat > "$WORK_DIR/inventory.yml" <<'INV'
all:
  children:
    appserver:
      hosts:
        localhost:
          ansible_connection: local
          ansible_python_interpreter: "{{ ansible_playbook_python }}"
INV

TARGET="$WORK_DIR/target"
printf '# test deployments\ncdm-va\ncdm-dos\n' > "$WORK_DIR/deployments.txt"
python3 - "$WORK_DIR/common.json" <<PY
import json, sys
json.dump({
    "ansible_become": False,            # no sudo needed to test
    "script_dir": "$TARGET",
    "deployments_file": "$WORK_DIR/deployments.txt",
    "ca_bundle": "$CA_BUNDLE",
    "script_path": "$WORK_DIR/bin:$PATH",
    "poll_interval_seconds": 1,
}, open(sys.argv[1], "w"))
PY

export ANSIBLE_NOCOLOR=1 ANSIBLE_FORCE_COLOR=0 ANSIBLE_LOCALHOST_WARNING=False \
       ANSIBLE_DEPRECATION_WARNINGS=False ANSIBLE_RETRY_FILES_ENABLED=False \
       ANSIBLE_STDOUT_CALLBACK=default ANSIBLE_LOCAL_TEMP="$WORK_DIR/ansible-tmp"

# run_pb <label> [ansible-playbook args...]
run_pb() {
    local label="$1"; shift
    OUT="$WORK_DIR/$label.out"
    set +e
    "$ANSIBLE_PLAYBOOK" -i "$WORK_DIR/inventory.yml" "$PLAYBOOK" -e "@$WORK_DIR/common.json" "$@" > "$OUT" 2>&1
    RC=$?
    set -e
}

printf 'Using %s\n\n' "$("$ANSIBLE_PLAYBOOK" --version | head -n 1)"

# ==========================================================================
printf 'Test: input validation fails before anything reaches the appserver\n'
validation_case() {  # validation_case <label> <expected message> <ansible args...>
    local label="$1" message="$2"; shift 2
    run_pb "$label" -e "script_dir=$WORK_DIR/untouched-$label" "$@"
    check_rc "$label: playbook fails" 2
    check_contains "$label: explained" "$message"
    if [[ -e "$WORK_DIR/untouched-$label" ]]; then fail "$label: appserver was touched"; else pass "$label: appserver untouched"; fi
}
validation_case no_deployments  'variable naming at least one deployment' -e 'deployments='
validation_case blank_list      'variable naming at least one deployment' -e '{"deployments": []}'
validation_case excl_all_word   "exclude_deployments cannot contain 'all'" -e '{"deployments": ["all"], "exclude_deployments": ["all"]}'
validation_case excl_everything 'exclude_deployments leaves nothing to do' -e '{"deployments": ["all"], "exclude_deployments": ["cdm-va", "cdm-dos"]}'
validation_case excl_bad_name   'Not valid deployment names'              -e '{"deployments": ["all"], "exclude_deployments": ["cdm-dos;rm"]}'
validation_case bad_run_mode    "run_mode must be 'dry-run' or 'execute'" -e deployments=cdm-va -e run_mode=go
validation_case bad_value_mode  "value_mode must be 'set-false' or"       -e deployments=cdm-va -e value_mode=zero
validation_case bad_name        'Not valid deployment names'              -e 'deployments="cdm-va;touch /tmp/x"'
validation_case bad_space       'Not valid Kibana space IDs'              -e deployments=cdm-va -e spaces=Master
validation_case parallel_zero   'parallel_jobs must be a whole number'    -e deployments=cdm-va -e parallel_jobs=0
validation_case parallel_big    'parallel_jobs must be a whole number'    -e deployments=cdm-va -e parallel_jobs=51
validation_case parallel_text   'parallel_jobs must be a whole number'    -e deployments=cdm-va -e parallel_jobs=lots
printf '# only comments\n\n' > "$WORK_DIR/empty.txt"
validation_case all_empty_file  'has no active entries'                   -e deployments=all -e "deployments_file=$WORK_DIR/empty.txt"

# ==========================================================================
printf '\nTest: a missing tool on the appserver is reported up front\n'
run_pb missing_tool -e deployments=cdm-va -e 'script_path=/usr/sbin:/usr/bin:/sbin:/bin'
check_rc "missing aws fails the playbook" 2
check_contains "missing aws named" ': aws (install them, or add their directory to script_path)'
check_absent "script never ran" '=== cdm-va ==='

# ==========================================================================
printf '\nTest: dry run\n'
: > "$WORK_DIR/aws-calls.log"
run_pb dry -e 'deployments="cdm-va, cdm-dos"'
check_rc "dry run succeeds" 0
check_contains "announced as dry run"           'DRY-RUN MODE - no changes will be made'
check_contains "two deployments, two jobs"      '2 deployment(s) in 2 parallel job(s): cdm-va, cdm-dos'
check_contains "script output shown"            '=== cdm-va ==='
check_contains "summary: needing reset"         'spaces needing reset      : 4  (dry run - nothing was changed)'
check_contains "summary: deployments"           'deployments in report     : 2'
check_contains "summary: no failures"           'deployments with failures : 0'
check_order    "summary comes after the output" '=== cdm-dos ===' 'RUN SUMMARY'
if [[ -x "$TARGET/reset_kibana_state_session.sh" ]]; then pass "script deployed and executable"; else fail "script not deployed"; fi
logs=( "$TARGET"/logs/reset_*.log ); reports=( "$TARGET"/reports/reset_*.csv )
if [[ -s "${logs[0]}" ]]; then pass "consolidated log written"; else fail "no consolidated log"; fi
if [[ -s "${reports[0]}" && "$(wc -l < "${reports[0]}")" -eq 7 ]]; then
    pass "merged CSV has one header and 6 rows"
else
    fail "merged CSV wrong: ${reports[0]:-none} ($(wc -l < "${reports[0]}" 2>/dev/null || echo 0) lines)"
fi
run_dirs=( "$TARGET"/reports/*/ )
if [[ -s "${run_dirs[0]}job1.csv" && -s "${run_dirs[0]}job2.csv" ]]; then
    pass "per-job CSVs kept under reports/<run>/ (the paths the script logs stay valid)"
else
    fail "per-job CSVs missing under ${run_dirs[0]:-reports/<run>/}"
fi
OUT="$WORK_DIR/dry.out"
check_contains "jobs numbered from 1 in their CSV names" '/job1.csv'
check_absent   "no blank summary events" '"msg": ""'
OUT="$WORK_DIR/aws-calls.log"
check_contains "AWS region passed"      'AWS_REGION=us-east-1'
check_contains "AWS CA bundle passed"   "AWS_CA_BUNDLE=$CA_BUNDLE"
check_contains "--region passed"        '--region us-east-1'
check_contains "FED_DEPLOYMENT passed"  'FED_DEPLOYMENT=cdm-fed'

# ==========================================================================
printf '\nTest: execute\n'
run_pb execute -e deployments=cdm-va -e run_mode=execute
check_rc "execute succeeds" 0
check_contains "announced as execute"  'EXECUTE MODE - state:storeInSessionStorage WILL be set to false in every space of 1 deployment(s)'
check_contains "master reset"          'cdm-va/master: state:storeInSessionStorage reset (true -> false)'
check_contains "summary: reset count"  'spaces reset to false     : 2'

run_pb execute_again -e deployments=cdm-va -e run_mode=execute
check_rc "second execute succeeds" 0
check_contains "idempotent"            'spaces already false      : 3'

# ==========================================================================
printf '\nTest: "all" expands deployments.txt on the controller\n'
printf '# comment\ncdm-va, cdm-dos\ncdm-fed   # trailing comment\nALL\ncdm-va\n' > "$WORK_DIR/all.txt"
run_pb all -e deployments=all -e "deployments_file=$WORK_DIR/all.txt" -e parallel_jobs=2
check_rc "'all' succeeds" 0
check_contains "commas, comments, duplicates and an 'all' line handled" '3 deployment(s) in 2 parallel job(s): cdm-va, cdm-dos, cdm-fed'
check_contains "summary covers all three" 'deployments in report     : 3'
run_pb all_upper -e deployments=ALL -e "deployments_file=$WORK_DIR/all.txt"
check_contains "'ALL' works too" '3 deployment(s) in 3 parallel job(s)'

# ==========================================================================
printf '\nTest: multiple-select answers (lists), as the survey sends them\n'
run_pb ms_all -e '{"deployments": ["all"]}'
check_rc "[\"all\"] works" 0
check_contains "[\"all\"] reads deployments.txt" '2 deployment(s) in 2 parallel job(s): cdm-va, cdm-dos'

run_pb ms_all_plus -e '{"deployments": ["all", "cdm-va"]}'
check_rc "'all' ticked with a name is accepted" 0
check_contains "a name already in the file adds nothing" '2 deployment(s) in 2 parallel job(s): cdm-va, cdm-dos'

run_pb ms_all_extra -e '{"deployments": ["all", "cdm-fed"]}'
check_contains "a ticked name not in the file is added after it" '3 deployment(s) in 3 parallel job(s): cdm-va, cdm-dos, cdm-fed'

run_pb ms_names -e '{"deployments": ["cdm-dos", "cdm-va"]}'
check_contains "ticked names kept in order" '2 deployment(s) in 2 parallel job(s): cdm-dos, cdm-va'

# ==========================================================================
printf '\nTest: exclude_deployments\n'
run_pb excl_list -e '{"deployments": ["all"], "exclude_deployments": ["cdm-dos"]}'
check_rc "excluding from 'all' works" 0
check_contains "exclusion announced"          'Excluding 1 deployment(s): cdm-dos'
check_contains "excluded deployment removed"  '1 deployment(s) in 1 parallel job(s): cdm-va'
check_absent   "excluded deployment never run" '=== cdm-dos ==='

run_pb excl_text -e '{"deployments": ["all", "cdm-fed"], "exclude_deployments": "cdm-va, cdm-dos"}'
check_contains "text exclusion with ', '" 'Excluding 2 deployment(s): cdm-va, cdm-dos'
check_contains "only cdm-fed left"         '1 deployment(s) in 1 parallel job(s): cdm-fed'

run_pb excl_text_comma -e deployments=all -e 'exclude_deployments=cdm-va,cdm-dos' -e "deployments_file=$WORK_DIR/all.txt"
check_contains "text exclusion with ','"   '1 deployment(s) in 1 parallel job(s): cdm-fed'

run_pb excl_unmatched -e '{"deployments": ["cdm-va"], "exclude_deployments": ["cdm-dos"]}'
check_rc "an exclusion that matches nothing still runs" 0
check_contains "unmatched exclusion warned" 'excluding them had no effect: cdm-dos'

run_pb excl_blank -e '{"deployments": ["cdm-va"], "exclude_deployments": ""}'
check_rc "a blank exclusion is ignored" 0
check_absent "nothing announced as excluded" 'Excluding'

# ==========================================================================
printf '\nTest: Skip spaces accepts comma separated IDs, with or without spaces\n'
for form in 'default,admin,infra' 'default, admin, infra'; do
    run_pb "skip_${form//[^a-z]/_}" -e deployments=cdm-va -e "{\"exclude_spaces\": \"$form\"}"
    check_rc "'$form' accepted" 0
    check_contains "'$form': passed to the script"  'excluded by --exclude-spaces'
    check_contains "'$form': exactly one space (default) skipped" 'spaces skipped            : 1'
    check_contains "'$form': other spaces still processed" 'cdm-va/master: already false'
done

# ==========================================================================
printf '\nTest: other input forms and options\n'
run_pb list_input -e '{"deployments": ["cdm-dos"]}'
check_rc "a list of deployments works" 0
check_contains "list input resolved" '1 deployment(s) in 1 parallel job(s): cdm-dos'

run_pb newline_input -e '{"deployments": "cdm-va\ncdm-dos\n"}'
check_contains "one-per-line (textarea) input works" '2 deployment(s) in 2 parallel job(s): cdm-va, cdm-dos'

run_pb blank_parallel -e deployments=cdm-va -e parallel_jobs=
check_rc "blank parallel_jobs falls back to the default" 0

run_pb spaces -e deployments=cdm-va -e 'spaces="master"'
check_contains "--spaces passed through" 'not selected by --spaces'
run_pb exclude -e deployments=cdm-va -e 'exclude_spaces="default, analytics"'
check_contains "--exclude-spaces passed through" 'excluded by --exclude-spaces'

run_pb insecure -e deployments=cdm-va -e verify_ssl=false
check_contains "verify_ssl=false passes --insecure" '--insecure: Kibana TLS certificates will NOT be verified'

run_pb verbose -e deployments=cdm-va -e verbose=true
check_contains "verbose=true passes --verbose" 'DEBUG: GET'

run_pb fed_override -e deployments=cdm-fdb -e fed_deployment=cdm-fdb
check_rc "fed_deployment override works" 0
check_contains "cdm-fdb uses federal_store" "cdm-fdb: secret 'federal_store'"

run_pb reset_default -e deployments=cdm-va -e run_mode=execute -e value_mode=reset-to-default -e force=true
check_rc "reset-to-default succeeds" 0
check_contains "override removed" 'unset(default false)'

# ==========================================================================
printf '\nTest: a failing deployment fails the job, after showing everything\n'
run_pb partial -e 'deployments="cdm-va, cdm-missing"' -e parallel_jobs=2
check_rc "job fails" 2
check_contains "good deployment's output still shown"  '=== cdm-va ==='
check_contains "summary counts the failed deployment"  'deployments with failures : 1'
check_contains "failed row listed"                     "FAILED           cdm-missing / -: aws secretsmanager get-secret-value failed for 'agency_missing_store'"
check_contains "failed job named"                      'Job 2 (cdm-missing) failed with rc=1 - at least one deployment or space failed'
check_absent   "successful job not reported as failed" 'Job 1 (cdm-va) failed'
check_contains "job marked failed"                     '1 of 2 job(s) did not complete cleanly'
check_order    "summary shown before the job fails"    'RUN SUMMARY' 'did not complete cleanly'

# ==========================================================================
printf '\nTest: a job that runs too long is stopped and reported\n'
run_pb timeout -e deployments=cdm-slow -e job_timeout_seconds=2
check_rc "timed-out job fails the playbook" 2
check_contains "timeout reported for the job" 'did not finish'
check_contains "job marked failed"            '1 of 1 job(s) did not complete cleanly'

# ==========================================================================
printf '\nTest: the AAP survey spec matches the playbook and deployments.txt\n'
SURVEY="$REPO_DIR/aap/survey_spec.json"
OUT="$WORK_DIR/survey-check.out"
if python3 - "$SURVEY" "$PLAYBOOK" > "$OUT" 2>&1 <<'PY'
import json, re, sys
spec = json.load(open(sys.argv[1]))["spec"]
playbook = open(sys.argv[2]).read()
problems = []
for q in spec:
    var, kind = q["variable"], q["type"]
    if not re.search(r"^    %s:" % re.escape(var), playbook, re.M):
        problems.append("%s: not a variable in the playbook's vars" % var)
    if kind == "multiplechoice" and q["default"] not in q["choices"]:
        problems.append("%s: default %r is not one of %r" % (var, q["default"], q["choices"]))
    if kind == "multiselect":
        if not isinstance(q["choices"], list) or not q["choices"]:
            problems.append("%s: multiselect without choices" % var)
        elif q["default"] not in ("", None) and q["default"] not in q["choices"]:
            problems.append("%s: default %r is not one of the choices" % (var, q["default"]))
    if kind == "integer" and not (q["min"] <= q["default"] <= q["max"]):
        problems.append("%s: default outside min/max" % var)
    for key in ("question_name", "required", "type", "variable", "default"):
        if key not in q:
            problems.append("%s: missing %s" % (var, key))
by_var = {q["variable"]: q for q in spec}
if by_var.get("deployments", {}).get("type") != "multiselect" or "all" not in by_var["deployments"]["choices"]:
    problems.append("deployments: should be multiselect offering 'all'")
if "all" in by_var.get("exclude_deployments", {}).get("choices", []):
    problems.append("exclude_deployments: must not offer 'all'")
print("\n".join(problems) or "ok")
sys.exit(1 if problems else 0)
PY
then pass "survey spec is valid and every variable exists in the playbook"; else fail "survey spec problems"; fi

OUT="$WORK_DIR/survey-sync.out"
if python3 "$REPO_DIR/aap/build_survey_spec.py" --check > "$OUT" 2>&1; then
    pass "survey_spec.json is up to date with deployments.txt"
else
    fail "survey_spec.json is stale: run python3 aap/build_survey_spec.py"
fi

# What AAP sends: multiple-select answers as lists, multiple choice as strings,
# blank optional text as "". Answers are picked from the spec's own choices,
# as AAP only allows those.
survey_answers() {  # survey_answers <out.json> <deployments...> -- <excluded...>
    python3 - "$SURVEY" "$@" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1]))["spec"]
out, rest = sys.argv[2], sys.argv[3:]
split = rest.index("--")
picked = {"deployments": rest[:split], "exclude_deployments": rest[split + 1:]}
answers = {}
for q in spec:
    if q["type"] == "multiselect":
        value = picked[q["variable"]]
        bad = [v for v in value if v not in q["choices"]]
        if bad:
            sys.exit("AAP would reject %s for %s: not among the choices" % (bad, q["variable"]))
        if value or q["required"]:
            answers[q["variable"]] = value
    else:
        answers[q["variable"]] = q["default"]
json.dump(answers, open(out, "w"))
PY
}

survey_answers "$WORK_DIR/survey-names.json" cdm-va cdm-dos --
run_pb survey_names -e "@$WORK_DIR/survey-names.json"
check_rc "survey: two deployments ticked" 0
check_contains "survey defaults are a dry run" 'DRY-RUN MODE'
check_contains "survey: ticked deployments used" '2 deployment(s) in 2 parallel job(s): cdm-va, cdm-dos'

survey_answers "$WORK_DIR/survey-all-excl.json" all -- cdm-dos
run_pb survey_all_excl -e "@$WORK_DIR/survey-all-excl.json"
check_rc "survey: 'all' with one excluded" 0
check_contains "survey: exclusion applied" 'Excluding 1 deployment(s): cdm-dos'
check_contains "survey: the rest processed" '1 deployment(s) in 1 parallel job(s): cdm-va'

survey_answers "$WORK_DIR/survey-all-plus.json" all cdm-va --
run_pb survey_all_plus -e "@$WORK_DIR/survey-all-plus.json"
check_rc "survey: 'all' ticked with a deployment" 0

# ==========================================================================
printf '\nTest: no credentials in any output\n'
api_key_b64="$(printf '%s' 'test-key-id:test-key-secret' | base64)"
leaks="$(grep -l -F -e "$api_key_b64" -e 'test-key-secret' "$WORK_DIR"/*.out "$TARGET"/logs/*.log "$TARGET"/reports/*.csv 2>/dev/null || true)"
OUT=""
if [[ -z "$leaks" ]]; then pass "API key never appears in playbook output, logs or reports"; else fail "API key leaked into: $leaks"; fi

# ==========================================================================
printf '\n'
if ((FAILURES == 0)); then
    printf '\033[32mAll %d playbook checks passed.\033[0m\n' "$CHECKS"
else
    printf '\033[31m%d of %d playbook check(s) failed.\033[0m\n' "$FAILURES" "$CHECKS"
    exit 1
fi
