# Running the reset from Ansible Automation Platform

This sets up an AAP **project** and **job template** (with a survey) that run
`reset_kibana_state_session.sh` on the appserver, the same way the Cleanup
Duplicate Data Views toolkit runs.

Menu paths are given for AAP 2.5 first, then AAP 2.4 in brackets. Field names
are the same in both.

## How it fits together

1. You launch the job template and answer the survey.
2. AAP checks out this repository (the project) and runs
   `playbooks/reset_kibana_state_session.yml`.
3. On the AAP side the playbook validates your answers and, for `all`, expands
   the list from `deployments.txt` in the checkout. Nothing reaches the
   appserver until the inputs are valid.
4. Over SSH with sudo (the Machine credential), it copies the script to
   `/opt/reset_kibana_state_session` on the appserver.
5. It splits the deployments across up to *Parallel jobs* copies of the script,
   running at once on the appserver.
6. Each copy reads each deployment's `kibana_url` and
   `awx_manage_kibana_api_key` from AWS Secrets Manager using the appserver's
   IAM role, lists every Kibana space, and sets `state:storeInSessionStorage`
   in each one (or only reports, in dry-run).
7. The playbook shows all the output, writes one log and one CSV for the run,
   prints a summary across every deployment, and **fails the job if any
   deployment or space failed**. A green job means every targeted space ended
   up `false`.

Secret names come from the deployment name: `cdm-fed` → `federal_store`, and
`cdm-<agency>` → `agency_<agency>_store`. Deployment names use hyphens
(`cdm-fed`, not `cdm_fed`).

---

## Before you start: check the appserver

These are one-time checks. If the Cleanup Duplicate Data Views toolkit already
runs on this appserver, the IAM role, network access and CA bundle are almost
certainly in place already.

**1. Tools.** The script needs `bash`, `curl`, `jq` (1.5 or later), the AWS CLI
(v1 or v2) and `awk`. On the appserver:

```bash
for t in bash curl jq aws awk; do printf '%-5s ' "$t"; command -v "$t" || echo MISSING; done
jq --version; aws --version
```

The AWS CLI v2 installer puts `aws` in `/usr/local/bin`, which RHEL's `sudo`
leaves off the PATH. The playbook sets the PATH itself, so that is handled. If
`aws` or `jq` lives somewhere else, put that directory at the front of the
`script_path` variable (Step 4). The playbook checks for all five tools before
running anything and names any it cannot find.

**2. IAM role.** The appserver's instance role needs
`secretsmanager:GetSecretValue` on every deployment's secret. The secret ARNs
end in a random six-character suffix, hence the `-*`:

```json
{
  "Effect": "Allow",
  "Action": "secretsmanager:GetSecretValue",
  "Resource": [
    "arn:aws:secretsmanager:us-east-1:<account-id>:secret:agency_*_store-*",
    "arn:aws:secretsmanager:us-east-1:<account-id>:secret:federal_store-*"
  ]
}
```

No AWS credential is attached in AAP. The script runs on the appserver and uses
its instance role.

**3. Secrets.** Each secret holds `kibana_url` and `awx_manage_kibana_api_key`.
The API key must be the base64 `encoded` value, and needs privileges to change
Advanced Settings in **every** space. Kibana only lists the spaces a key can
see, so a key limited to some spaces silently produces a shorter list. Compare
the space count in the first dry run against the Kibana UI.

**4. Network.** The appserver must reach every deployment's Kibana URL and AWS
Secrets Manager in `us-east-1`.

**5. CA bundle.** `/etc/pki/tls/certs/ca-bundle.crt` must trust the Zscaler CA
(it is the same file the other toolkits use). It verifies Kibana's TLS, and is
also given to the AWS CLI, which otherwise uses its own built-in CA list.

---

## Step 1 — Create the project

**Automation Execution → Projects → Create project** (AAP 2.4: **Resources →
Projects → Add**)

