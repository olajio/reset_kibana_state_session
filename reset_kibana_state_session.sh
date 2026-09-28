#!/usr/bin/env bash
#
# reset_kibana_state_session.sh
#
# Resets the Kibana advanced setting `state:storeInSessionStorage` to false
# (its default) in EVERY space of EVERY deployment listed in deployments.txt,
# or of the deployments passed as arguments.
#
# Why: when `state:storeInSessionStorage` is true, Kibana keeps global app
# state in browser sessionStorage and puts only a short hash in the URL
# (e.g. `?_g=h@8c48049`). After a cluster change or upgrade those
# sessionStorage entries go stale, the hash can no longer be resolved, and
# Kibana shows:
#
#     "Unable to completely restore the URL, be sure to use the share
#      functionality."
#
# Setting it back to false makes Kibana put the full state in the URL again.
#
# Kibana credentials are read per deployment from AWS Secrets Manager:
#   cdm-fed        -> federal_store
#   cdm-<agency>   -> agency_<agency>_store
#
# Usage: see --help.

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SETTING_KEY='state:storeInSessionStorage'

# Placeholders recognised in the *_TEMPLATE settings below. Kept in variables so
# the braces stay literal in ${var//pattern/replacement}.
readonly PH_AGENCY='{{agency}}'
readonly PH_DEPLOYMENT='{{deployment}}'

# --------------------------------------------------------------------------
# Defaults (most can be overridden by flags or environment variables)
# --------------------------------------------------------------------------
DEPLOYMENTS_FILE="${DEPLOYMENTS_FILE:-deployments.txt}"
DRY_RUN=false
RESET_TO_DEFAULT=false
FORCE=false
ASSUME_YES=false
VERBOSE=false
HTTP_TIMEOUT="${HTTP_TIMEOUT:-30}"
HTTP_RETRIES="${HTTP_RETRIES:-3}"
RETRY_BACKOFF="${RETRY_BACKOFF:-2}"
INSECURE=false
CA_BUNDLE="${CA_BUNDLE:-}"
REPORT_CSV=""
SPACE_INCLUDE=""
SPACE_EXCLUDE=""

# AWS passthrough
AWS_PROFILE_OPT="${AWS_PROFILE_OPT:-}"
AWS_REGION_OPT="${AWS_REGION_OPT:-}"

# Secret naming
FED_DEPLOYMENT="${FED_DEPLOYMENT:-cdm-fed}"
FED_SECRET_NAME="${FED_SECRET_NAME:-federal_store}"
AGENCY_SECRET_TEMPLATE="${AGENCY_SECRET_TEMPLATE:-agency_${PH_AGENCY}_store}"
# Rendered form of the template above, used in --help.
AGENCY_SECRET_EXAMPLE="${AGENCY_SECRET_TEMPLATE//$PH_AGENCY/<agency>}"

# Which JSON keys inside the secret hold what. Each is a space separated list
# of candidates, tried in order; the first one present and non-empty wins.
SECRET_KEYS_URL="${SECRET_KEYS_URL:-kibana_url KIBANA_URL kibanaUrl kibana_endpoint kibana_host kibana_uri kibana url endpoint}"
SECRET_KEYS_USERNAME="${SECRET_KEYS_USERNAME:-kibana_username KIBANA_USERNAME kibanaUsername kibana_user elastic_username elasticsearch_username username user}"
SECRET_KEYS_PASSWORD="${SECRET_KEYS_PASSWORD:-kibana_password KIBANA_PASSWORD kibanaPassword kibana_pass elastic_password elasticsearch_password password pass}"
SECRET_KEYS_API_KEY="${SECRET_KEYS_API_KEY:-kibana_api_key KIBANA_API_KEY kibanaApiKey api_key apiKey}"

# Optional fallback when the secret carries no Kibana URL.
# Placeholders: {{deployment}} {{agency}}
KIBANA_URL_TEMPLATE="${KIBANA_URL_TEMPLATE:-}"

# --------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
    C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_DIM=''; C_BOLD=''
