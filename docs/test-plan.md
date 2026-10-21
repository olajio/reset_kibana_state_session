# Test plan: reset_kibana_state_session

Six checks of the AAP job template **Reset Kibana storeInSessionStorage**. The
script has already run successfully in production, so these focus on the
survey, the newer options (excluding deployments, skipping spaces) and the
end result in Kibana.

Launch the template from **Templates** (not Relaunch, which skips the survey)
and note each job ID in the results table.

**Safety:** dry runs change nothing and are safe anywhere. Only TC-5 uses
`execute`, on one deployment agreed with the change owner.

---

### TC-1 — Survey is correct

Click **Launch** and check the survey before answering.

**Expected:** **Deployments** offers `all` plus the six deployments (`cdm-fed`,
`cdm-va`, `cdm-dos`, `cdm-tva`, `cdm-abmc`, `cdm-nasa`). **Exclude deployments**
offers the six without `all`. **Run mode** is single select, default `dry-run`.

### TC-2 — Dry run of all deployments

Tick `all`; leave everything else at its defaults.

**Expected:** `DRY-RUN MODE ... Checking 6 deployment(s)`, then a **RUN
SUMMARY** with `deployments in report : 6`. Any rows under **Needs attention**
are findings to report (usually access problems). Record the job's duration.

### TC-3 — Exclude deployments

Tick `all`; under **Exclude deployments** tick `cdm-nasa` and `cdm-tva`.

**Expected:** `Excluding 2 deployment(s): cdm-tva, cdm-nasa` and `Checking 4
deployment(s)`; neither excluded deployment appears in the output.

### TC-4 — Skip spaces, with and without spaces after commas

Two dry runs of one deployment, with **Skip spaces** set to `default,admin`,
then to `default, admin` (use real space IDs from that deployment).

**Expected (both):** those spaces show `skipped` / `excluded by
--exclude-spaces`; every other space is still checked.

### TC-5 — Execute on one deployment

Tick the agreed deployment, Run mode `execute`. Then run the same thing again.

**Expected:** first run is green, every space ends `reset` or `already-false`,
no failures. The second run shows every space `already-false` (nothing
changed). In Kibana, **Stack Management → Advanced Settings** in any space of
that deployment shows `storeInSessionStorage` off.

### TC-6 — The error is gone

In that deployment, open a dashboard, change the time range, open another
dashboard and go back with the browser's Back button.

**Expected:** no "Unable to completely restore the URL" message; the URL
contains `_g=(` (full state) rather than `_g=h@` (a hash). Bookmarks saved
before the reset may still fail — that is expected.

---

## Results

| ID | Check | Result (Pass / Fail) | AAP job ID | Notes |
| --- | --- | --- | --- | --- |
| TC-1 | Survey is correct | | | |
| TC-2 | Dry run of all deployments | | | |
| TC-3 | Exclude deployments | | | |
| TC-4 | Skip spaces, both comma forms | | | |
| TC-5 | Execute on one deployment | | | |
| TC-6 | The error is gone | | | |

For a failure, add the job ID, the survey answers, and expected versus actual
to the Jira task.