| Field | Value |
| --- | --- |
| Name | `Reset Kibana State Session` |
| Description | `Resets Kibana state:storeInSessionStorage to false across deployments` |
| Organization | Your organization (the same one as your other Kibana toolkits) |
| Execution environment | Leave blank (uses the default). The playbook only uses `ansible.builtin` modules, so no extra collections are needed. |
| Source control type | `Git` |
| Source control URL | `https://github.com/olajio/reset_kibana_state_session.git` |
| Source control branch/tag/commit | `main` |
| Source control refspec | Leave blank |
| Source control credential | The GitHub credential your other projects use, if this repository is private. Leave blank if it is public. |
| Options: **Clean** | ✅ Checked — discard local changes before each update |
| Options: **Delete** | ☐ Unchecked |
| Options: **Track submodules** | ☐ Unchecked |
| Options: **Update revision on launch** | ✅ Checked — every job uses the latest script and `deployments.txt` from `main` |
| Options: **Allow branch override** | ☐ Unchecked — stops a job template from pointing at an untested branch |
| Cache timeout | `0` |

Save. AAP syncs the project immediately; wait for the status to show
**Successful** before continuing. If it fails, the job output shows why —
usually the source control credential.

---

## Step 2 — Choose or create the inventory

The playbook runs on the inventory group named exactly **`appserver`**.

**Option A — reuse an existing inventory (recommended).** If the inventory used
by the Cleanup Duplicate Data Views template has an `appserver` group containing
the appserver, use that one. Nothing to create.

**Option B — create one.** **Automation Execution → Infrastructure →
Inventories → Create inventory → Create inventory** (AAP 2.4: **Resources →
Inventories → Add → Add inventory**)

| Field | Value |
| --- | --- |
| Name | `Kibana Toolkits - Appserver` |
| Organization | Your organization |

Save, then:

1. **Groups → Create group**: name `appserver`. Save.
2. In the `appserver` group, **Hosts → Create new host**: name = the
   appserver's hostname or IP. Save.

**Option C — take it from the project.** Edit `inventory/hosts.yml` in this
repository to name the appserver and push to `main`. Then, in a new inventory:
**Sources → Create source**, Source = `Sourced from a Project`, Project =
`Reset Kibana State Session`, Inventory file = `inventory/hosts.yml`, and check
**Overwrite** and **Update on launch**. Save and **Sync**.

---

## Step 3 — Choose or create the Machine credential

**Option A — reuse** the Machine credential your other appserver templates use.

**Option B — create one.** **Automation Execution → Infrastructure →
Credentials → Create credential** (AAP 2.4: **Resources → Credentials → Add**)

| Field | Value |
| --- | --- |
| Name | `Appserver SSH` |
| Organization | Your organization |
| Credential type | `Machine` |
| Username | The SSH user for the appserver |
| SSH private key | That user's private key (or a password, if that is how you connect) |
| Privilege escalation method | `sudo` |
| Privilege escalation username | Leave blank (root) |
| Privilege escalation password | Only if that user's sudo asks for a password |

Do **not** attach an Amazon Web Services credential. The script runs on the
appserver and uses its IAM role; an AWS credential in AAP would only apply
inside the execution environment, not on the appserver.

---

## Step 4 — Create the job template

**Automation Execution → Templates → Create template → Create job template**
(AAP 2.4: **Resources → Templates → Add → Add job template**)

