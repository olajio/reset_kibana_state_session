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
3. On the AAP side the playbook validates your answers, expands `all` to every
   deployment in `deployments.txt` in the checkout, and removes any you chose
   to exclude. Nothing reaches the appserver until the inputs are valid.
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

The survey has nine questions. **Deployments** and **Exclude deployments** are
multiple-select, so every deployment has to be listed in the survey as an
option. Those options are generated from `deployments.txt`, so the survey and
the file never disagree.

### 5a. Generate the survey from deployments.txt

`deployments.txt` must hold your real deployment list (the repository ships
with four examples). From a checkout of this repository:

```bash
python3 aap/build_survey_spec.py
```

This rewrites `aap/survey_spec.json` with every deployment as an option (plus
`all` for Deployments). Commit and push both files. `python3
aap/build_survey_spec.py --check` tells you whether the spec is up to date.

### 5b. Load it into the template (recommended)

Uploading the spec sets all nine questions at once — far easier than typing a
hundred options into the UI. It **replaces** the template's whole survey, so
any questions you created by hand are swapped for these nine (with the same
variable names). Find the template's ID (it is in the template's URL), then:

```bash
AAP=https://aap.example.gov
API=$AAP/api/controller/v2          # AAP 2.4: API=$AAP/api/v2
ID=<job template id>

curl -u "<your AAP username>" -H 'Content-Type: application/json' \
     -X POST "$API/job_templates/$ID/survey_spec/" -d @aap/survey_spec.json

curl -u "<your AAP username>" -H 'Content-Type: application/json' \
     -X PATCH "$API/job_templates/$ID/" -d '{"survey_enabled": true}'
```

Open the Survey tab afterwards: there should be nine questions, and the
**Survey enabled** toggle at the top should be on.

### 5c. Or build it in the UI

Open the template's **Survey** tab and create these questions in this order.
"Answer variable name" must be exactly as shown — the playbook reads those
names, and silently ignores any other.

For the options of questions 1 and 2, print the list with:

```bash
python3 aap/build_survey_spec.py --choices     # all, then every deployment
```

#### Question 1 — Deployments

| Field | Value |
| --- | --- |
| Question | `Deployments` |
| Description | `Tick 'all' for every deployment in deployments.txt, or tick individual deployments. Deployments ticked alongside 'all' are already included.` |
| Answer variable name | `deployments` |
| Answer type | `Multiple Choice (multiple select)` |
| Multiple choice options | `all`, then every deployment, one per option (the `--choices` output) |
| Default answer | None ticked, so every run is a deliberate choice |
| Required | ✅ Yes |

Ticking `all` runs every deployment in `deployments.txt` — the file, not the
survey's option list, so a deployment added to the file is included even
before the survey is regenerated. Ticking `all` together with individual
deployments is fine: they are already part of `all`.

#### Question 2 — Exclude deployments

| Field | Value |
| --- | --- |
| Question | `Exclude deployments` |
| Description | `Optional. Deployments to leave out, e.g. when 'all' is ticked.` |
| Answer variable name | `exclude_deployments` |
| Answer type | `Multiple Choice (multiple select)` |
| Multiple choice options | Every deployment, **without** `all` (the `--choices` output minus its first line) |
| Default answer | None ticked |
| Required | ☐ No |

Exclusions are applied after `all` is expanded. Excluding a deployment that
was not selected does nothing (the job output says so); excluding every
selected deployment stops the job before anything runs.

#### Question 3 — Run mode

| Field | Value |
| --- | --- |
| Question | `Run mode` |
| Description | `dry-run reports what would change and changes nothing. execute changes the setting.` |
| Answer variable name | `run_mode` |
| Answer type | `Multiple Choice (single select)` — **not** multiple select |
| Multiple choice options | `dry-run`, `execute` |
| Default answer | `dry-run` |
| Required | ✅ Yes |

#### Question 4 — Value to write

| Field | Value |
| --- | --- |
| Question | `Value to write` |
| Description | `set-false writes an explicit false (visible in Advanced Settings). reset-to-default removes the override, like the UI's Reset to default. Both leave the setting false.` |
| Answer variable name | `value_mode` |
| Answer type | `Multiple Choice (single select)` |
| Multiple choice options | `set-false`, `reset-to-default` |
| Default answer | `set-false` |
| Required | ✅ Yes |

#### Question 5 — Spaces

| Field | Value |
| --- | --- |
| Question | `Spaces` |
| Description | `Optional. Only these Kibana space IDs, separated by commas (e.g. default,admin or default, admin). Leave blank for every space.` |
| Answer variable name | `spaces` |
| Answer type | `Text` |
| Required | ☐ No |
| Minimum length | `0` |
| Maximum length | `2048` |
| Default answer | Leave blank |

#### Question 6 — Skip spaces

| Field | Value |
| --- | --- |
| Question | `Skip spaces` |
| Description | `Optional. Kibana space IDs to leave alone, separated by commas (e.g. default,admin,infra or default, admin, infra). Leave blank to skip none.` |
| Answer variable name | `exclude_spaces` |
| Answer type | `Text` |
| Required | ☐ No |
| Minimum length | `0` |
| Maximum length | `2048` |
| Default answer | Leave blank |

