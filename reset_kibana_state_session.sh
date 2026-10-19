#!/usr/bin/env bash
#
# reset_kibana_state_session.sh
#
# Resets the Kibana advanced setting `state:storeInSessionStorage` to false
# (its default) in EVERY space of EVERY deployment listed in deployments.txt
# (pass `all`, or no deployments at all), or of the deployments passed as
# arguments.
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
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SETTING_KEY='state:storeInSessionStorage'

# Control characters, kept in variables so they behave the same in every bash
# version inside ${var//pattern/replacement}.
readonly TAB=$'\t' CR=$'\r' LF=$'\n'

# Placeholders recognised in the *_TEMPLATE settings below. Kept in variables so
# the braces stay literal in ${var//pattern/replacement}.
readonly PH_AGENCY='{{agency}}'
readonly PH_DEPLOYMENT='{{deployment}}'

# --------------------------------------------------------------------------
# Defaults (most can be overridden by flags or environment variables)
# --------------------------------------------------------------------------
# Where deployments come from when none are named, or `all` is given. An
# explicit --file or DEPLOYMENTS_FILE is used exactly as given; otherwise
# deployments.txt is looked for in the current directory, then next to this
# script, so `all` works no matter where the script is run from.
if [[ -n "${DEPLOYMENTS_FILE:-}" ]]; then
    DEPLOYMENTS_FILE_EXPLICIT=true
else
    DEPLOYMENTS_FILE_EXPLICIT=false
fi
DEPLOYMENTS_FILE="${DEPLOYMENTS_FILE:-deployments.txt}"
FILE_FLAG_GIVEN=false

# The deployment-list keyword that means "every deployment in the file".
readonly ALL_KEYWORD='all'

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

# Per-deployment credentials and per-request results (set by the functions
# below; initialised here so `set -u` never trips on them).
KB_URL=''; KB_USER=''; KB_PASS=''; KB_API_KEY=''; CRED_ERROR=''
KB_HTTP_CODE=''; KB_BODY=''; KB_ERR=''; KB_REDIRECT=''; KB_PROBLEM=''

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
usage_error() { log_error "$*"; log_error "see '$SCRIPT_NAME --help'"; exit 2; }

