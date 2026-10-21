# Test plan: reset_kibana_state_session

Test cases for `reset_kibana_state_session.sh` and the AAP job template
**Reset Kibana storeInSessionStorage**. They cover the script on the appserver,
the AAP job and its survey, and — most importantly — that resetting
`state:storeInSessionStorage` actually removes the "Unable to completely
restore the URL" error in Kibana.

Record the result of every test case in the [results table](#results) and
attach the evidence it asks for.

---

## Safety rules — read before starting

1. **Every change is limited to the test spaces.** Any `execute` run — the CLI
   with `--yes`, or AAP with Run mode `execute` — must name only the
   `rkss-test-*` spaces (`--spaces` on the CLI, **Spaces** in the survey).
   Never run `execute` against real spaces or `all`: that is the production
   rollout itself and needs the change request.
2. **Dry runs are safe anywhere**, including `all`. They read settings and
   change nothing.
3. **Test spaces exist in one deployment only**, `TEST_DEP`, agreed with the
   change owner (ideally a non-production deployment, or one of the
   deployments already fixed by hand).
4. If anything ever changes a space you did not intend, stop and tell the
   change owner. (Setting a real space to `false` is the intended fix and
   harmless, but it should still only happen through the approved rollout.)

---

## What you need

| Need | Used by |
| --- | --- |
| SSH access to the appserver the AAP job uses, with `bash`, `curl`, `jq` and the AWS CLI | Sections B and setup |
| **Execute** on the AAP template, and permission to copy it (TC-29 only) | Section C |
| A Kibana login for `TEST_DEP` that can view Advanced Settings and copy dashboards between spaces | Section D, UI checks |
| The `TEST_DEP` name, agreed with the change owner | Everywhere |
| Optional: a Linux workstation with `git`, `bash` 4+, `curl`, `jq`, `python3` and ansible-core 2.15+ | Section A |

Record which version you are testing: the commit on `main`
(`git rev-parse --short HEAD`), or the **Revision** shown in any AAP job's
details.

---

## Test setup

Run these on the appserver, as your own user — the script does not need root.

### 1. Point at the test deployment

```bash
TEST_DEP=cdm-xxxx                     # the agreed test deployment
if [ "$TEST_DEP" = cdm-fed ]; then SECRET=federal_store; else SECRET="agency_${TEST_DEP#cdm-}_store"; fi

SECRET_JSON="$(aws secretsmanager get-secret-value --region us-east-1 \
               --secret-id "$SECRET" --query SecretString --output text)"
KB="$(jq -r .kibana_url <<<"$SECRET_JSON")"; KB="${KB%/}"
KEY="$(jq -r .awx_manage_kibana_api_key <<<"$SECRET_JSON")"
unset SECRET_JSON

# Kibana API helper. The key is passed to curl through a pipe, so it never
# appears in the process list or your shell history.
kb()  { curl -sS -K <(printf 'header = "Authorization: ApiKey %s"\n' "$KEY") \
             -H 'kbn-xsrf: true' -H 'Content-Type: application/json' "$@"; }
# Show a space's current value
val() { kb "$KB/s/$1/api/kibana/settings" \
          | jq -c '.settings["state:storeInSessionStorage"] // "unset (default false)"'; }
# Set a space's value to true (test spaces only!)
settrue() { kb -X POST "$KB/s/$1/api/kibana/settings/state:storeInSessionStorage" -d '{"value":true}' >/dev/null; val "$1"; }

RKSS=/opt/reset_kibana_state_session/reset_kibana_state_session.sh
```

`$RKSS` is put on the appserver by any run of the AAP template; if it is not
there yet, do TC-20 first.

### 2. Create three test spaces

```bash
for s in a b c; do
  kb -X POST "$KB/api/spaces/space" -d "{\"id\":\"rkss-test-$s\",\"name\":\"RKSS test $s\"}" | jq -c '{id, name}'
done
settrue rkss-test-a        # -> {"userValue":true}
settrue rkss-test-b        # -> {"userValue":true}
val rkss-test-c            # -> "unset (default false)"
```

| Space | Starting value | Purpose |
| --- | --- | --- |
| `rkss-test-a` | `true` | Reset by the script |
| `rkss-test-b` | `true` | Reproduces the original error; reset-to-default |
| `rkss-test-c` | unset (default `false`) | Must be left alone |

If creating a space returns 403, the API key cannot manage spaces: ask a Kibana
admin to create the three spaces in **Stack Management → Spaces** with exactly
these IDs, then run the `settrue` / `val` lines.

### 3. Put a dashboard in rkss-test-b (for Section D)

In Kibana: **Stack Management → Saved objects**, select any two dashboards,
**Copy to space** → `rkss-test-b`. Copy their related objects too.

---

## A. Automated test suites

Optional on a workstation; they need no AWS, Kibana or AAP.

### TC-01 — Script test suite passes · P2

**Steps**

```bash
git clone https://github.com/olajio/reset_kibana_state_session.git && cd reset_kibana_state_session
./tests/run_tests.sh
```

**Expected:** ends with `All N checks passed.` and exit status 0.

### TC-02 — Playbook test suite passes · P2

**Steps:** `./tests/run_playbook_tests.sh` (needs ansible-core 2.15+, e.g.
`python3 -m venv ~/ans && ~/ans/bin/pip install 'ansible-core>=2.15'`, then
`ANSIBLE_BIN_DIR=~/ans/bin ./tests/run_playbook_tests.sh`).

**Expected:** ends with `All N playbook checks passed.`

### TC-03 — Survey matches deployments.txt · P1

**Steps:** `python3 aap/build_survey_spec.py --check`

**Expected:** `... matches .../deployments.txt (6 deployments)`, exit status 0.

---

## B. The script on the appserver

### TC-04 — Help and option errors · P2

**Steps**

```bash
$RKSS --help | less          # read it
$RKSS --bogus; echo "exit=$?"
```

**Expected:** help describes `all`, `--exclude-deployments`, `--spaces` and
`--exclude-spaces`. The bogus option prints `unknown option: --bogus` and
`exit=2`.

### TC-05 — Dry run lists every space and changes nothing · P1

**Steps**

```bash
$RKSS --dry-run "$TEST_DEP"; echo "exit=$?"
val rkss-test-a
```

**Expected**

- The log shows `secret 'agency_..._store'` (or `federal_store`) and
  `Kibana at https://...`.
- One report row per space. **The number of spaces equals the count in Kibana
  under Stack Management → Spaces** (including the three test spaces). If any
  are missing, the API key cannot see them — record it as a defect.
- `rkss-test-a` and `rkss-test-b`: `DRY RUN - would set
  state:storeInSessionStorage to false (currently true)`.
- `rkss-test-c`: `already false (unset(default false)); nothing to do`.
- `exit=0`, and `val rkss-test-a` still shows `{"userValue":true}`.

### TC-06 — Every deployment resolves to the right secret · P1

**Steps:** `time $RKSS --dry-run all`

**Expected**

- `'all': read 6 deployment(s) from` followed by the deployments file (the
  full path `/opt/reset_kibana_state_session/deployments.txt`, or just
  `deployments.txt` if you run it from that directory).
- `cdm-fed` uses `secret 'federal_store'`; every other deployment uses
  `agency_<name>_store` (e.g. `cdm-va` → `agency_va_store`).
- Each deployment logs `Kibana at https://...` and lists its spaces.
- Record the final summary and the run time. Any `failed` rows are findings to
  report (they are usually access problems, not script defects).

### TC-07 — Execute changes only the selected test space · P1

**Steps**

```bash
$RKSS --yes --spaces rkss-test-a "$TEST_DEP"; echo "exit=$?"
val rkss-test-a; val rkss-test-b; val rkss-test-c
```

**Expected**

- `rkss-test-a: state:storeInSessionStorage reset (true -> false)`
- Every other space is `skipped` with `not selected by --spaces`.
- `exit=0`. Values: `a` → `{"userValue":false}`, `b` → still
  `{"userValue":true}`, `c` → still unset.
- In Kibana, space `rkss-test-a` → **Stack Management → Advanced Settings**,
  search `storeInSessionStorage`: the switch is off.

### TC-08 — Re-running changes nothing · P1

**Steps:** `$RKSS --yes --verbose --spaces rkss-test-a "$TEST_DEP"`

**Expected:** `rkss-test-a: already false (false); nothing to do`, and no
`DEBUG: POST` line anywhere in the output.

### TC-09 — Reset to default · P2

**Steps**

```bash
$RKSS --yes --reset-to-default --spaces rkss-test-b "$TEST_DEP"
val rkss-test-b
settrue rkss-test-b           # put it back to true for Section D
```

**Expected:** `rkss-test-b: state:storeInSessionStorage reset (true ->
unset(default false))`; `val` shows `"unset (default false)"`. In the Kibana UI
the setting shows no customisation (no "Reset to default" link).

### TC-10 — Skip spaces, with and without spaces after commas · P1

**Steps**

```bash
$RKSS --dry-run --exclude-spaces 'rkss-test-a,rkss-test-b' "$TEST_DEP"
$RKSS --dry-run --exclude-spaces 'rkss-test-a, rkss-test-b' "$TEST_DEP"
```

**Expected (both runs):** `rkss-test-a` and `rkss-test-b` are `skipped` with
`excluded by --exclude-spaces`; every other space is still checked.

### TC-11 — Exclude deployments from "all" · P1

**Steps**

```bash
$RKSS --dry-run --exclude-deployments cdm-nasa,cdm-tva all
$RKSS --dry-run --exclude-deployments 'cdm-nasa, cdm-tva' all
```

**Expected (both runs):** `excluding 2 deployment(s): cdm-tva cdm-nasa` and
`4 deployment(s) to process`; no `=== cdm-tva ===` or `=== cdm-nasa ===`
section.

### TC-12 — Exclusion edge cases · P2

**Steps and expected**

| Command | Expected |
| --- | --- |
| `$RKSS --dry-run --exclude-deployments cdm-fed,cdm-va,cdm-dos,cdm-tva,cdm-abmc,cdm-nasa all; echo $?` | `--exclude-deployments excludes every deployment in the list - nothing to do`, exit `2` |
| `$RKSS --dry-run --exclude-deployments all all; echo $?` | `--exclude-deployments cannot contain 'all'`, exit `2` |
| `$RKSS --dry-run --exclude-deployments cdm-nosuch "$TEST_DEP"; echo $?` | Warning `'cdm-nosuch' is not in the deployment list, so there is nothing to exclude`; runs normally; exit `0` |

### TC-13 — "all" cannot be mixed with names on the command line · P2

**Steps:** `$RKSS --dry-run all "$TEST_DEP"; echo $?`

**Expected:** `'all' means every deployment in the deployments file and cannot
be combined with other deployment names`, exit `2`, nothing processed.

### TC-14 — Changing settings needs confirmation · P1

**Steps**

```bash
# a) not interactive, no --yes
$RKSS --spaces rkss-test-b "$TEST_DEP" < /dev/null; echo "exit=$?"
# b) interactive: answer n at the prompt
$RKSS --spaces rkss-test-b "$TEST_DEP"; echo "exit=$?"
val rkss-test-b
```

**Expected:** (a) `not running interactively, so cannot ask for confirmation:
pass --yes ...`, `exit=2`. (b) Prompts `Continue? [y/N]`; after `n`:
`aborted by user`, `exit=1`. `rkss-test-b` is still `{"userValue":true}`.

### TC-15 — CSV report · P2

**Steps:** `$RKSS --dry-run --report-csv ~/rkss-report.csv "$TEST_DEP"`, then
open the file in a spreadsheet.

**Expected:** a header row `deployment,space_id,space_name,value_before,action,detail`
and one row per space, each with six columns, matching the table printed on
screen.

### TC-16 — One failing deployment does not stop the others · P1

**Steps:** `$RKSS --dry-run cdm-doesnotexist "$TEST_DEP"; echo "exit=$?"`

**Expected:** `cdm-doesnotexist` fails reading `agency_doesnotexist_store`
(`ResourceNotFoundException` or `AccessDenied`); `$TEST_DEP` is still processed
in full; the report has a `failed` row for `cdm-doesnotexist`; `exit=1`.

### TC-17 — Works from any directory · P3

**Steps:** `cd /tmp && $RKSS --dry-run all; cd -`

**Expected:** `'all': read 6 deployment(s) from
/opt/reset_kibana_state_session/deployments.txt` (the file beside the script).

### TC-18 — The API key never appears in output or reports · P1

**Steps**

```bash
$RKSS --dry-run --verbose --report-csv ~/rkss-v.csv "$TEST_DEP" > ~/rkss-v.log 2>&1
grep -c -F "${KEY:0:12}" ~/rkss-v.log ~/rkss-v.csv
```

**Expected:** both counts are `0`. The log has `DEBUG: GET https://...` lines
showing URLs only.

---

## C. The AAP job template

Launch **Reset Kibana storeInSessionStorage** from the template (not with
Relaunch, which skips the survey). Note each job's ID for the results table.

### TC-19 — The survey · P1

**Steps:** click **Launch** and inspect the survey before answering.

**Expected**

- Nine questions: Deployments, Exclude deployments, Run mode, Value to write,
  Spaces, Skip spaces, Parallel jobs, Verify Kibana TLS, Verbose logging.
- **Deployments** (multiple select, required) offers `all`, `cdm-fed`,
  `cdm-va`, `cdm-dos`, `cdm-tva`, `cdm-abmc`, `cdm-nasa`, nothing ticked.
- **Exclude deployments** (multiple select, optional) offers the six
  deployments and **not** `all`.
- **Run mode** is single select, default `dry-run`. **Value to write** defaults
  to `set-false`, **Parallel jobs** to `10`, **Verify Kibana TLS** to `true`,
  **Verbose logging** to `false`.

### TC-20 — Dry run of one deployment · P1

**Steps:** tick `$TEST_DEP` only; leave every other answer at its default.

**Expected**

- Job succeeds (green).
- Output includes `🔒 DRY-RUN MODE - no changes will be made ... Checking 1
  deployment(s) in 1 parallel job(s): <TEST_DEP>`, a `════════ job 1 of 1`
  banner, the script's own log and report, then `RUN SUMMARY -
  state:storeInSessionStorage (dry-run)` and the log and CSV paths.
- Those two files exist on the appserver under
  `/opt/reset_kibana_state_session/logs/` and `.../reports/`.

### TC-21 — Dry run of all · P1

**Steps:** tick `all`.

**Expected:** `Checking 6 deployment(s) in 6 parallel job(s)`; the summary
reports `deployments in report : 6`; the totals match TC-06's command-line
run. Record the job's duration.

### TC-22 — "all" ticked together with a deployment · P2

**Steps:** tick `all` and `cdm-va`.

**Expected:** no error; the same 6 deployments as TC-21.

### TC-23 — "all" with Exclude deployments · P1

**Steps:** tick `all`; under **Exclude deployments** tick `cdm-nasa` and
`cdm-tva`.

**Expected:** `Excluding 2 deployment(s): cdm-tva, cdm-nasa`, then `Checking 4
deployment(s) in 4 parallel job(s)`; neither excluded deployment appears in the
output.

### TC-24 — Excluding everything stops before the appserver · P2

**Steps:** tick `$TEST_DEP`, and tick `$TEST_DEP` under **Exclude
deployments** too.

**Expected:** the job fails at **Fail when every deployment is excluded** with
`exclude_deployments leaves nothing to do`; no later task runs (in particular
no "Copy the script ..." task), and no new file appears in
`/opt/reset_kibana_state_session/logs/`.

### TC-25 — Execute on one test space · P1

**Steps:** first `settrue rkss-test-a` on the appserver. Then launch: tick
`$TEST_DEP`, Run mode `execute`, **Spaces** `rkss-test-a`.

**Expected:** `⚠ EXECUTE MODE - state:storeInSessionStorage WILL be set to
false in the selected spaces of 1 deployment(s) ...`;
`rkss-test-a: state:storeInSessionStorage reset (true -> false)`; summary
`spaces reset to false : 1`; job green. `val rkss-test-a` → `{"userValue":false}`;
`val rkss-test-b` still `{"userValue":true}`.

### TC-26 — Skip spaces, with and without spaces after commas · P1

**Steps:** two dry runs of `$TEST_DEP`, with **Skip spaces** set to
`rkss-test-a,rkss-test-b`, then to `rkss-test-a, rkss-test-b`.

**Expected (both):** `rkss-test-a` and `rkss-test-b` are `skipped` with
`excluded by --exclude-spaces`; summary `spaces skipped : 2`; every other space
is checked.

### TC-27 — An invalid space ID is rejected up front · P2

**Steps:** dry run of `$TEST_DEP` with **Skip spaces** `Default`.

**Expected:** the job fails with `Not valid Kibana space IDs: Default` before
any task touches the appserver.

### TC-28 — Parallel jobs · P3

**Steps:** dry runs of `all` with **Parallel jobs** `1`, then `3`.

**Expected:** `in 1 parallel job(s)`, then `in 3 parallel job(s)`; both
summaries have the same totals as TC-21.

### TC-29 — A failure turns the job red but still shows everything · P1

**Steps:** on the template, **⋮ → Copy**. In the copy's **Extra variables**,
add `aws_region: us-west-2` (where the secrets do not exist) and save. Launch
the copy: tick `$TEST_DEP`, dry run. Delete the copy afterwards.

**Expected:** the job fails (red), but the output still shows the script's
output and the `RUN SUMMARY` with `deployments with failures : 1` and a
**Needs attention** row naming the secret error. The last task reports `1 of 1
job(s) did not complete cleanly`.

### TC-30 — TLS verification off, verbose on · P3

**Steps:** dry run of `$TEST_DEP` with **Verify Kibana TLS** `false`; then
another with **Verbose logging** `true`.

**Expected:** the first shows `--insecure: Kibana TLS certificates will NOT be
verified`; the second shows `DEBUG: GET https://...` lines, with no API key
anywhere in the output.

### TC-31 — Two runs never overlap · P3

**Steps:** launch a dry run of `all` twice in quick succession.

**Expected:** the second job waits (Pending) until the first finishes.

---

## D. The actual fix, in Kibana

### TC-32 — Reproduce the original error with the setting on · P1

**Steps**

1. Confirm `val rkss-test-b` is `{"userValue":true}`.
2. In Kibana, switch to space `rkss-test-b` and open one of the copied
   dashboards. Change the time range.
3. Look at the address bar: the URL contains `_g=h@` followed by a short hash.
4. Copy the URL, open a private/incognito window, log in, and paste it.

**Expected:** Kibana shows **"Unable to completely restore the URL, be sure to
use the share functionality."** This confirms the test space reproduces the
problem. (If it does not appear, record it — Section D depends on it.)

### TC-33 — The error is gone after the reset · P1

**Steps**

1. Reset the space through AAP: tick `$TEST_DEP`, Run mode `execute`,
   **Spaces** `rkss-test-b`. (Or on the CLI:
   `$RKSS --yes --spaces rkss-test-b "$TEST_DEP"`.)
2. Reload the dashboard in `rkss-test-b` (the setting is read on page load) and
   change the time range again.
3. The URL now contains `_g=(` with the full state, and no `h@` hash.
4. Copy that URL into a new private window.
5. Open the second dashboard, then go back with the browser's Back button.

**Expected:** steps 4 and 5 show no error; the dashboard opens with the same
time range. URLs copied *before* the reset (with `h@`) still fail — that is
expected, as they point at browser storage that no longer exists.

---

## Cleanup

```bash
for s in a b c; do kb -X DELETE "$KB/api/spaces/space/rkss-test-$s" -w '%{http_code}\n' -o /dev/null; done
rm -f ~/rkss-report.csv ~/rkss-v.csv ~/rkss-v.log
unset KEY KB SECRET
```

Expected: `204` for each space. Delete the template copy from TC-29 if not done
already. Deleting a space also deletes the dashboards copied into it.

---

## Reporting a defect

For each failing test case, record in the Jira task:

- The test case ID, and the commit or AAP **Revision** tested
- The exact command, or the survey answers
- The full output: the AAP job ID, or the console output saved to a file
- Expected versus actual result
- The CSV report, if one was written

---

## Results

| ID | Test case | Priority | Result (Pass / Fail / Blocked) | Evidence (job ID, file) | Notes |
| --- | --- | --- | --- | --- | --- |
| TC-01 | Script test suite passes | P2 | | | |
| TC-02 | Playbook test suite passes | P2 | | | |
| TC-03 | Survey matches deployments.txt | P1 | | | |
| TC-04 | Help and option errors | P2 | | | |
| TC-05 | Dry run lists every space and changes nothing | P1 | | | |
| TC-06 | Every deployment resolves to the right secret | P1 | | | |
| TC-07 | Execute changes only the selected test space | P1 | | | |
| TC-08 | Re-running changes nothing | P1 | | | |
| TC-09 | Reset to default | P2 | | | |
| TC-10 | Skip spaces, both comma forms (CLI) | P1 | | | |
| TC-11 | Exclude deployments from "all" (CLI) | P1 | | | |
| TC-12 | Exclusion edge cases | P2 | | | |
| TC-13 | "all" cannot be mixed with names on the CLI | P2 | | | |
| TC-14 | Changing settings needs confirmation | P1 | | | |
| TC-15 | CSV report | P2 | | | |
| TC-16 | One failing deployment does not stop the others | P1 | | | |
| TC-17 | Works from any directory | P3 | | | |
| TC-18 | The API key never appears in output or reports | P1 | | | |
| TC-19 | The survey | P1 | | | |
| TC-20 | AAP dry run of one deployment | P1 | | | |
| TC-21 | AAP dry run of all | P1 | | | |
| TC-22 | "all" ticked together with a deployment | P2 | | | |
| TC-23 | "all" with Exclude deployments | P1 | | | |
| TC-24 | Excluding everything stops before the appserver | P2 | | | |
| TC-25 | AAP execute on one test space | P1 | | | |
| TC-26 | Skip spaces, both comma forms (AAP) | P1 | | | |
| TC-27 | An invalid space ID is rejected up front | P2 | | | |
| TC-28 | Parallel jobs | P3 | | | |
| TC-29 | A failure turns the job red but shows everything | P1 | | | |
| TC-30 | TLS verification off, verbose on | P3 | | | |
| TC-31 | Two runs never overlap | P3 | | | |
| TC-32 | Reproduce the original error with the setting on | P1 | | | |
| TC-33 | The error is gone after the reset | P1 | | | |

Priorities: **P1** must pass before the rollout; **P2** should pass, or have an
agreed workaround; **P3** nice to confirm.