Both space questions accept `default,admin,infra` and `default, admin, infra`
alike. Space IDs are the lowercase IDs (`default`, `admin`), not display names
(`Default`); the playbook rejects anything else before running. The skipped
spaces apply to every deployment in the run.

#### Question 7 — Parallel jobs

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

#### Question 8 — Verify Kibana TLS

| Field | Value |
| --- | --- |
| Question | `Verify Kibana TLS` |
| Description | `Keep true. false skips certificate checks for Kibana (last resort).` |
| Answer variable name | `verify_ssl` |
| Answer type | `Multiple Choice (single select)` |
| Multiple choice options | `true`, `false` |
| Default answer | `true` |
| Required | ✅ Yes |

#### Question 9 — Verbose logging

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
**on**. A new survey starts disabled, and while it is off AAP shows no
questions at launch and the playbook stops with "You must pass a `deployments`
variable".

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

1. **One deployment, dry run.** Tick one deployment you know (e.g. `cdm-va`),
   Run mode `dry-run`. Expect a green job. Check the space list in the report
   against that deployment's Kibana UI — if spaces are missing, the API key
   cannot see them.
2. **Everything, dry run.** Tick `all`, Run mode `dry-run`. Read the
   **RUN SUMMARY** at the end: *spaces needing reset* is how many will change,
   and **Needs attention** lists every deployment that failed (missing secret,
   401/403, unreachable Kibana). Fix those before executing. The job is red
   if anything failed, even in a dry run.
3. **Pilot, execute.** Tick two deployments that have the problem (for example
   the ones you already fixed by hand), Run mode `execute`. Confirm in the Kibana
   UI that the setting is now false and dashboards navigate without the error.
4. **Everything, execute.** Tick `all`, Run mode `execute`. To hold some
   deployments back (for example ones awaiting a separate change), tick them
   under **Exclude deployments**.
5. **Proof.** Tick `all`, Run mode `dry-run` again. Every space should
   be *already false* and *spaces needing reset* `0`. Attach this job's output
   or CSV to the change record.

---

## Reading the output

- **Announce run mode** says DRY-RUN or EXECUTE, and lists the deployments.
  **Announce excluded deployments** lists any you excluded.
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
   just the **Deployments** and **Exclude deployments** questions (the same
   settings as Questions 1 and 2). To upload those two from the spec:
   `jq '.spec |= .[:2]' aap/survey_spec.json > /tmp/wf.json`, then POST
   `/tmp/wf.json` to `workflow_job_templates/<ID>/survey_spec/` as in Step 5b.
2. In the workflow visualizer, add three nodes in sequence, each running
   **On success** of the one before:
   - **Job template** `Reset Kibana storeInSessionStorage`, with its survey
     answers set in the node: Run mode `dry-run`. The node's survey still
     asks for Deployments because that question is required; tick any
     placeholder (e.g. `all`) — the workflow survey's answers are passed to
     the node at launch and replace it.
   - **Approval** node: name `Approve the reset`, with a timeout of a few
     hours. The approver reads the dry run's summary before approving.
   - **Job template** `Reset Kibana storeInSessionStorage` again, with Run
     mode `execute`.
3. Give operators **Execute** on the workflow and approvers the **Approve**
   role, and remove direct Execute on the job template from operators.
4. **Test the workflow with a dry run in both nodes first.** Set the third
   node's Run mode to `dry-run` too, launch the workflow for one deployment,
   and open both resulting jobs: their **Extra variables** must show the
   deployment you ticked in the workflow survey, not the placeholder. Only
   then switch the third node to `execute`.

---

## Updating the deployment list

`all` reads `deployments.txt` from the project checkout, so the list is version
controlled. The survey's options, though, are stored in AAP, not read from git.
To add or remove a deployment:

1. Edit `deployments.txt` on `main` (one per line, or separated by commas; `#`
   starts a comment).
2. Run `python3 aap/build_survey_spec.py`, and commit and push both files.
3. Upload the new survey (Step 5b). Until you do, the change already applies to
   `all` — **Update revision on launch** makes every job use the latest file —
   but a new deployment cannot be ticked individually, and a removed one is
   still offered.

---

## Troubleshooting

| What you see | Cause | Fix |
| --- | --- | --- |
| The survey does not appear at launch | **Survey enabled** is off, or the job was started with **Relaunch**, a schedule or a workflow node (none of which show the survey) | Turn on **Survey enabled** (Step 5); launch from the template itself |
| `You must pass a deployments variable` | Survey not enabled, or no answer | Turn on **Survey enabled** (Step 5) |
| `run_mode must be 'dry-run' or 'execute' - got '['dry-run']'` (or the same for `value_mode`) | The question is **Multiple Choice (multiple select)**, which sends a list | Change its answer type to **Multiple Choice (single select)** |
| A deployment is not offered in Deployments | The survey was built before it was added to `deployments.txt` | Regenerate and upload the survey (see Updating the deployment list) |
| `exclude_deployments leaves nothing to do` | Every selected deployment is also excluded | Untick some exclusions |
| `exclude_deployments names deployment(s) that were not selected` | An excluded deployment was not part of the selection | Nothing to fix — it is a note; check it was not a mis-click |
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