| Field | Value |
| --- | --- |
| Name | `Reset Kibana storeInSessionStorage` |
| Description | `Sets state:storeInSessionStorage to false in every space. Dry run by default.` |
| Job type | `Run` (not `Check` — check mode skips the commands, so it would report nothing) |
| Inventory | The inventory from Step 2 |
| Project | `Reset Kibana State Session` |
| Execution environment | Leave blank, or the one your other Kibana templates use |
| Playbook | `playbooks/reset_kibana_state_session.yml` |
| Credentials | The Machine credential from Step 3 |
| Labels | `kibana` (optional) |
| Forks | `0` (default) |
| Limit | Leave blank |
| Verbosity | `0 (Normal)` |
| Job slicing | `1` |
| Timeout | `7200` (seconds; a safety net above the playbook's own one-hour limit per job) |
| Show changes | Off |
| Instance groups | Leave blank |
| Extra variables | Leave as `---`, or set the overrides below |
| Prompt on launch | Leave every box unchecked — the survey covers the inputs |
| Options: **Privilege escalation** | ☐ Unchecked — the playbook already sets `become: true` |
| Options: **Provisioning callbacks** | ☐ Unchecked |
| Options: **Enable webhook** | ☐ Unchecked |
| Options: **Concurrent jobs** | ☐ Unchecked — so two runs never change the same deployments at once |
| Options: **Enable fact storage** | ☐ Unchecked |
| Options: **Prevent instance group fallback** | ☐ Unchecked |

Save.

### Extra variables (optional)

Only needed if something in your environment differs from the defaults. Put any
of these in the template's **Extra variables** box, in YAML:

```yaml
---
aws_region: us-east-1                          # region of the secrets
fed_deployment: cdm-fed                        # the deployment that uses federal_store
script_dir: /opt/reset_kibana_state_session    # where the script runs on the appserver
ca_bundle: /etc/pki/tls/certs/ca-bundle.crt    # trusts the Zscaler CA
aws_ca_bundle: /etc/pki/tls/certs/ca-bundle.crt  # '' to use the AWS CLI's own CA list
script_path: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
job_timeout_seconds: 3600                      # per copy of the script
```

The values shown are the defaults.

---

## Step 5 — Add the survey

Open the template, go to the **Survey** tab, and add these eight questions in
this order. ("Answer variable name" must be exactly as shown — the playbook
reads those names.)

### Question 1 — Deployments

| Field | Value |
| --- | --- |
| Question | `Deployments` |
| Description | `Deployment names separated by commas, spaces or new lines (e.g. cdm-va, cdm-fed), or all for every deployment in deployments.txt. all cannot be combined with names.` |
| Answer variable name | `deployments` |
| Answer type | `Textarea` |
| Required | ✅ Yes |
| Minimum length | `1` |
| Maximum length | `10000` |
| Default answer | Leave blank, so every run is a deliberate choice |

### Question 2 — Run mode

| Field | Value |
| --- | --- |
| Question | `Run mode` |
| Description | `dry-run reports what would change and changes nothing. execute changes the setting.` |
| Answer variable name | `run_mode` |
| Answer type | `Multiple Choice (single select)` |
| Multiple choice options | `dry-run`, `execute` |
| Default answer | `dry-run` |
| Required | ✅ Yes |

### Question 3 — Value to write

| Field | Value |
| --- | --- |
| Question | `Value to write` |
| Description | `set-false writes an explicit false (visible in Advanced Settings). reset-to-default removes the override, like the UI's Reset to default. Both leave the setting false.` |
| Answer variable name | `value_mode` |
| Answer type | `Multiple Choice (single select)` |
| Multiple choice options | `set-false`, `reset-to-default` |
| Default answer | `set-false` |
| Required | ✅ Yes |

### Question 4 — Only these spaces (optional)

| Field | Value |
| --- | --- |
| Question | `Only these spaces (optional)` |
| Description | `Kibana space IDs to limit the run to, separated by commas or spaces (e.g. default, master). Leave blank for every space.` |
| Answer variable name | `spaces` |
| Answer type | `Text` |
| Required | ☐ No |
| Minimum length | `0` |
| Maximum length | `2048` |
| Default answer | Leave blank |

### Question 5 — Skip these spaces (optional)

| Field | Value |
| --- | --- |
| Question | `Skip these spaces (optional)` |
| Description | `Kibana space IDs to leave alone, separated by commas or spaces. Leave blank to skip none.` |
| Answer variable name | `exclude_spaces` |
| Answer type | `Text` |
| Required | ☐ No |
| Minimum length | `0` |
| Maximum length | `2048` |
| Default answer | Leave blank |

Space IDs are the lowercase IDs (`default`, `master`), not display names
(`Default`). The playbook rejects anything else before running.

### Question 6 — Parallel jobs

| Field | Value |
| --- | --- |
| Question | `Parallel jobs` |
| Description | `How many copies of the script run on the appserver at once. Deployments are split evenly between them.` |
| Answer variable name | `parallel_jobs` |
| Answer type | `Integer` |
| Minimum | `1` |
| Maximum | `50` |
| Default answer | `10` |
| Required | ✅ Yes |

Ten copies should keep a 100+ deployment run to minutes rather than tens of
minutes, without starting a hundred AWS CLI processes on the appserver at once.

### Question 7 — Verify Kibana TLS certificates

| Field | Value |
| --- | --- |
| Question | `Verify Kibana TLS certificates` |
| Description | `Keep true. false skips certificate checks for Kibana (last resort).` |
| Answer variable name | `verify_ssl` |
| Answer type | `Multiple Choice (single select)` |
| Multiple choice options | `true`, `false` |
| Default answer | `true` |
| Required | ✅ Yes |

### Question 8 — Verbose logging

| Field | Value |
| --- | --- |
| Question | `Verbose logging` |
| Description | `true logs every Kibana API request (URLs only, never credentials).` |
| Answer variable name | `verbose` |
| Answer type | `Multiple Choice (single select)` |
| Multiple choice options | `false`, `true` |
| Default answer | `false` |
| Required | ✅ Yes |

Finally, make sure the **Survey enabled** toggle at the top of the Survey tab is
**on**. Without it AAP ignores the questions and the playbook stops with
"You must pass a `deployments` variable".

### Or: import the survey through the API

`aap/survey_spec.json` holds the same eight questions. Find the template's ID
(it is in the template's URL), then:

```bash
AAP=https://aap.example.gov
API=$AAP/api/controller/v2          # AAP 2.4: API=$AAP/api/v2
ID=<job template id>

curl -u "<your AAP username>" -H 'Content-Type: application/json' \
     -X POST "$API/job_templates/$ID/survey_spec/" -d @aap/survey_spec.json

curl -u "<your AAP username>" -H 'Content-Type: application/json' \
     -X PATCH "$API/job_templates/$ID/" -d '{"survey_enabled": true}'
```

Open the Survey tab afterwards to check all eight questions are there.

---

## Step 6 — Permissions

On the template's **User access** tab (AAP 2.4: **Access**), give **Execute**
only to the people who should run this change. Anyone with Execute can choose
`execute` in the survey.

For stricter control, see [Optional: dry run, approval, then
execute](#optional-dry-run-approval-then-execute).

---

## Step 7 — First runs

Do these in order. Each is **Launch** on the template, then the survey.

1. **One deployment, dry run.** Deployments `cdm-va` (or any one you know),
   Run mode `dry-run`. Expect a green job. Check the space list in the report
   against that deployment's Kibana UI — if spaces are missing, the API key
   cannot see them.
2. **Everything, dry run.** Deployments `all`, Run mode `dry-run`. Read the
   **RUN SUMMARY** at the end: *spaces needing reset* is how many will change,
   and **Needs attention** lists every deployment that failed (missing secret,
   401/403, unreachable Kibana). Fix those before executing. The job is red
   if anything failed, even in a dry run.
3. **Pilot, execute.** Deployments: two that have the problem (for example the
   ones you already fixed by hand), Run mode `execute`. Confirm in the Kibana
   UI that the setting is now false and dashboards navigate without the error.
4. **Everything, execute.** Deployments `all`, Run mode `execute`.
5. **Proof.** Deployments `all`, Run mode `dry-run` again. Every space should
   be *already false* and *spaces needing reset* `0`. Attach this job's output
   or CSV to the change record.

---

## Reading the output

- **Announce run mode** says DRY-RUN or EXECUTE, and lists the deployments.
- **Show reset output** is each copy of the script's own log and report, one
  line per event, with a `════════ job N of M ════════` banner between copies.
- **Show the summary** is one summary across every deployment, then
  **Needs attention** listing every failed space, then where the files are.
- **Report failed jobs** names any copy of the script that failed, and the
  last task fails the job.

Each run also leaves, on the appserver:

| File | What |
| --- | --- |
| `/opt/reset_kibana_state_session/logs/reset_<timestamp>.log` | Everything the job output shows, with blank lines kept |
| `/opt/reset_kibana_state_session/reports/reset_<timestamp>.csv` | One CSV row per deployment and space: before value, action, detail |
| `/opt/reset_kibana_state_session/reports/<timestamp>/jobN.csv` | Each copy's own CSV, as named in its log |

Actions in the report: `reset`, `already-false`, `would-reset` (dry run),
`skipped` (filtered out by the space options), `reset-unverified` (the write
succeeded but the re-read failed — re-run to confirm), `failed`.

---

## Optional: dry run, approval, then execute

For change control, wrap the template in a workflow so an execute run only
happens after someone approves a dry run.

1. **Automation Execution → Templates → Create template → Create workflow job
   template** (AAP 2.4: **Templates → Add → Add workflow template**). Name it
   `Reset Kibana storeInSessionStorage - approved`, and give it a survey with
   just the **Deployments** question (the same settings as Question 1).
2. In the workflow visualizer, add three nodes in sequence, each running
   **On success** of the one before:
   - **Job template** `Reset Kibana storeInSessionStorage`, with its survey
     answers set in the node: Run mode `dry-run`. The node's survey still
     asks for Deployments because that question is required; enter any
     placeholder (e.g. `all`) — the workflow survey's answer is passed to the
     node at launch and replaces it.
   - **Approval** node: name `Approve the reset`, with a timeout of a few
     hours. The approver reads the dry run's summary before approving.
   - **Job template** `Reset Kibana storeInSessionStorage` again, with Run
     mode `execute`.
3. Give operators **Execute** on the workflow and approvers the **Approve**
   role, and remove direct Execute on the job template from operators.
4. **Test the workflow with a dry run in both nodes first.** Set the third
   node's Run mode to `dry-run` too, launch the workflow for one deployment,
   and open both resulting jobs: their **Extra variables** must show the
   deployment you entered in the workflow survey, not the placeholder. Only
   then switch the third node to `execute`.

---

## Updating the deployment list

`all` reads `deployments.txt` from the project checkout, so the list is version
controlled. To add or remove a deployment, edit `deployments.txt` on `main`
(one per line, or separated by commas; `#` starts a comment). With **Update
revision on launch** checked, the next job uses the new list — no sync needed.

---

## Troubleshooting

| What you see | Cause | Fix |
| --- | --- | --- |
| `You must pass a deployments variable` | Survey not enabled, or no answer | Turn on **Survey enabled** (Step 5) |
| `'all' ... cannot be combined with other names` | `all` plus names in Deployments | Use `all` on its own, or only names |
| `Not valid Kibana space IDs` | A display name such as `Default` in a space question | Use the lowercase space ID, e.g. `default` |
| `not found on <host> with PATH=...: aws` | AWS CLI (or jq) not installed, or outside the PATH | Install it, or add its directory to the front of `script_path` |
| `ca_bundle ... does not exist on the appserver` | Different CA bundle path on this host | Set `ca_bundle` (and `aws_ca_bundle`) in Extra variables |
| `get-secret-value failed ... AccessDenied` | Instance role cannot read that secret | Extend the IAM policy (see Before you start) |
| `get-secret-value failed ... ResourceNotFoundException` | No secret by that name in the region | Check the deployment name, `aws_region`, and `fed_deployment` |
| `no usable credentials in secret` | No `awx_manage_kibana_api_key` in the secret | Add the key to that secret |
| `HTTP 401` | API key wrong, expired, or not the `encoded` form | Replace the key in the secret |
| `HTTP 403` | API key lacks privileges in that space | Grant Advanced Settings privileges in every space |
| `redirected to ...` | `kibana_url` in the secret is not the final address | Set `kibana_url` to the address it redirects to |
| `expected a Kibana settings object` | Something other than Kibana answered (a proxy or login page) | Check `kibana_url` and the network path from the appserver |
| `job did not finish` | A copy of the script ran past `job_timeout_seconds` | Usually an unreachable Kibana; check the deployments listed for that job. Raise `parallel_jobs` or `job_timeout_seconds` if many deployments are slow |
| Fewer spaces than the Kibana UI shows | The API key cannot see every space | Give the key access to all spaces |
