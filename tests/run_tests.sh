#!/usr/bin/env bash
#
# End-to-end checks for reset_kibana_state_session.sh against a mock Kibana and
# a stub `aws secretsmanager get-secret-value`. No real AWS or Kibana needed.
#
#   ./tests/run_tests.sh
#
# To test against a particular jq (the script supports jq 1.5 and later), put
# its directory first on the PATH used by the script:
#
#   JQ_BIN_DIR=/path/to/jq-1.5 ./tests/run_tests.sh

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
SCRIPT="$REPO_DIR/reset_kibana_state_session.sh"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reset-kibana-tests.XXXXXX")"
MOCK_PID=""
FAILURES=0
CHECKS=0
RC=0
OUT=""

cleanup() {
    if [[ -n "$MOCK_PID" ]]; then kill "$MOCK_PID" 2>/dev/null || true; fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

pass() { CHECKS=$((CHECKS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() {
    CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1))
    printf '  \033[31mFAIL\033[0m %s\n' "$1"
    if [[ -n "$OUT" && -f "$OUT" ]]; then
        printf '    --- output ---\n'; sed 's/^/    /' "$OUT"
    fi
}

# run_cmd <label> <command...>: run a command, keeping its output in OUT and its
# exit status in RC, without letting set -e stop the suite.
run_cmd() {
    local label="$1"; shift
    OUT="$WORK_DIR/$label.out"
    set +e
    "$@" > "$OUT" 2>&1
    RC=$?
    set -e
}
run() { local label="$1"; shift; run_cmd "$label" "$SCRIPT" "$@"; }

check_rc()       { if [[ "$RC" == "$2" ]]; then pass "$1"; else fail "$1 (exit $RC, expected $2)"; fi; }
check_contains() { if grep -Fq -- "$2" "$OUT"; then pass "$1"; else fail "$1 (expected to find: $2)"; fi; }
check_absent()   { if grep -Fq -- "$2" "$OUT"; then fail "$1 (did not expect: $2)"; else pass "$1"; fi; }

# run_tty <label> <answer> <args...>: run the script on a pseudo-terminal (so it
# is "interactive") and type <answer> at its confirmation prompt. <answer> is
# a Python bytes literal body, e.g. 'n\n' or '\x04' for Ctrl-D.
run_tty() {
    local label="$1" answer="$2"; shift 2
    run_cmd "$label" env ANSWER="$answer" python3 - "$SCRIPT" "$@" <<'PY_TTY'
import ast, os, pty, select, sys
answer = ast.literal_eval("b'" + os.environ["ANSWER"] + "'")
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
out, sent = b"", False
while True:
    ready, _, _ = select.select([fd], [], [], 20)
    if not ready:
        break
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    out += data
    if not sent and b"Continue? [y/N]" in out:
        os.write(fd, answer)
        sent = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace"))
sys.stdout.write("\n[prompt answered: %s]\n" % sent)
sys.exit(os.waitstatus_to_exitcode(status))
PY_TTY
}

aws_call_count() { if [[ -f "$WORK_DIR/aws-calls.log" ]]; then wc -l < "$WORK_DIR/aws-calls.log" | tr -d ' '; else echo 0; fi; }

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
printf 'Mock Kibana on %s\n' "$KIBANA_BASE"

# --------------------------------------------------------------------------
# Secrets, and a stub `aws` on PATH that serves them
# --------------------------------------------------------------------------
export SECRETS_DIR="$WORK_DIR/secrets"
mkdir -p "$SECRETS_DIR" "$WORK_DIR/bin"
python3 - "$SECRETS_DIR" "$KIBANA_BASE" <<'PY'
import base64, json, os, sys
out, base = sys.argv[1], sys.argv[2]
user, password = "kibana_admin", 'p@ss"w\\ord'
api_key = base64.b64encode(b"test-key-id:test-key-secret").decode()
basic = {"kibana_username": user, "kibana_password": password}
secrets = {
    "federal_store":         {"kibana_url": base, **basic},
    "agency_va_store":       {"kibana_url": base, **basic},
    "agency_dos_store":      {"kibana_url": base, **basic},
    # The real deployment secret schema: kibana_url + awx_manage_kibana_api_key.
    "agency_apikey_store":   {"kibana_url": base, "awx_manage_kibana_api_key": api_key},
    # API key alongside unrelated, wrong username/password: the key must win.
    "agency_apiprio_store":  {"kibana_url": base, "awx_manage_kibana_api_key": api_key,
                              "username": "someone-else", "password": "not-the-kibana-one"},
    # Older key name, still accepted as a fallback.
    "agency_legacykey_store": {"kibana_url": base, "kibana_api_key": api_key},
    "agency_bogus_store":    {"kibana_url": base + "/bogus", **basic},
    "agency_html_store":     {"kibana_url": base + "/html", **basic},
    "agency_redirect_store": {"kibana_url": base + "/redirect", **basic},
    "agency_spacey_store":   {"kibana_url": "  " + base + "/ \n", **basic},
    "agency_badurl_store":   {"kibana_url": "not a url", **basic},
    "agency_broken_store":   {"kibana_username": user, "kibana_password": "nope"},
    "agency_custkeys_store": {"kbn_endpoint": base, "svc_user": user, "svc_pw": password},
}
for name, value in secrets.items():
    with open(os.path.join(out, name + ".json"), "w") as f:
        json.dump(value, f)
PY

cat > "$WORK_DIR/bin/aws" <<'AWS_STUB'
#!/usr/bin/env bash
# Stub for `aws secretsmanager get-secret-value --secret-id NAME ...`.
if [[ -n "${AWS_PAGER-}" ]]; then
    echo "stub: AWS_PAGER should be empty for scripted use, got '$AWS_PAGER'" >&2
    exit 99
fi
secret_id='' prev=''
for arg in "$@"; do
    [[ "$prev" == --secret-id ]] && secret_id="$arg"
    prev="$arg"
done
echo "$secret_id" >> "$SECRETS_DIR/../aws-calls.log"
file="$SECRETS_DIR/$secret_id.json"
if [[ -n "$secret_id" && "$secret_id" != */* && -f "$file" ]]; then
    cat "$file"
else
    echo "An error occurred (ResourceNotFoundException) when calling the GetSecretValue operation: Secrets Manager can't find the specified secret." >&2
    exit 254
fi
AWS_STUB
chmod +x "$WORK_DIR/bin/aws"

export PATH="$WORK_DIR/bin:${JQ_BIN_DIR:+$JQ_BIN_DIR:}$PATH"
export NO_COLOR=1
printf 'Using %s, %s\n\n' "$(jq --version)" "$(bash --version | head -n 1)"

# A deployments file for the `all` tests, kept outside the repo.
cat > "$WORK_DIR/two.txt" <<'LIST'
# comment
cdm-va

cdm-dos   # trailing comment
LIST

# ==========================================================================
printf 'Test: --help\n'
run help --help
check_rc "help exits 0" 0
check_contains "help mentions the setting"            'state:storeInSessionStorage'
check_contains "help renders the agency secret name"  'agency_<agency>_store'
check_contains "help documents the all wildcard"      'Process every deployment listed in the deployments file.'

# ==========================================================================
printf '\nTest: usage errors exit 2 and touch nothing\n'
calls_before="$(aws_call_count)"

run bogus_opt --bogus
check_rc "unknown option exits 2" 2
check_contains "unknown option reported" 'unknown option: --bogus'

run file_noval --file
check_rc "--file with no value exits 2" 2

run timeout_bad --timeout abc all
check_rc "non-numeric --timeout exits 2" 2

run retries_zero --retries 0 all
check_rc "--retries 0 exits 2" 2

run all_mixed --report-csv "$WORK_DIR/must-not-exist.csv" all cdm-va
check_rc "'all' plus a deployment exits 2" 2
check_contains "'all' plus a deployment explained" "cannot be combined with other deployment names"
check_absent  "'all' plus a deployment processes nothing" '==='
if [[ -e "$WORK_DIR/must-not-exist.csv" ]]; then fail "usage error left a CSV behind"; else pass "usage error creates no CSV"; fi

run all_comma all,cdm-va
check_rc "'all,cdm-va' exits 2" 2

run all_twice all ALL
check_rc "'all ALL' exits 2" 2

run empty_arg ''
check_rc "an empty deployment argument exits 2 (does not fall back to every deployment)" 2

run bad_csv --yes --report-csv "$WORK_DIR/no/such/dir/report.csv" cdm-va
check_rc "unwritable --report-csv exits 2 before any work" 2
check_absent "unwritable --report-csv processes nothing" '==='

if [[ "$(aws_call_count)" == "$calls_before" ]]; then pass "no secrets read for any usage error"; else fail "usage errors read secrets"; fi

# ==========================================================================
printf '\nTest: secret name derivation (via a missing secret)\n'
run nope --yes cdm-nope
check_rc "missing secret exits 1" 1
check_contains "cdm-nope -> agency_nope_store" "secret 'agency_nope_store'"

# ==========================================================================
printf '\nTest: dry run changes nothing\n'
run dry --dry-run cdm-va
check_rc "dry run exits 0" 0
check_contains "dry run finds master"           'would-reset'
check_contains "dry run reports default space"  'already-false'
check_contains "dry run mentions cdm-va secret" "secret 'agency_va_store'"
check_absent  "dry run does not claim a reset"  'reset ('

# ==========================================================================
printf '\nTest: real run resets every space\n'
run real --yes --report-csv "$WORK_DIR/report.csv" cdm-va
check_rc "real run exits 0" 0
check_contains "master reset"      'cdm-va/master: state:storeInSessionStorage reset (true -> false)'
check_contains "analytics reset"   'cdm-va/analytics: state:storeInSessionStorage reset (true -> false)'
check_contains "no failures"       'done - no failures'
check_contains "table header"      'DEPLOYMENT  SPACE_ID'
OUT="$WORK_DIR/report.csv"
check_contains "csv header"         'deployment,space_id,space_name,value_before,action,detail'
check_contains "csv row for master" '"cdm-va","master","Master","true","reset","now false"'

# ==========================================================================
printf '\nTest: second run is idempotent\n'
run again --yes cdm-va
check_rc "second run exits 0" 0
check_contains "master already false" 'cdm-va/master: already false'
check_contains "spaces already false: 3" 'spaces already false  : 3'

# ==========================================================================
printf '\nTest: space filters\n'
run filter --yes --spaces master --dry-run cdm-va
check_contains "analytics skipped by --spaces" 'not selected by --spaces'
run exclude --dry-run --exclude-spaces analytics,default cdm-va
check_contains "excluded spaces skipped" 'excluded by --exclude-spaces'
check_contains "master still checked"    'cdm-va/master: already false'

# ==========================================================================
printf '\nTest: "all" processes every deployment in the deployments file\n'
run all_lower --dry-run --file "$WORK_DIR/two.txt" all
check_rc "'all' exits 0" 0
check_contains "'all' reads the file"  "'all': read 2 deployment(s) from $WORK_DIR/two.txt"
check_contains "'all' processes cdm-va" '=== cdm-va ==='
check_contains "'all' processes cdm-dos" '=== cdm-dos ==='

run all_upper --dry-run --file "$WORK_DIR/two.txt" ALL
check_contains "'ALL' is the same wildcard" "'all': read 2 deployment(s)"
run all_mixedcase --dry-run --file "$WORK_DIR/two.txt" All
check_contains "'All' is the same wildcard" "'all': read 2 deployment(s)"
run all_dashdash --dry-run --file "$WORK_DIR/two.txt" -- all
check_contains "'-- all' is the same wildcard" "'all': read 2 deployment(s)"
run_cmd all_envfile env DEPLOYMENTS_FILE="$WORK_DIR/two.txt" "$SCRIPT" --dry-run all
check_contains "DEPLOYMENTS_FILE env is honoured" "read 2 deployment(s) from $WORK_DIR/two.txt"

run noargs --dry-run --file "$WORK_DIR/two.txt"
check_contains "no deployments named also reads the file" "no deployments named; read 2 deployment(s)"

run all_real --yes --report-csv "$WORK_DIR/all.csv" --file "$WORK_DIR/two.txt" all
check_rc "real 'all' run exits 0" 0
check_contains "real 'all' run summary" 'deployments succeeded : 2'

run all_missing --dry-run --file "$WORK_DIR/does-not-exist.txt" all
check_rc "'all' with a missing file exits 1" 1
check_contains "'all' with a missing file explained" 'deployments file not found or not readable'

# ==========================================================================
printf '\nTest: "all" finds deployments.txt next to the script from any directory\n'
mkdir -p "$WORK_DIR/install" "$WORK_DIR/elsewhere" "$WORK_DIR/cwdfile"
cp "$SCRIPT" "$WORK_DIR/install/reset_kibana_state_session.sh"
printf 'cdm-va\n' > "$WORK_DIR/install/deployments.txt"
# shellcheck disable=SC2016  # $1/$2 belong to the inner shell
run_cmd from_elsewhere bash -c 'cd "$1" && "$2" --dry-run all' _ \
    "$WORK_DIR/elsewhere" "$WORK_DIR/install/reset_kibana_state_session.sh"
check_rc "run from another directory exits 0" 0
check_contains "uses deployments.txt beside the script" "read 1 deployment(s) from $WORK_DIR/install/deployments.txt"

printf 'cdm-va\ncdm-dos\n' > "$WORK_DIR/cwdfile/deployments.txt"
# shellcheck disable=SC2016  # $1/$2 belong to the inner shell
run_cmd from_cwd bash -c 'cd "$1" && "$2" --dry-run all' _ \
    "$WORK_DIR/cwdfile" "$WORK_DIR/install/reset_kibana_state_session.sh"
check_contains "deployments.txt in the current directory wins" "read 2 deployment(s) from deployments.txt"

# ==========================================================================
printf '\nTest: deployment list parsing\n'
printf 'cdm-va, cdm-dos\n' > "$WORK_DIR/commas.txt"
run commas_file --dry-run --file "$WORK_DIR/commas.txt" all
check_contains "comma separated file line" "read 2 deployment(s)"
check_contains "comma separated: cdm-dos processed" "secret 'agency_dos_store'"

run commas_cli --dry-run cdm-va,cdm-dos
check_contains "comma separated arguments" "using 2 deployment(s) from the command line"

printf 'cdm-va\r\ncdm-dos\r\n' > "$WORK_DIR/crlf.txt"
run crlf --dry-run --file "$WORK_DIR/crlf.txt" all
check_contains "CRLF file read" "read 2 deployment(s)"
if grep -q $'\r' "$OUT"; then fail "CRLF leaked a carriage return into names"; else pass "no carriage returns in names"; fi

printf 'cdm-va\ncdm-dos\ncdm-va\n' > "$WORK_DIR/dupes.txt"
run dupes --dry-run --file "$WORK_DIR/dupes.txt" all
check_contains "duplicate reported" "duplicate deployment 'cdm-va'"
check_contains "duplicate processed once" "read 2 deployment(s)"

run dupes_cli --dry-run cdm-va cdm-va
check_contains "duplicate argument processed once" "using 1 deployment(s) from the command line"

printf 'all\ncdm-va\n' > "$WORK_DIR/allline.txt"
run allline --dry-run --file "$WORK_DIR/allline.txt" all
check_contains "'all' inside the file is skipped with a warning" "is the command-line wildcard, not a deployment name - skipped"
check_contains "rest of the file still read" "read 1 deployment(s)"
check_absent  "no secret looked up for 'all'" "agency_all_store"

run file_ignored --dry-run --file "$WORK_DIR/two.txt" cdm-va
check_contains "--file with named deployments warns" "is ignored because deployments were named on the command line"
check_contains "named deployment used"                "using 1 deployment(s) from the command line"

# ==========================================================================
printf '\nTest: --exclude-deployments\n'
printf 'cdm-va\ncdm-dos\ncdm-fed\n' > "$WORK_DIR/three.txt"

run excl_all --dry-run --file "$WORK_DIR/three.txt" --exclude-deployments cdm-dos all
check_rc "excluding from 'all' exits 0" 0
check_contains "exclusion announced"          'excluding 1 deployment(s): cdm-dos'
check_contains "remaining count announced"    '2 deployment(s) to process'
check_contains "kept deployment processed"    '=== cdm-va ==='
check_absent   "excluded deployment skipped"  '=== cdm-dos ==='

run excl_commaspace --dry-run --file "$WORK_DIR/three.txt" --exclude-deployments 'cdm-va, cdm-fed' all
check_contains "'a, b' form excludes both"    'excluding 2 deployment(s): cdm-va cdm-fed'
check_contains "only cdm-dos left"            '1 deployment(s) to process'

run excl_comma --dry-run --file "$WORK_DIR/three.txt" --exclude-deployments cdm-va,cdm-fed all
check_contains "'a,b' form excludes both"     'excluding 2 deployment(s): cdm-va cdm-fed'

run excl_named --dry-run --exclude-deployments cdm-va cdm-va cdm-dos
check_rc "excluding from named deployments exits 0" 0
check_contains "named list minus exclusion"   'excluding 1 deployment(s): cdm-va'
check_absent   "excluded named deployment skipped" '=== cdm-va ==='

run excl_unknown --dry-run --file "$WORK_DIR/three.txt" --exclude-deployments cdm-nosuch all
check_rc "unknown exclusion still runs" 0
check_contains "unknown exclusion warned"     "'cdm-nosuch' is not in the deployment list"

calls_before="$(aws_call_count)"
run excl_everything --dry-run --file "$WORK_DIR/three.txt" --exclude-deployments cdm-va,cdm-dos,cdm-fed all
check_rc "excluding everything exits 2" 2
check_contains "excluding everything explained" 'excludes every deployment in the list - nothing to do'
run excl_allword --dry-run --file "$WORK_DIR/three.txt" --exclude-deployments all all
check_rc "excluding 'all' exits 2" 2
run excl_empty --dry-run --exclude-deployments ', ' cdm-va
check_rc "an exclusion naming nothing exits 2" 2
run excl_novalue --dry-run cdm-va --exclude-deployments
check_rc "--exclude-deployments with no value exits 2" 2
if [[ "$(aws_call_count)" == "$calls_before" ]]; then pass "rejected exclusions read no secrets"; else fail "rejected exclusions read secrets"; fi

# ==========================================================================
printf '\nTest: cdm-fed maps to federal_store\n'
run fed --yes --dry-run cdm-fed
check_contains "fed secret name" "secret 'federal_store'"

# ==========================================================================
printf '\nTest: a deployment with an unusable secret fails, later ones still run\n'
run mixed --yes --dry-run cdm-broken cdm-fed
check_rc "mixed run exits 1" 1
check_contains "broken deployment reported" 'no Kibana URL in secret'
check_contains "cdm-fed still processed"    "secret 'federal_store'"

# ==========================================================================
printf '\nTest: Kibana URL and API key read from the secret\n'
run apikey --dry-run cdm-apikey
check_rc "kibana_url + awx_manage_kibana_api_key secret authenticates" 0
check_contains "API key deployment lists all spaces" 'cdm-apikey: 3 space(s) processed'

# --force so the POST really happens (the spaces are already false by now).
run apikey_real --yes --force cdm-apikey
check_rc "writing the setting with awx_manage_kibana_api_key works" 0
check_contains "write via API key verified" 'cdm-apikey/master: state:storeInSessionStorage reset (false -> false)'

run apiprio --dry-run cdm-apiprio
check_rc "API key is used even when username/password are also present" 0

run legacykey --dry-run cdm-legacykey
check_rc "older kibana_api_key name still works as a fallback" 0

run_cmd custkeys env SECRET_KEYS_URL=kbn_endpoint SECRET_KEYS_USERNAME=svc_user SECRET_KEYS_PASSWORD=svc_pw \
    "$SCRIPT" --dry-run cdm-custkeys
check_rc "custom secret key names via SECRET_KEYS_*" 0

run spacey --dry-run cdm-spacey
check_rc "URL with surrounding whitespace is trimmed" 0

run badurl --dry-run cdm-badurl
check_rc "malformed URL fails" 1
check_contains "malformed URL explained" 'is malformed'

# ==========================================================================
printf '\nTest: unexpected Kibana responses fail loudly, never "already-false"\n'
run bogus --dry-run --report-csv "$WORK_DIR/bogus.csv" cdm-bogus
check_rc "{} settings response exits 1" 1
check_contains "{} settings response reported" 'expected a Kibana settings object'
check_absent  "{} settings response not mistaken for already-false" 'already-false'

run html --dry-run --report-csv "$WORK_DIR/html.csv" cdm-html
check_rc "HTML 200 response exits 1" 1
check_contains "HTML 200 response reported" 'expected a Kibana settings object'
check_absent  "HTML 200 response not mistaken for already-false" 'already-false'

run redirect --dry-run cdm-redirect
check_rc "redirect exits 1" 1
check_contains "redirect explained with its target" 'redirected to https://elsewhere.example/api/spaces/space'

for csv in bogus html; do
    if python3 - "$WORK_DIR/$csv.csv" <<'PY'
import csv, sys
rows = list(csv.reader(open(sys.argv[1], newline="")))
ok = len(rows) >= 2 and all(len(r) == 6 and not any(c in f for f in r for c in "\t\r\n") for r in rows)
sys.exit(0 if ok else 1)
PY
    then pass "$csv report CSV keeps 6 single-line columns per row"
    else OUT="$WORK_DIR/$csv.csv"; fail "$csv report CSV is malformed"; fi
done

# ==========================================================================
printf '\nTest: AWS CLI pager is disabled\n'
run_cmd pager env AWS_PAGER=less "$SCRIPT" --dry-run cdm-va
check_rc "runs with AWS_PAGER set in the environment" 0

# ==========================================================================
printf '\nTest: changing settings needs confirmation\n'
calls_before="$(aws_call_count)"
# shellcheck disable=SC2016  # $1/$2 belong to the inner shell
run_cmd noninteractive bash -c '"$1" --report-csv "$2" cdm-va < /dev/null' _ "$SCRIPT" "$WORK_DIR/refused.csv"
check_rc "non-interactive real run without --yes exits 2" 2
check_contains "non-interactive refusal explained" 'pass --yes to change settings'
if [[ "$(aws_call_count)" == "$calls_before" ]]; then pass "refused run read no secrets"; else fail "refused run read secrets"; fi
if [[ -e "$WORK_DIR/refused.csv" ]]; then fail "refused run left a CSV behind"; else pass "refused run creates no CSV"; fi

# shellcheck disable=SC2016  # $1/$2 belong to the inner shell
run_cmd noninteractive_dry bash -c '"$1" --dry-run cdm-va < /dev/null' _ "$SCRIPT"
check_rc "non-interactive --dry-run needs no --yes" 0

run_tty prompt_no 'n\n' cdm-va
check_rc "answering n at the prompt exits 1" 1
check_contains "the prompt was shown" '[prompt answered: True]'
check_contains "answering n aborts" 'aborted by user'
check_absent  "answering n processes nothing" '=== cdm-va ==='

run_tty prompt_eof '\x04' cdm-va
check_rc "Ctrl-D at the prompt exits 1" 1
check_contains "Ctrl-D aborts cleanly" 'aborted by user'

run_tty prompt_yes 'y\n' cdm-va
check_rc "answering y at the prompt proceeds" 0
check_contains "answering y processes the deployment" '=== cdm-va ==='

# ==========================================================================
printf '\nTest: --reset-to-default removes the override\n'
run default --yes --force --reset-to-default cdm-va
check_rc "--reset-to-default exits 0" 0
check_contains "override removed" 'unset(default false)'

# ==========================================================================
printf '\nTest: credentials never appear in any output\n'
api_key_b64="$(printf '%s' 'test-key-id:test-key-secret' | base64)"
leaks="$(grep -l -F -e 'p@ss' -e "$api_key_b64" -e 'test-key-secret' "$WORK_DIR"/*.out "$WORK_DIR"/*.csv 2>/dev/null || true)"
OUT=""
if [[ -z "$leaks" ]]; then pass "no password or API key in any output or report"; else fail "credentials leaked into: $leaks"; fi

# ==========================================================================
printf '\n'
if ((FAILURES == 0)); then
    printf '\033[32mAll %d checks passed.\033[0m\n' "$CHECKS"
else
    printf '\033[31m%d of %d check(s) failed.\033[0m\n' "$FAILURES" "$CHECKS"
    exit 1
fi
