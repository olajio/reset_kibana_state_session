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

- `bash` 4+, `curl`, `jq`
- `aws` CLI, already authenticated with permission to read the relevant secrets
  (`secretsmanager:GetSecretValue`)
- A Kibana user (or API key) per deployment that may change advanced settings
  in every space — in practice a superuser, since Advanced Settings are
  space-scoped saved objects

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

Each secret must be a JSON object holding the Kibana endpoint and credentials.
The script accepts the common key spellings and takes the first one it finds:

```json
{
  "kibana_url": "https://kibana.cdm-va.example.gov",
  "kibana_username": "svc_kibana_admin",
  "kibana_password": "..."
}
```

- URL keys tried: `kibana_url`, `KIBANA_URL`, `kibanaUrl`, `kibana_endpoint`,
  `kibana_host`, `kibana_uri`, `kibana`, `url`, `endpoint`
- Username keys: `kibana_username`, `kibana_user`, `elastic_username`,
  `username`, `user`, …
- Password keys: `kibana_password`, `kibana_pass`, `elastic_password`,
  `password`, `pass`, …
- API key instead of username/password: `kibana_api_key`, `api_key`, `apiKey`
  (sent as `Authorization: ApiKey …`)

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

List your deployments in `deployments.txt`, one per line (`#` comments and blank
lines are ignored), then:

```bash
# See what would change, everywhere. Always start here.
./reset_kibana_state_session.sh --dry-run

# Do it, for every deployment in deployments.txt
./reset_kibana_state_session.sh

# Only certain deployments (overrides the file)
./reset_kibana_state_session.sh cdm-va cdm-fed

# A different list, unattended, with a CSV report for the change record
./reset_kibana_state_session.sh --file prod.txt --yes --report-csv reset-report.csv

# Only the master spaces
./reset_kibana_state_session.sh --spaces master
```

Full flag list: `./reset_kibana_state_session.sh --help`.

| Flag | Meaning |
| --- | --- |
| `-f, --file PATH` | Deployments file (default `deployments.txt`) |
| `-n, --dry-run` | Report what would change; change nothing |
| `--reset-to-default` | Send `{"value": null}` — removes the override, exactly like the UI's *Reset to default* — instead of writing an explicit `false` |
| `--force` | Write even where the value is already false |
| `-s, --spaces LIST` | Only these space ids (comma separated) |
| `-x, --exclude-spaces LIST` | Skip these space ids |
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

DEPLOYMENT       SPACE_ID           SPACE_NAME             BEFORE                 ACTION             DETAIL
cdm-va           default            Default                unset(default false)   already-false      no change needed
cdm-va           master             Master                 true                   reset              now false
cdm-va           analytics          Analytics              true                   reset              now false

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
deployment or space failed, `2` on a usage error. One failing deployment does
not stop the rest — the run continues and the failure appears in the report.

## Safety notes

- Idempotent: re-running reports `already-false` and makes no further writes.
- Interactive runs ask for confirmation first; `--yes` skips that for CI.
- Credentials are passed to `curl` through a `0600` config file in a `0700`
  temporary directory, so they never appear in the process list or in any log
  line. The temporary directory is removed on exit.
- Transport errors, `429` and `5xx` are retried with linear backoff; `4xx`
  responses are not (a `401`/`403` means fix the credentials, not retry).
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

It covers the secret-name mapping, dry run, the real reset, idempotency, space
filters, deployments-file parsing, per-deployment failure isolation,
`--reset-to-default`, and that credentials never reach the output.
