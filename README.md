# reset_kibana_state_session

Bulk-reset the Kibana advanced setting `state:storeInSessionStorage` to `false`
across many deployments and **every space** in each one.

## The problem this solves

When `state:storeInSessionStorage` is `true`, Kibana keeps global app state in
the browser's `sessionStorage` and puts only a short hash in the URL, e.g.
`?_g=h@8c48049`. After a cluster change or an upgrade those `sessionStorage`
entries go stale, the hash can no longer be resolved, and Kibana shows:

> Unable to completely restore the URL, be sure to use the share functionality.

Setting it back to its default (`false`) makes Kibana put the full state in the
URL again, and the error goes away.

Doing this by hand means, per deployment and per space: Stack Management →
Kibana → Advanced Settings → search `state:storeInSessionStorage` → *Reset to
default* → Save. This script does the same thing through the API:

```
POST /s/<space_id>/api/kibana/settings/state:storeInSessionStorage
{"value": false}
```

## Requirements

- `bash` 4+, `curl`, `jq` 1.5 or later, `awk`
- `aws` CLI, already authenticated with permission to read the relevant secrets
  (`secretsmanager:GetSecretValue`)
- A Kibana user (or API key) per deployment that may change advanced settings
  in every space — in practice a superuser, since Advanced Settings are
  space-scoped saved objects

## Running from Ansible Automation Platform

`playbooks/reset_kibana_state_session.yml` runs the script on the appserver
from AAP, with a survey for the inputs. [docs/aap-setup.md](docs/aap-setup.md)
walks through creating the project, inventory, credential, job template and
survey; `aap/survey_spec.json` holds the survey for import through the API.