fi

_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log_info()  { printf '%s[%s] %s%s\n' "$C_BLUE"   "$(_ts)" "$*" "$C_RESET" >&2; }
log_ok()    { printf '%s[%s] %s%s\n' "$C_GREEN"  "$(_ts)" "$*" "$C_RESET" >&2; }
log_warn()  { printf '%s[%s] WARN: %s%s\n' "$C_YELLOW" "$(_ts)" "$*" "$C_RESET" >&2; }
log_error() { printf '%s[%s] ERROR: %s%s\n' "$C_RED" "$(_ts)" "$*" "$C_RESET" >&2; }
log_debug() { [[ "$VERBOSE" == true ]] && printf '%s[%s] DEBUG: %s%s\n' "$C_DIM" "$(_ts)" "$*" "$C_RESET" >&2 || true; }
die()       { log_error "$*"; exit 1; }

usage() {
    cat <<HELP_EOF
${C_BOLD}${SCRIPT_NAME}${C_RESET} - reset Kibana's ${SETTING_KEY} across deployments and spaces

USAGE
    ${SCRIPT_NAME} [OPTIONS] [DEPLOYMENT ...]

With no DEPLOYMENT arguments, every deployment in ${DEPLOYMENTS_FILE} is
processed. Otherwise only the deployments named on the command line are.

For each deployment the script:
  1. derives the AWS Secrets Manager secret name
     (${FED_DEPLOYMENT} -> ${FED_SECRET_NAME}, cdm-<agency> -> ${AGENCY_SECRET_EXAMPLE}),
  2. reads the Kibana URL and credentials from that secret,
  3. lists ALL spaces via GET /api/spaces/space,
  4. sets ${SETTING_KEY} to false in each space via
     POST /s/<space_id>/api/kibana/settings/${SETTING_KEY},
  5. verifies the new value and prints a report.

OPTIONS
    -f, --file PATH        Deployments file (default: ${DEPLOYMENTS_FILE})
    -n, --dry-run          Report what would change; make no changes
        --reset-to-default Send {"value": null} (removes the override, i.e. the
                           UI's "Reset to default") instead of an explicit false
        --force            Write the setting even where it is already false
    -s, --spaces LIST      Only these space ids (comma separated)
    -x, --exclude-spaces LIST
                           Skip these space ids (comma separated)
        --report-csv PATH  Also write the report as CSV
        --profile NAME     AWS CLI profile
        --region NAME      AWS region
        --timeout SECONDS  Per-request timeout (default: ${HTTP_TIMEOUT})
        --retries N        Attempts per request on transport/5xx/429 (default: ${HTTP_RETRIES})
        --ca-bundle PATH   CA bundle for Kibana TLS verification
        --insecure         Skip Kibana TLS verification (last resort)
    -y, --yes              Do not prompt for confirmation
    -v, --verbose          Verbose logging
    -h, --help             This help

ENVIRONMENT
    KIBANA_URL_TEMPLATE    Fallback URL when the secret has none, e.g.
                           'https://kibana.{{deployment}}.example.com'
    SECRET_KEYS_URL, SECRET_KEYS_USERNAME, SECRET_KEYS_PASSWORD,
    SECRET_KEYS_API_KEY    Candidate JSON keys inside each secret
    FED_SECRET_NAME, AGENCY_SECRET_TEMPLATE, FED_DEPLOYMENT
                           Override the secret naming scheme
    NO_COLOR               Disable coloured output

EXIT STATUS
    0  every targeted space ended up with ${SETTING_KEY} = false
    1  at least one deployment or space failed
    2  usage error

EXAMPLES
    ${SCRIPT_NAME} --dry-run
    ${SCRIPT_NAME} cdm-va cdm-fed
    ${SCRIPT_NAME} --report-csv /tmp/reset-report.csv --yes
    ${SCRIPT_NAME} --spaces default,master cdm-dos
HELP_EOF
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
declare -a CLI_DEPLOYMENTS=()

while (($#)); do
    case "$1" in
        -f|--file)             [[ $# -ge 2 ]] || die "$1 needs a value"; DEPLOYMENTS_FILE="$2"; shift 2 ;;
        -n|--dry-run)          DRY_RUN=true; shift ;;
        --reset-to-default)    RESET_TO_DEFAULT=true; shift ;;
        --force)               FORCE=true; shift ;;
        -s|--spaces)           [[ $# -ge 2 ]] || die "$1 needs a value"; SPACE_INCLUDE="$2"; shift 2 ;;
        -x|--exclude-spaces)   [[ $# -ge 2 ]] || die "$1 needs a value"; SPACE_EXCLUDE="$2"; shift 2 ;;
        --report-csv)          [[ $# -ge 2 ]] || die "$1 needs a value"; REPORT_CSV="$2"; shift 2 ;;
        --profile)             [[ $# -ge 2 ]] || die "$1 needs a value"; AWS_PROFILE_OPT="$2"; shift 2 ;;
        --region)              [[ $# -ge 2 ]] || die "$1 needs a value"; AWS_REGION_OPT="$2"; shift 2 ;;
        --timeout)             [[ $# -ge 2 ]] || die "$1 needs a value"; HTTP_TIMEOUT="$2"; shift 2 ;;
        --retries)             [[ $# -ge 2 ]] || die "$1 needs a value"; HTTP_RETRIES="$2"; shift 2 ;;
        --ca-bundle)           [[ $# -ge 2 ]] || die "$1 needs a value"; CA_BUNDLE="$2"; shift 2 ;;
        --insecure)            INSECURE=true; shift ;;
        -y|--yes)              ASSUME_YES=true; shift ;;
        -v|--verbose)          VERBOSE=true; shift ;;
        -h|--help)             usage; exit 0 ;;
        --)                    shift; while (($#)); do CLI_DEPLOYMENTS+=("$1"); shift; done ;;
        -*)                    usage >&2; echo >&2; log_error "unknown option: $1"; exit 2 ;;
        *)                     CLI_DEPLOYMENTS+=("$1"); shift ;;
    esac
done

[[ "$HTTP_TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be an integer"
[[ "$HTTP_RETRIES" =~ ^[0-9]+$ && "$HTTP_RETRIES" -ge 1 ]] || die "--retries must be an integer >= 1"
[[ -z "$CA_BUNDLE" || -r "$CA_BUNDLE" ]] || die "CA bundle not readable: $CA_BUNDLE"

# --------------------------------------------------------------------------
# Dependencies and scratch space
# --------------------------------------------------------------------------
for dep in curl jq aws; do
    command -v "$dep" >/dev/null 2>&1 || die "required command not found: $dep"
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reset-kibana-state.XXXXXX")"
chmod 700 "$TMP_DIR"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

readonly BODY_FILE="$TMP_DIR/body"
readonly ERR_FILE="$TMP_DIR/err"
readonly PAYLOAD_FILE="$TMP_DIR/payload.json"
readonly CURL_CFG="$TMP_DIR/curl.cfg"
readonly REPORT_TSV="$TMP_DIR/report.tsv"
: > "$REPORT_TSV"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

# Escape a value for use inside a curl config file double-quoted string.
curl_cfg_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

in_csv_list() {  # in_csv_list <needle> <comma,separated,list>
    local needle="$1" list="$2" item
    local IFS=','
    for item in $list; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# Report rows: deployment, space id, space name, value before, action, detail
add_report_row() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$REPORT_TSV"
}

secret_name_for() {  # secret_name_for <deployment>
    local deployment="$1" agency
    if [[ "$deployment" == "$FED_DEPLOYMENT" ]]; then
        printf '%s' "$FED_SECRET_NAME"
        return 0
    fi
    if [[ "$deployment" == cdm-* ]]; then
        agency="${deployment#cdm-}"
    else
        agency="$deployment"
        log_debug "$deployment does not use the cdm-<agency> form; treating '$agency' as the agency"
    fi
    [[ -n "$agency" ]] || return 1
    printf '%s' "${AGENCY_SECRET_TEMPLATE//$PH_AGENCY/$agency}"
}

# Pick the first present, non-empty, scalar value among candidate keys.
json_pick() {  # json_pick <json> <candidate keys...>
    local json="$1"; shift
    jq -r --args '
        . as $o
        | first(
            $ARGS.positional[]
            | . as $k
            | select($o | has($k))
            | $o[$k]
            | select(type != "null" and type != "object" and type != "array")
            | tostring
            | select(length > 0)
          ) // empty
    ' <<<"$json" -- "$@" 2>/dev/null | head -n 1
}

# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------
# Sets KB_HTTP_CODE / KB_BODY / KB_ERR. Returns 0 only on a 2xx response.
kb_request() {  # kb_request <method> <path> [json payload]
    local method="$1" path="$2" payload="${3-}"
    local url="${KB_URL%/}${path}"
    local attempt=1 code=''

    KB_HTTP_CODE=''; KB_BODY=''; KB_ERR=''

    while :; do
        local -a args=(
            --silent --show-error --location
            --max-time "$HTTP_TIMEOUT"
            --config "$CURL_CFG"
            --request "$method"
            --header 'kbn-xsrf: true'
            --output "$BODY_FILE"
            --write-out '%{http_code}'
        )
        if [[ -n "$CA_BUNDLE" ]]; then args+=(--cacert "$CA_BUNDLE"); fi
        if [[ "$INSECURE" == true ]]; then args+=(--insecure); fi
        if [[ -n "$payload" ]]; then
            printf '%s' "$payload" > "$PAYLOAD_FILE"
            args+=(--header 'Content-Type: application/json' --data-binary "@$PAYLOAD_FILE")
        fi

        : > "$BODY_FILE"; : > "$ERR_FILE"
        if ! code="$(curl "${args[@]}" "$url" 2>"$ERR_FILE")"; then
            code=''
        fi

        KB_HTTP_CODE="$code"
        KB_BODY="$(cat "$BODY_FILE" 2>/dev/null || true)"
        KB_ERR="$(tr '\n' ' ' < "$ERR_FILE" 2>/dev/null || true)"

        log_debug "$method $url -> ${code:-<no response>}"

        if [[ -n "$code" ]] && ((code >= 200 && code < 300)); then
            return 0
        fi

        if ((attempt < HTTP_RETRIES)) &&
           { [[ -z "$code" ]] || ((code == 429 || code >= 500)); }; then
            local wait=$((RETRY_BACKOFF * attempt))
            log_warn "$method $path failed (${code:-transport error}); retry $((attempt + 1))/$HTTP_RETRIES in ${wait}s"
            sleep "$wait"
            attempt=$((attempt + 1))
            continue
        fi
        return 1
    done
}

# Short, single-line error description for the report.
kb_error_detail() {
    local msg
    msg="$(jq -r '(.message // .error.reason // .error // empty)' <<<"$KB_BODY" 2>/dev/null || true)"
    [[ -z "$msg" ]] && msg="$(printf '%s' "$KB_BODY" | tr '\n' ' ' | cut -c1-160)"
    [[ -z "$msg" ]] && msg="$KB_ERR"
    printf 'HTTP %s: %s' "${KB_HTTP_CODE:-none}" "${msg:-no response body}"
}

# --------------------------------------------------------------------------
# Secrets
# --------------------------------------------------------------------------
# Sets KB_URL, KB_USER, KB_PASS, KB_API_KEY and writes the curl auth config.
load_deployment_credentials() {  # load_deployment_credentials <deployment> <secret name>
    local deployment="$1" secret_name="$2" secret_json=''
    local -a aws_args=(secretsmanager get-secret-value --secret-id "$secret_name"
                       --query SecretString --output text)
    if [[ -n "$AWS_PROFILE_OPT" ]]; then aws_args+=(--profile "$AWS_PROFILE_OPT"); fi
    if [[ -n "$AWS_REGION_OPT"  ]]; then aws_args+=(--region  "$AWS_REGION_OPT");  fi

    KB_URL=''; KB_USER=''; KB_PASS=''; KB_API_KEY=''

    log_debug "reading secret '$secret_name' for $deployment"
    if ! secret_json="$(aws "${aws_args[@]}" 2>"$ERR_FILE")"; then
        CRED_ERROR="aws secretsmanager get-secret-value failed for '$secret_name': $(tr '\n' ' ' < "$ERR_FILE" | cut -c1-200)"
        return 1
    fi
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$secret_json"; then
        CRED_ERROR="secret '$secret_name' is not a JSON object"
        return 1
    fi

    KB_URL="$(json_pick "$secret_json" $SECRET_KEYS_URL)"
    KB_USER="$(json_pick "$secret_json" $SECRET_KEYS_USERNAME)"
    KB_PASS="$(json_pick "$secret_json" $SECRET_KEYS_PASSWORD)"
    KB_API_KEY="$(json_pick "$secret_json" $SECRET_KEYS_API_KEY)"
    secret_json=''

    if [[ -z "$KB_URL" && -n "$KIBANA_URL_TEMPLATE" ]]; then
        local agency="${deployment#cdm-}"
        KB_URL="${KIBANA_URL_TEMPLATE//$PH_DEPLOYMENT/$deployment}"
        KB_URL="${KB_URL//$PH_AGENCY/$agency}"
        log_debug "no URL in secret; using template -> $KB_URL"
    fi
    if [[ -z "$KB_URL" ]]; then
        CRED_ERROR="no Kibana URL in secret '$secret_name' (tried: $SECRET_KEYS_URL) and KIBANA_URL_TEMPLATE is unset"
        return 1
    fi
    [[ "$KB_URL" == http://* || "$KB_URL" == https://* ]] || KB_URL="https://$KB_URL"

    if [[ -z "$KB_API_KEY" && ( -z "$KB_USER" || -z "$KB_PASS" ) ]]; then
        CRED_ERROR="no usable credentials in secret '$secret_name' (need an API key, or a username and password)"
        return 1
    fi

    : > "$CURL_CFG"
    chmod 600 "$CURL_CFG"
    if [[ -n "$KB_API_KEY" ]]; then
        printf 'header = "Authorization: ApiKey %s"\n' "$(curl_cfg_escape "$KB_API_KEY")" >> "$CURL_CFG"
        log_debug "authenticating to $KB_URL with an API key"
    else
        printf 'user = "%s:%s"\n' "$(curl_cfg_escape "$KB_USER")" "$(curl_cfg_escape "$KB_PASS")" >> "$CURL_CFG"
        log_debug "authenticating to $KB_URL as '$KB_USER'"
    fi
}

# --------------------------------------------------------------------------
# Kibana operations
# --------------------------------------------------------------------------
space_path_prefix() {  # default space has no /s/<id> prefix
    if [[ "$1" == "default" ]]; then printf ''; else printf '/s/%s' "$1"; fi
}

# Echoes "<id>\t<name>" per space.
list_spaces() {
    if ! kb_request GET /api/spaces/space; then
        if [[ "$KB_HTTP_CODE" == "404" ]]; then
            log_warn "spaces API not available (404); assuming a single 'default' space"
            printf 'default\tDefault\n'
            return 0
        fi
        return 1
    fi
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$KB_BODY"; then
        KB_ERR='unexpected response from /api/spaces/space'
        return 1
    fi
    jq -r '.[] | [(.id // "default"), (.name // .id // "default")] | @tsv' <<<"$KB_BODY"
}

# Reads the setting into SETTING_VALUE (empty when there is no override).
# Sets a global rather than echoing so that the KB_* diagnostics from the
# request survive for the caller's error reporting.
SETTING_VALUE=''
read_setting_value() {  # read_setting_value <space id>
    local prefix; prefix="$(space_path_prefix "$1")"
    SETTING_VALUE=''
    kb_request GET "${prefix}/api/kibana/settings" || return 1
    # Not `.userValue // empty`: jq's // treats an explicit false as absent,
    # which is exactly the value this script cares about.
    SETTING_VALUE="$(jq -r --arg k "$SETTING_KEY" '
        (.settings // {}) as $s
        | if ($s | has($k)) and (($s[$k] // {}) | type == "object") and ($s[$k] | has("userValue"))
          then ($s[$k].userValue | tostring)
          else ""
          end
    ' <<<"$KB_BODY")"
}

set_setting_false() {  # set_setting_false <space id>
    local prefix payload
    prefix="$(space_path_prefix "$1")"
    if [[ "$RESET_TO_DEFAULT" == true ]]; then
        payload='{"value":null}'
    else
        payload='{"value":false}'
    fi
    kb_request POST "${prefix}/api/kibana/settings/${SETTING_KEY}" "$payload"
}

# --------------------------------------------------------------------------
# Per-deployment / per-space work
# --------------------------------------------------------------------------
COUNT_RESET=0
COUNT_ALREADY=0
COUNT_WOULD=0
COUNT_SKIPPED=0
COUNT_FAILED=0
COUNT_DEPLOYMENTS_OK=0
COUNT_DEPLOYMENTS_FAILED=0

process_space() {  # process_space <deployment> <space id> <space name>
    local deployment="$1" space_id="$2" space_name="$3" before='' after='' detail=''

    if [[ -n "$SPACE_INCLUDE" ]] && ! in_csv_list "$space_id" "$SPACE_INCLUDE"; then
        log_debug "$deployment/$space_id: not in --spaces; skipping"
        add_report_row "$deployment" "$space_id" "$space_name" '-' 'skipped' 'not selected by --spaces'
        COUNT_SKIPPED=$((COUNT_SKIPPED + 1)); return 0
    fi
    if [[ -n "$SPACE_EXCLUDE" ]] && in_csv_list "$space_id" "$SPACE_EXCLUDE"; then
        log_debug "$deployment/$space_id: excluded; skipping"
        add_report_row "$deployment" "$space_id" "$space_name" '-' 'skipped' 'excluded by --exclude-spaces'
        COUNT_SKIPPED=$((COUNT_SKIPPED + 1)); return 0
    fi

    if ! read_setting_value "$space_id"; then
        detail="$(kb_error_detail)"
        log_error "$deployment/$space_id: could not read settings - $detail"
        add_report_row "$deployment" "$space_id" "$space_name" '?' 'failed' "read settings: $detail"
        COUNT_FAILED=$((COUNT_FAILED + 1)); return 1
    fi
    before="${SETTING_VALUE:-unset(default false)}"

    if [[ "$FORCE" != true && ( "$before" == 'false' || "$before" == 'unset(default false)' ) ]]; then
        log_info "$deployment/$space_id: already false ($before); nothing to do"
        add_report_row "$deployment" "$space_id" "$space_name" "$before" 'already-false' 'no change needed'
        COUNT_ALREADY=$((COUNT_ALREADY + 1)); return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_warn "$deployment/$space_id: DRY RUN - would set $SETTING_KEY to false (currently $before)"
        add_report_row "$deployment" "$space_id" "$space_name" "$before" 'would-reset' 'dry run; no change made'
        COUNT_WOULD=$((COUNT_WOULD + 1)); return 0
    fi

    if ! set_setting_false "$space_id"; then
        detail="$(kb_error_detail)"
        log_error "$deployment/$space_id: could not write setting - $detail"
        add_report_row "$deployment" "$space_id" "$space_name" "$before" 'failed' "write setting: $detail"
        COUNT_FAILED=$((COUNT_FAILED + 1)); return 1
    fi

    if ! read_setting_value "$space_id"; then
        log_warn "$deployment/$space_id: setting written but verification failed - $(kb_error_detail)"
        add_report_row "$deployment" "$space_id" "$space_name" "$before" 'reset-unverified' 'write succeeded; re-read failed'
        COUNT_RESET=$((COUNT_RESET + 1)); return 0
    fi
    after="${SETTING_VALUE:-unset(default false)}"

    if [[ "$after" == 'false' || "$after" == 'unset(default false)' ]]; then
        log_ok "$deployment/$space_id: $SETTING_KEY reset ($before -> $after)"
        add_report_row "$deployment" "$space_id" "$space_name" "$before" 'reset' "now $after"
        COUNT_RESET=$((COUNT_RESET + 1)); return 0
    fi

    log_error "$deployment/$space_id: setting still $after after the write"
    add_report_row "$deployment" "$space_id" "$space_name" "$before" 'failed' "value is still $after after write"
    COUNT_FAILED=$((COUNT_FAILED + 1)); return 1
}

process_deployment() {  # process_deployment <deployment>
    local deployment="$1" secret_name='' space_id space_name detail=''
    local deployment_failed=false space_count=0

    printf '\n%s=== %s ===%s\n' "$C_BOLD" "$deployment" "$C_RESET" >&2

    if ! secret_name="$(secret_name_for "$deployment")"; then
        log_error "$deployment: cannot derive a secret name"
        add_report_row "$deployment" '-' '-' '-' 'failed' 'cannot derive secret name'
        COUNT_FAILED=$((COUNT_FAILED + 1))
        COUNT_DEPLOYMENTS_FAILED=$((COUNT_DEPLOYMENTS_FAILED + 1))
        return 1
    fi
    log_info "$deployment: secret '$secret_name'"

    CRED_ERROR=''
    if ! load_deployment_credentials "$deployment" "$secret_name"; then
        log_error "$deployment: $CRED_ERROR"
        add_report_row "$deployment" '-' '-' '-' 'failed' "$CRED_ERROR"
        COUNT_FAILED=$((COUNT_FAILED + 1))
        COUNT_DEPLOYMENTS_FAILED=$((COUNT_DEPLOYMENTS_FAILED + 1))
        return 1
    fi
    log_info "$deployment: Kibana at $KB_URL"

    local spaces_file="$TMP_DIR/spaces.tsv"
    if ! list_spaces > "$spaces_file"; then
        detail="$(kb_error_detail)"
        log_error "$deployment: could not list spaces - $detail"
        add_report_row "$deployment" '-' '-' '-' 'failed' "list spaces: $detail"
        COUNT_FAILED=$((COUNT_FAILED + 1))
        COUNT_DEPLOYMENTS_FAILED=$((COUNT_DEPLOYMENTS_FAILED + 1))
        return 1
    fi

    while IFS=$'\t' read -r space_id space_name; do
        [[ -n "$space_id" ]] || continue
        space_count=$((space_count + 1))
        process_space "$deployment" "$space_id" "${space_name:-$space_id}" || deployment_failed=true
    done < "$spaces_file"

    if ((space_count == 0)); then
        log_warn "$deployment: no spaces returned"
        add_report_row "$deployment" '-' '-' '-' 'skipped' 'no spaces returned'
        COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
    fi
    log_info "$deployment: $space_count space(s) processed"

    if [[ "$deployment_failed" == true ]]; then
        COUNT_DEPLOYMENTS_FAILED=$((COUNT_DEPLOYMENTS_FAILED + 1))
        return 1
    fi
    COUNT_DEPLOYMENTS_OK=$((COUNT_DEPLOYMENTS_OK + 1))
    return 0
}

# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------
csv_field() {
    printf '"%s"' "${1//\"/\"\"}"
}

write_csv_report() {
    local out="$1" d s n b a det
    {
        printf 'deployment,space_id,space_name,value_before,action,detail\n'
        while IFS=$'\t' read -r d s n b a det; do
            printf '%s,%s,%s,%s,%s,%s\n' \
                "$(csv_field "$d")" "$(csv_field "$s")" "$(csv_field "$n")" \
                "$(csv_field "$b")" "$(csv_field "$a")" "$(csv_field "$det")"
        done < "$REPORT_TSV"
    } > "$out"
    log_info "CSV report written to $out"
}

print_report() {
    local total
    total="$(wc -l < "$REPORT_TSV" | tr -d ' ')"

    printf '\n%s%s\n' "$C_BOLD" '================================================================'
    printf ' REPORT - %s\n' "$SETTING_KEY"
    printf '%s%s\n\n' '================================================================' "$C_RESET"

    if ((total == 0)); then
        printf 'No deployments or spaces were processed.\n'
        return 0
    fi

    {
        printf 'DEPLOYMENT\tSPACE_ID\tSPACE_NAME\tBEFORE\tACTION\tDETAIL\n'
        cat "$REPORT_TSV"
    } | if command -v column >/dev/null 2>&1; then
            column -t -s $'\t'
        else
            awk -F'\t' '{printf "%-16s %-18s %-22s %-22s %-18s %s\n", $1, $2, $3, $4, $5, $6}'
        fi

    printf '\n%sSummary%s\n' "$C_BOLD" "$C_RESET"
    printf '  deployments succeeded : %d\n' "$COUNT_DEPLOYMENTS_OK"
    printf '  deployments failed    : %d\n' "$COUNT_DEPLOYMENTS_FAILED"
    printf '  spaces reset to false : %d\n' "$COUNT_RESET"
    printf '  spaces already false  : %d\n' "$COUNT_ALREADY"
    if [[ "$DRY_RUN" == true ]]; then
        printf '  spaces needing reset  : %d  (dry run - nothing was changed)\n' "$COUNT_WOULD"
    fi
    printf '  spaces skipped        : %d\n' "$COUNT_SKIPPED"
    printf '  failures              : %d\n' "$COUNT_FAILED"

    if [[ -n "$REPORT_CSV" ]]; then write_csv_report "$REPORT_CSV"; fi
    return 0
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
declare -a DEPLOYMENTS=()

if ((${#CLI_DEPLOYMENTS[@]} > 0)); then
    DEPLOYMENTS=("${CLI_DEPLOYMENTS[@]}")
    log_info "using ${#DEPLOYMENTS[@]} deployment(s) from the command line"
else
    [[ -r "$DEPLOYMENTS_FILE" ]] || die "deployments file not readable: $DEPLOYMENTS_FILE (pass deployments as arguments or use --file)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                                  # strip comments
        line="${line//$'\r'/}"                              # strip CR
        line="${line#"${line%%[![:space:]]*}"}"             # ltrim
        line="${line%"${line##*[![:space:]]}"}"             # rtrim
        [[ -n "$line" ]] || continue
        DEPLOYMENTS+=("$line")
    done < "$DEPLOYMENTS_FILE"
    ((${#DEPLOYMENTS[@]} > 0)) || die "no deployments found in $DEPLOYMENTS_FILE"
    log_info "read ${#DEPLOYMENTS[@]} deployment(s) from $DEPLOYMENTS_FILE"
fi

if [[ "$INSECURE" == true ]]; then
    log_warn "--insecure: Kibana TLS certificates will NOT be verified"
fi

if [[ "$DRY_RUN" != true && "$ASSUME_YES" != true && -t 0 ]]; then
    printf '\n' >&2
    if [[ "$RESET_TO_DEFAULT" == true ]]; then
        log_warn "about to RESET $SETTING_KEY to its default in every space of ${#DEPLOYMENTS[@]} deployment(s)"
    else
        log_warn "about to SET $SETTING_KEY to false in every space of ${#DEPLOYMENTS[@]} deployment(s)"
    fi
    read -r -p "Continue? [y/N] " reply
    [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]] || die "aborted by user"
fi

EXIT_CODE=0
for deployment in "${DEPLOYMENTS[@]}"; do
    process_deployment "$deployment" || EXIT_CODE=1
done

print_report

if ((EXIT_CODE == 0)); then
    log_ok "done - no failures"
else
    log_error "done - some deployments or spaces failed (see the report above)"
fi
exit "$EXIT_CODE"