usage() {
    cat <<HELP_EOF
${C_BOLD}${SCRIPT_NAME}${C_RESET} - reset Kibana's ${SETTING_KEY} across deployments and spaces

USAGE
    ${SCRIPT_NAME} [OPTIONS] ${ALL_KEYWORD}
    ${SCRIPT_NAME} [OPTIONS] DEPLOYMENT [DEPLOYMENT ...]
    ${SCRIPT_NAME} [OPTIONS]

${ALL_KEYWORD}           Process every deployment listed in the deployments file.
              A wildcard, not a deployment name; case-insensitive. Cannot
              be combined with specific deployments.
DEPLOYMENT    Process only these deployments, e.g. cdm-va cdm-fed. Names may
              be separated by spaces or commas (cdm-va,cdm-fed).
(nothing)     Same as ${ALL_KEYWORD}.

The deployments file is ${DEPLOYMENTS_FILE} (from --file / DEPLOYMENTS_FILE when
given; otherwise looked for in the current directory, then next to the
script). One or more deployments per line, separated by spaces or commas;
blank lines and anything after '#' are ignored. Duplicates are processed once.

For each deployment the script:
  1. derives the AWS Secrets Manager secret name
     (${FED_DEPLOYMENT} -> ${FED_SECRET_NAME}, cdm-<agency> -> ${AGENCY_SECRET_EXAMPLE}),
  2. reads the Kibana URL and credentials from that secret,
  3. lists ALL spaces via GET /api/spaces/space,
  4. sets ${SETTING_KEY} to false in each space via
     POST /s/<space_id>/api/kibana/settings/${SETTING_KEY},
  5. verifies the new value and prints a report.

OPTIONS
    -f, --file PATH        Deployments file used by '${ALL_KEYWORD}' (default: deployments.txt)
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
    -y, --yes              Do not prompt for confirmation (required to change
                           settings when not run from a terminal, e.g. cron/CI)
    -v, --verbose          Verbose logging
    -h, --help             This help

ENVIRONMENT
    KIBANA_URL_TEMPLATE    Fallback URL when the secret has none, e.g.
                           'https://kibana.{{deployment}}.example.com'
    SECRET_KEYS_URL, SECRET_KEYS_USERNAME, SECRET_KEYS_PASSWORD,
    SECRET_KEYS_API_KEY    Candidate JSON keys inside each secret
    FED_SECRET_NAME, AGENCY_SECRET_TEMPLATE, FED_DEPLOYMENT
                           Override the secret naming scheme
    DEPLOYMENTS_FILE       Same as --file
    NO_COLOR               Disable coloured output

EXIT STATUS
    0  every targeted space ended up with ${SETTING_KEY} = false
    1  at least one deployment or space failed
    2  usage error (bad option or argument); nothing was changed

EXAMPLES
    ${SCRIPT_NAME} --dry-run ${ALL_KEYWORD}
    ${SCRIPT_NAME} ${ALL_KEYWORD}
    ${SCRIPT_NAME} cdm-va cdm-fed
    ${SCRIPT_NAME} --yes --report-csv /tmp/reset-report.csv ${ALL_KEYWORD}
    ${SCRIPT_NAME} --file prod-deployments.txt ${ALL_KEYWORD}
    ${SCRIPT_NAME} --spaces default,master cdm-dos
HELP_EOF
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
declare -a CLI_DEPLOYMENTS=()

while (($#)); do
    case "$1" in
        -f|--file)             [[ $# -ge 2 ]] || usage_error "$1 needs a value"
                               DEPLOYMENTS_FILE="$2"; DEPLOYMENTS_FILE_EXPLICIT=true; FILE_FLAG_GIVEN=true
                               shift 2 ;;
        -n|--dry-run)          DRY_RUN=true; shift ;;
        --reset-to-default)    RESET_TO_DEFAULT=true; shift ;;
        --force)               FORCE=true; shift ;;
        -s|--spaces)           [[ $# -ge 2 ]] || usage_error "$1 needs a value"; SPACE_INCLUDE="$2"; shift 2 ;;
        -x|--exclude-spaces)   [[ $# -ge 2 ]] || usage_error "$1 needs a value"; SPACE_EXCLUDE="$2"; shift 2 ;;
        --report-csv)          [[ $# -ge 2 ]] || usage_error "$1 needs a value"; REPORT_CSV="$2"; shift 2 ;;
        --profile)             [[ $# -ge 2 ]] || usage_error "$1 needs a value"; AWS_PROFILE_OPT="$2"; shift 2 ;;
        --region)              [[ $# -ge 2 ]] || usage_error "$1 needs a value"; AWS_REGION_OPT="$2"; shift 2 ;;
        --timeout)             [[ $# -ge 2 ]] || usage_error "$1 needs a value"; HTTP_TIMEOUT="$2"; shift 2 ;;
        --retries)             [[ $# -ge 2 ]] || usage_error "$1 needs a value"; HTTP_RETRIES="$2"; shift 2 ;;
        --ca-bundle)           [[ $# -ge 2 ]] || usage_error "$1 needs a value"; CA_BUNDLE="$2"; shift 2 ;;
        --insecure)            INSECURE=true; shift ;;
        -y|--yes)              ASSUME_YES=true; shift ;;
        -v|--verbose)          VERBOSE=true; shift ;;
        -h|--help)             usage; exit 0 ;;
        --)                    shift; while (($#)); do CLI_DEPLOYMENTS+=("$1"); shift; done ;;
        -*)                    usage >&2; echo >&2; log_error "unknown option: $1"; exit 2 ;;
        *)                     CLI_DEPLOYMENTS+=("$1"); shift ;;
    esac
done

[[ "$HTTP_TIMEOUT" =~ ^[0-9]+$ ]] || usage_error "--timeout must be a whole number of seconds: $HTTP_TIMEOUT"
if [[ ! "$HTTP_RETRIES" =~ ^[0-9]+$ ]] || ((10#$HTTP_RETRIES < 1)); then
    usage_error "--retries must be a whole number >= 1: $HTTP_RETRIES"
fi
[[ "$RETRY_BACKOFF" =~ ^[0-9]+$ ]] || usage_error "RETRY_BACKOFF must be a whole number of seconds: $RETRY_BACKOFF"
# Normalise to base 10 so a value like 08 is not read as (invalid) octal.
HTTP_TIMEOUT=$((10#$HTTP_TIMEOUT)); HTTP_RETRIES=$((10#$HTTP_RETRIES)); RETRY_BACKOFF=$((10#$RETRY_BACKOFF))
[[ -z "$CA_BUNDLE" || -r "$CA_BUNDLE" ]] || usage_error "CA bundle not readable: $CA_BUNDLE"

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

# Report rows: deployment, space id, space name, value before, action, detail.
# Fields are flattened to one line with no tabs (error text can contain both,
# e.g. an HTML error page) and never left empty, so every row keeps exactly six
# columns in the table and the CSV.
add_report_row() {
    local row='' field
    for field in "$1" "$2" "$3" "$4" "$5" "$6"; do
        field="${field//$TAB/ }"
        field="${field//$CR/ }"
        field="${field//$LF/ }"
        [[ -n "$field" ]] || field='-'
        row="${row:+$row$TAB}$field"
    done
    printf '%s\n' "$row" >> "$REPORT_TSV"
}

is_all_keyword() {  # is_all_keyword <word> - case-insensitive match on "all"
    local lower
    lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    [[ "$lower" == "$ALL_KEYWORD" ]]
}

# Deployments to process, in order, without duplicates.
declare -a DEPLOYMENTS=()
DEPLOYMENTS_SEEN="$LF"
add_deployment() {  # add_deployment <name> <where it came from>
    case "$DEPLOYMENTS_SEEN" in
        *"$LF$1$LF"*)
            log_warn "duplicate deployment '$1' ($2) - it will be processed once"
            return 0 ;;
    esac
    DEPLOYMENTS_SEEN="$DEPLOYMENTS_SEEN$1$LF"
    DEPLOYMENTS+=("$1")
}

# Split a line on spaces, tabs and commas, printing one word per line.
split_words() {  # split_words <text>
    local text="$1" word
    local -a words=()
    text="${text//,/ }"
    text="${text//$CR/ }"
    text="${text//$LF/ }"
    read -r -a words <<<"$text" || true
    if ((${#words[@]} > 0)); then
        for word in "${words[@]}"; do printf '%s\n' "$word"; done
    fi
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

# Print the first present, non-empty, scalar value among the candidate keys.
# Works with jq 1.5 and later (no --args / $ARGS, which need jq 1.6).
json_pick() {  # json_pick <json> <space separated candidate keys>
    local json="$1" keys_joined
    local -a keys=()
    read -r -a keys <<<"$2" || true
    ((${#keys[@]} > 0)) || return 0
    keys_joined="${keys[*]}"
    jq -r --arg keys "$keys_joined" '
        . as $o
        | first(
            $keys | split(" ")[] | select(length > 0) as $k
            | $o | .[$k]
            | if . == null or type == "object" or type == "array" then empty else tostring end
            | select(length > 0)
          ) // empty
    ' <<<"$json" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------
# Sets KB_HTTP_CODE / KB_BODY / KB_ERR / KB_REDIRECT. Returns 0 only on a 2xx
# response.
#
# Redirects are deliberately not followed: following one would turn the POST
# into a GET, and older curl versions send a custom Authorization header on to
# whatever host the redirect names. A redirect is reported as a failure that
# says where it pointed, so the URL in the secret can be corrected.
kb_request() {  # kb_request <method> <path> [json payload]
    local method="$1" path="$2" payload="${3-}"
    local url="${KB_URL%/}${path}"
    local attempt=1 code='' out=''

    KB_HTTP_CODE=''; KB_BODY=''; KB_ERR=''; KB_REDIRECT=''; KB_PROBLEM=''

    while :; do
        local -a args=(
            --silent --show-error
            --max-time "$HTTP_TIMEOUT"
            --config "$CURL_CFG"
            --request "$method"
            --header 'kbn-xsrf: true'
            --output "$BODY_FILE"
            --write-out '%{http_code} %{redirect_url}'
        )
        if [[ -n "$CA_BUNDLE" ]]; then args+=(--cacert "$CA_BUNDLE"); fi
        if [[ "$INSECURE" == true ]]; then args+=(--insecure); fi
        if [[ -n "$payload" ]]; then
            printf '%s' "$payload" > "$PAYLOAD_FILE"
            args+=(--header 'Content-Type: application/json' --data-binary "@$PAYLOAD_FILE")
        fi

        : > "$BODY_FILE"; : > "$ERR_FILE"
        # A transport failure (DNS, refused, TLS, timeout) makes curl exit
        # non-zero; treat that as "no HTTP status" so it can be retried.
        if ! out="$(curl "${args[@]}" "$url" 2>"$ERR_FILE")"; then
            out=''
        fi
        code="${out%% *}"
        [[ "$code" =~ ^[0-9]{3}$ && "$code" != 000 ]] || code=''

        KB_HTTP_CODE="$code"
        KB_REDIRECT="${out#* }"
        [[ "$KB_REDIRECT" != "$out" ]] || KB_REDIRECT=''
        KB_BODY="$(cat "$BODY_FILE" 2>/dev/null || true)"
        KB_ERR="$(tr '\n' ' ' < "$ERR_FILE" 2>/dev/null || true)"

        log_debug "$method $url -> ${code:-<no response>}"

        if [[ -n "$code" ]] && ((10#$code >= 200 && 10#$code < 300)); then
            return 0
        fi

        if ((attempt < HTTP_RETRIES)) &&
           { [[ -z "$code" ]] || ((10#$code == 429 || 10#$code >= 500)); }; then
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
    local msg='' snippet
    snippet="$(printf '%s' "$KB_BODY" | tr '\n\t\r' '   ' | cut -c1-160)"
    if [[ -n "$KB_PROBLEM" ]]; then
        msg="$KB_PROBLEM${snippet:+ - got: $snippet}"
    elif [[ "$KB_HTTP_CODE" == 3* ]]; then
        msg="redirected${KB_REDIRECT:+ to $KB_REDIRECT}; set the Kibana URL in the secret to the final address"
    else
        msg="$(jq -r '(.message // .error.reason // .error // empty)
                      | if type == "string" then . else tojson end' <<<"$KB_BODY" 2>/dev/null || true)"
        [[ -n "$msg" ]] || msg="$snippet"
        [[ -n "$msg" ]] || msg="$KB_ERR"
    fi
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
    # AWS_PAGER='' stops AWS CLI v2 from piping the output through a pager.
    if ! secret_json="$(AWS_PAGER='' aws "${aws_args[@]}" 2>"$ERR_FILE")"; then
        CRED_ERROR="aws secretsmanager get-secret-value failed for '$secret_name': $(tr '\n' ' ' < "$ERR_FILE" | cut -c1-200)"
        return 1
    fi
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$secret_json"; then
        CRED_ERROR="secret '$secret_name' is not a JSON object"
        return 1
    fi

    KB_URL="$(json_pick "$secret_json" "$SECRET_KEYS_URL")"
    KB_USER="$(json_pick "$secret_json" "$SECRET_KEYS_USERNAME")"
    KB_PASS="$(json_pick "$secret_json" "$SECRET_KEYS_PASSWORD")"
    KB_API_KEY="$(json_pick "$secret_json" "$SECRET_KEYS_API_KEY")"
    secret_json=''

    if [[ -z "$KB_URL" && -n "$KIBANA_URL_TEMPLATE" ]]; then
        local agency="${deployment#cdm-}"
        KB_URL="${KIBANA_URL_TEMPLATE//$PH_DEPLOYMENT/$deployment}"
        KB_URL="${KB_URL//$PH_AGENCY/$agency}"
        log_debug "no URL in secret; using template -> $KB_URL"
    fi
    # Surrounding whitespace in a stored URL is a copy/paste slip, never meaningful.
    KB_URL="${KB_URL#"${KB_URL%%[![:space:]]*}"}"
    KB_URL="${KB_URL%"${KB_URL##*[![:space:]]}"}"
    if [[ -z "$KB_URL" ]]; then
        CRED_ERROR="no Kibana URL in secret '$secret_name' (tried: $SECRET_KEYS_URL) and KIBANA_URL_TEMPLATE is unset"
        return 1
    fi
    [[ "$KB_URL" == http://* || "$KB_URL" == https://* ]] || KB_URL="https://$KB_URL"
    local url_re='^https?://[^[:space:]/?#]+(/[^[:space:]]*)?$'
    if [[ ! "$KB_URL" =~ $url_re ]]; then
        CRED_ERROR="Kibana URL from secret '$secret_name' is malformed: $KB_URL"
        return 1
    fi

    if [[ -z "$KB_API_KEY" && ( -z "$KB_USER" || -z "$KB_PASS" ) ]]; then
        CRED_ERROR="no usable credentials in secret '$secret_name' (need an API key, or a username and password)"
        return 1
    fi
    # A line break cannot be sent in an HTTP header; refuse rather than send a
    # mangled credential and get a confusing 401.
    local in_use
    if [[ -n "$KB_API_KEY" ]]; then in_use="$KB_API_KEY"; else in_use="$KB_USER$KB_PASS"; fi
    if [[ "$in_use" == *"$LF"* || "$in_use" == *"$CR"* ]]; then
        CRED_ERROR="credentials in secret '$secret_name' contain a line break"
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
        KB_PROBLEM='unexpected response from /api/spaces/space (expected a JSON list of spaces)'
        return 1
    fi
    jq -r '.[]
           | select(type == "object" and (.id | type) == "string" and (.id | length) > 0)
           | [.id, (if (.name | type) == "string" and (.name | length) > 0 then .name else .id end)]
           | @tsv' <<<"$KB_BODY"
}

# Reads the setting into SETTING_VALUE (empty when there is no override).
# Sets a global rather than echoing so that the KB_* diagnostics from the
# request survive for the caller's error reporting.
SETTING_VALUE=''
read_setting_value() {  # read_setting_value <space id>
    local prefix; prefix="$(space_path_prefix "$1")"
    SETTING_VALUE=''
    kb_request GET "${prefix}/api/kibana/settings" || return 1
    # Only a genuine settings response may be read as "not set". Anything else
    # (a proxy's {} or HTML login page with status 200) must fail, not be
    # mistaken for "already false" and skipped.
    if ! jq -e 'type == "object" and (.settings | type) == "object"' >/dev/null 2>&1 <<<"$KB_BODY"; then
        KB_PROBLEM='unexpected response from /api/kibana/settings (expected a Kibana settings object)'
        return 1
    fi
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

    # Align columns with awk rather than column(1), which is missing on some
    # minimal images and fails on long lines on others.
    {
        printf 'DEPLOYMENT\tSPACE_ID\tSPACE_NAME\tBEFORE\tACTION\tDETAIL\n'
        cat "$REPORT_TSV"
    } | awk -F'\t' '
        {
            for (i = 1; i <= NF; i++) {
                cell[NR, i] = $i
                if (length($i) > width[i]) width[i] = length($i)
            }
            if (NF > cols) cols = NF
        }
        END {
            for (r = 1; r <= NR; r++) {
                line = ""
                for (i = 1; i < cols; i++) line = line sprintf("%-" width[i] "s  ", cell[r, i])
                print line cell[r, cols]
            }
        }'

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
# Split the command-line deployments (which may be comma separated) into words
# and look for the `all` wildcard.
declare -a CLI_WORDS=()
USE_ALL=false
if ((${#CLI_DEPLOYMENTS[@]} > 0)); then
    for arg in "${CLI_DEPLOYMENTS[@]}"; do
        while IFS= read -r word; do
            [[ -n "$word" ]] || continue
            if is_all_keyword "$word"; then USE_ALL=true; fi
            CLI_WORDS+=("$word")
        done < <(split_words "$arg")
    done
fi

if [[ "$USE_ALL" == true ]] && ((${#CLI_WORDS[@]} > 1)); then
    usage_error "'$ALL_KEYWORD' means every deployment in the deployments file and cannot be combined with other deployment names (got: ${CLI_WORDS[*]})"
fi
if ((${#CLI_DEPLOYMENTS[@]} > 0)) && ((${#CLI_WORDS[@]} == 0)); then
    usage_error "no deployment names in the arguments given"
fi

if ((${#CLI_WORDS[@]} > 0)) && [[ "$USE_ALL" != true ]]; then
    # Specific deployments named on the command line.
    for word in "${CLI_WORDS[@]}"; do
        add_deployment "$word" 'command line'
    done
    if [[ "$FILE_FLAG_GIVEN" == true ]]; then
        log_warn "--file $DEPLOYMENTS_FILE is ignored because deployments were named on the command line (use '$ALL_KEYWORD' to process the file)"
    fi
    log_info "using ${#DEPLOYMENTS[@]} deployment(s) from the command line"
else
    # `all`, or nothing: every deployment in the deployments file.
    if [[ "$DEPLOYMENTS_FILE_EXPLICIT" != true && ! -e "$DEPLOYMENTS_FILE" &&
          -e "$SCRIPT_DIR/$DEPLOYMENTS_FILE" ]]; then
        DEPLOYMENTS_FILE="$SCRIPT_DIR/$DEPLOYMENTS_FILE"
    fi
    [[ -f "$DEPLOYMENTS_FILE" && -r "$DEPLOYMENTS_FILE" ]] ||
        die "deployments file not found or not readable: $DEPLOYMENTS_FILE (name deployments on the command line, or use --file)"

    line_no=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))
        line="${line%%#*}"                                   # strip comments
        while IFS= read -r word; do
            [[ -n "$word" ]] || continue
            if is_all_keyword "$word"; then
                log_warn "$DEPLOYMENTS_FILE line $line_no: '$word' is the command-line wildcard, not a deployment name - skipped"
                continue
            fi
            add_deployment "$word" "$DEPLOYMENTS_FILE line $line_no"
        done < <(split_words "$line")
    done < "$DEPLOYMENTS_FILE"

    ((${#DEPLOYMENTS[@]} > 0)) || die "no deployments found in $DEPLOYMENTS_FILE"
    if [[ "$USE_ALL" == true ]]; then
        log_info "'$ALL_KEYWORD': read ${#DEPLOYMENTS[@]} deployment(s) from $DEPLOYMENTS_FILE"
    else
        log_info "no deployments named; read ${#DEPLOYMENTS[@]} deployment(s) from $DEPLOYMENTS_FILE"
    fi
fi

# Changing settings needs a yes: from the prompt when run interactively, or
# from --yes otherwise. Without a terminal there is no one to ask, and silently
# proceeding could change every space of every deployment unattended.
if [[ "$DRY_RUN" != true && "$ASSUME_YES" != true && ! -t 0 ]]; then
    usage_error "not running interactively, so cannot ask for confirmation: pass --yes to change settings (or --dry-run to preview)"
fi

# Fail now, not after processing 100+ deployments, if the report cannot be
# written. Done after every other usage check so a usage error creates nothing.
if [[ -n "$REPORT_CSV" ]] && ! { : >> "$REPORT_CSV"; } 2>/dev/null; then
    usage_error "--report-csv path is not writable: $REPORT_CSV"
fi

# --------------------------------------------------------------------------
# Dependencies and scratch space (after argument checks, so usage errors are
# reported first)
# --------------------------------------------------------------------------
for dep in curl jq aws awk; do
    command -v "$dep" >/dev/null 2>&1 || die "required command not found: $dep"
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reset-kibana-state.XXXXXX")"
chmod 700 "$TMP_DIR"
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

readonly BODY_FILE="$TMP_DIR/body"
readonly ERR_FILE="$TMP_DIR/err"
readonly PAYLOAD_FILE="$TMP_DIR/payload.json"
readonly CURL_CFG="$TMP_DIR/curl.cfg"
readonly REPORT_TSV="$TMP_DIR/report.tsv"
: > "$REPORT_TSV"

if [[ "$INSECURE" == true ]]; then
    log_warn "--insecure: Kibana TLS certificates will NOT be verified"
fi

if [[ "$DRY_RUN" != true && "$ASSUME_YES" != true ]]; then
    printf '\n' >&2
    if [[ "$RESET_TO_DEFAULT" == true ]]; then
        log_warn "about to RESET $SETTING_KEY to its default in every space of ${#DEPLOYMENTS[@]} deployment(s)"
    else
        log_warn "about to SET $SETTING_KEY to false in every space of ${#DEPLOYMENTS[@]} deployment(s)"
    fi
    # Ctrl-D (EOF) counts as "no" rather than tripping set -e silently.
    reply=''
    read -r -p "Continue? [y/N] " reply || reply=''
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