The survey's **Deployments** and **Exclude deployments** questions are
multiple-select, so they list every deployment as an option. Those options are
generated from `deployments.txt`: after changing the file, run
`python3 aap/build_survey_spec.py` and upload the result (see
[Updating the deployment list](docs/aap-setup.md#updating-the-deployment-list)).

| Path | What |
| --- | --- |
| `reset_kibana_state_session.sh` | The script |
| `deployments.txt` | The deployments `all` expands to |
| `playbooks/reset_kibana_state_session.yml` | AAP playbook (runs on the `appserver` group) |
| `playbooks/files/summarize_report.awk` | Summarises the run's CSV across every deployment |
| `inventory/hosts.yml` | Example inventory with the `appserver` group |
| `aap/survey_spec.json` | The job template survey (generated) |
| `aap/build_survey_spec.py` | Generates the survey from `deployments.txt` |
| `docs/aap-setup.md` | AAP setup, step by step |
| `docs/test-plan.md` | Manual test cases for the script, the AAP job and the fix in Kibana |
| `tests/` | Test suites for the script and the playbook |

## Deployment → secret mapping

The AWS Secrets Manager secret name is derived from the deployment name:

| Deployment | Secret          |
| ---------- | --------------- |
| `cdm-fed`  | `federal_store` |
| `cdm-va`   | `agency_va_store`  |
| `cdm-dos`  | `agency_dos_store` |
| `cdm-tva`  | `agency_tva_store` |

i.e. `cdm-fed` → `federal_store`, and any other `cdm-<agency>` →
`agency_<agency>_store`. Override with `FED_DEPLOYMENT`, `FED_SECRET_NAME` and
`AGENCY_SECRET_TEMPLATE` (which understands the `{{agency}}` placeholder) if the
scheme ever changes.

## Secret contents

Each deployment's secret is a JSON object. The two keys the script uses are:

```json
{
  "kibana_url": "https://kibana.cdm-va.example.gov",
  "awx_manage_kibana_api_key": "<base64 encoded API key>"
}
```

- `kibana_url` — the Kibana endpoint.
- `awx_manage_kibana_api_key` — sent as `Authorization: ApiKey <value>`. It
  must be the base64 `encoded` form Elasticsearch returns when a key is
  created (not the separate `id` and `api_key` fields), and the key needs
  privileges to change advanced settings in every space.

Other keys in the secret are ignored. When the API key is present it is always
used, even if the secret also holds unrelated `username`/`password` fields.

For secrets that don't follow that schema the script also accepts, in order of
preference:

- URL: `KIBANA_URL`, `kibanaUrl`, `kibana_endpoint`, `kibana_host`,
  `kibana_uri`, `kibana`, `url`, `endpoint`
- API key: `kibana_api_key`, `KIBANA_API_KEY`, `kibanaApiKey`, `api_key`,
  `apiKey`
- Or, only when there is no API key, a username and password: `kibana_username`
  / `kibana_password`, `elastic_username` / `elastic_password`, `username` /
  `password`, …

If your secrets use different names, set `SECRET_KEYS_URL`,
`SECRET_KEYS_USERNAME`, `SECRET_KEYS_PASSWORD` or `SECRET_KEYS_API_KEY` to a
space-separated list of the keys to try — no code change needed:

```bash
SECRET_KEYS_URL='kbn_endpoint' SECRET_KEYS_PASSWORD='kbn_pw' \
  ./reset_kibana_state_session.sh --dry-run
```

If the secret holds no URL at all, provide one with a template:

```bash
KIBANA_URL_TEMPLATE='https://kibana.{{deployment}}.example.gov' \
  ./reset_kibana_state_session.sh
```

`{{deployment}}` and `{{agency}}` are both substituted.

## Usage

```bash
# See what would change across every deployment in deployments.txt. Start here.
./reset_kibana_state_session.sh --dry-run all

# Do it, for every deployment in deployments.txt
./reset_kibana_state_session.sh all

# Only certain deployments (the file is not read)
./reset_kibana_state_session.sh cdm-va cdm-fed
./reset_kibana_state_session.sh cdm-va,cdm-fed          # commas work too

# A different list, unattended, with a CSV report for the change record
./reset_kibana_state_session.sh --file prod.txt --yes --report-csv reset-report.csv all

# Everything except some deployments
./reset_kibana_state_session.sh --exclude-deployments cdm-tva,cdm-dos all

# Only the master spaces, everywhere
./reset_kibana_state_session.sh --spaces master all

# Every space except some
./reset_kibana_state_session.sh --exclude-spaces 'default, admin, infra' all
```

### Choosing deployments

| You pass | What runs |
| --- | --- |
| `all` | Every deployment in the deployments file |
| one or more names | Only those deployments; the file is not read |
| nothing | Same as `all` |

`all` is a wildcard, not a deployment name. It is case-insensitive (`ALL` and
`All` work too) and on the command line cannot be mixed with names: `all
cdm-va` is rejected with exit status `2` before anything runs, rather than
guessing which you meant. (In the AAP survey, where these are tick-boxes,
ticking `all` alongside individual deployments is accepted and means `all`.)

`--exclude-deployments LIST` leaves deployments out of whichever list was
chosen — `all` or named ones. Names are separated by commas or spaces
(`cdm-va,cdm-dos` or `'cdm-va, cdm-dos'`). An excluded name that is not in the
list is reported and otherwise ignored; excluding every deployment, or
excluding `all`, is rejected with exit status `2`.

### The deployments file

- Defaults to `deployments.txt`, looked for in the current directory and then
  next to the script — so `all` works from cron or any other directory.
  `--file PATH` (or `DEPLOYMENTS_FILE=PATH`) uses exactly that file instead.
- One deployment per line, or several separated by spaces or commas
  (`cdm-va, cdm-dos`). Blank lines and anything after `#` are ignored; Windows
  line endings are fine.
- A name listed twice is processed once, with a warning.
- A line reading `all` is skipped with a warning — it is the command-line
  wildcard, never a deployment.

Full flag list: `./reset_kibana_state_session.sh --help`.

| Flag | Meaning |
| --- | --- |
| `-f, --file PATH` | Deployments file read by `all` (default `deployments.txt`) |
| `-n, --dry-run` | Report what would change; change nothing |
| `--reset-to-default` | Send `{"value": null}` — removes the override, exactly like the UI's *Reset to default* — instead of writing an explicit `false` |
| `--force` | Write even where the value is already false |
| `-s, --spaces LIST` | Only these space ids (comma separated) |
| `-x, --exclude-spaces LIST` | Skip these space ids (comma separated; spaces after commas are fine) |
| `--exclude-deployments LIST` | Leave these deployments out (comma or space separated) |
| `--report-csv PATH` | Also write the report as CSV |
| `--profile` / `--region` | Passed through to the AWS CLI |
| `--timeout` / `--retries` | Per-request timeout and attempt count |
| `--ca-bundle PATH` / `--insecure` | Kibana TLS verification |
| `-y, --yes` | Skip the confirmation prompt |
| `-v, --verbose` | Log every request |

### `false` or "reset to default"?

Both leave Kibana behaving the same way, since `false` *is* the default.

- Default behaviour writes an explicit `false`. The override stays visible in
  Advanced Settings, which makes the change easy to audit and to confirm.
- `--reset-to-default` removes the override entirely, matching the manual fix
  click-for-click. Advanced Settings then shows no customisation at all.

## What it does per deployment

1. Derive the secret name from the deployment name.
2. `aws secretsmanager get-secret-value` → Kibana URL + credentials.
3. `GET /api/spaces/space` → **all** spaces. (If the spaces API returns 404,
   the deployment is treated as having only the `default` space.)
4. Per space, `GET [/s/<id>]/api/kibana/settings` to read the current value.
   Spaces already at `false` are left alone and reported as such.
5. `POST [/s/<id>]/api/kibana/settings/state:storeInSessionStorage` with
   `{"value": false}`.
6. Re-read the setting to verify, then report.

The `default` space is addressed without an `/s/default` prefix, which is how
Kibana serves it.

## Report

```
================================================================
 REPORT - state:storeInSessionStorage
================================================================

DEPLOYMENT  SPACE_ID   SPACE_NAME  BEFORE                ACTION         DETAIL
cdm-va      default    Default     unset(default false)  already-false  no change needed
cdm-va      master     Master      true                  reset          now false
cdm-va      analytics  Analytics   true                  reset          now false

Summary
  deployments succeeded : 1
  deployments failed    : 0
  spaces reset to false : 2
  spaces already false  : 1
  spaces skipped        : 0
  failures              : 0
```

Actions: `reset`, `already-false`, `would-reset` (dry run), `reset-unverified`
(write succeeded, re-read failed), `skipped`, `failed`.

Exit status is `0` when every targeted space ended up at `false`, `1` if any
deployment or space failed, `2` on a usage error (bad option or argument, or an
unwritable `--report-csv` path) — in which case nothing was read or changed.
One failing deployment does not stop the rest — the run continues and the
failure appears in the report.

## Safety notes

- Idempotent: re-running reports `already-false` and makes no further writes.
- Changing settings needs a yes. Run from a terminal, the script asks first;
  run without one (cron, CI, `ssh host '…'`), it refuses unless `--yes` is
  given, rather than silently changing every deployment. `--dry-run` never
  needs it, so a scheduled drift check runs unattended.
- Credentials are passed to `curl` through a `0600` config file in a `0700`
  temporary directory, so they never appear in the process list or in any log
  line. The temporary directory is removed on exit.
- Transport errors, `429` and `5xx` are retried with linear backoff; `4xx`
  responses are not (a `401`/`403` means fix the credentials, not retry).
- A response that is not what Kibana returns — `{}` from a proxy, an HTML
  login page served with status `200` — is reported as `failed`. It is never
  mistaken for "setting not present" and skipped as `already-false`.
- Redirects are not followed. Following one would turn the `POST` into a `GET`,
  and older `curl` versions forward the `Authorization` header to whatever host
  the redirect names. A redirect is reported with its target so the URL in the
  secret can be corrected.
- Roughly three HTTP calls per space, run sequentially. For 100+ deployments
  expect the run to take a while; split the deployments file across a few
  parallel invocations if that matters.

## Tests

`tests/run_tests.sh` runs the script end to end against a mock Kibana
(`tests/mock_kibana.py`) and a stub `aws`, so it needs neither AWS nor a real
cluster:

```bash
./tests/run_tests.sh
```

It covers the secret-name mapping, the `all` wildcard and every way of naming
deployments, deployments-file parsing and lookup, usage errors (exit `2`, with
nothing read or changed), dry run, the real reset, idempotency, space filters,
API-key and username/password authentication, unexpected Kibana responses and
redirects, per-deployment failure isolation, `--reset-to-default`, and that
credentials never reach the output or the report.

The script supports jq 1.5 and later. To run the suite against a specific jq:

```bash
JQ_BIN_DIR=/path/to/dir/containing/jq ./tests/run_tests.sh
```

`tests/run_playbook_tests.sh` runs the real AAP playbook against the local
machine (standing in for the appserver), with the same mock Kibana and a stub
`aws` serving secrets in the real `kibana_url` / `awx_manage_kibana_api_key`
schema. It needs ansible-core 2.15 or later, but no AAP, AWS or sudo:

```bash
./tests/run_playbook_tests.sh
ANSIBLE_BIN_DIR=/path/to/venv/bin ./tests/run_playbook_tests.sh   # a specific install
```

It covers input validation (nothing reaches the appserver on bad input), dry
run and execute, `all`, every input form the survey can send, each survey
option, the missing-tool check, a failing deployment (all output still shown,
then the job fails), a job that times out, and that the survey spec matches the
playbook.
