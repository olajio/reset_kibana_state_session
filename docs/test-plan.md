# Test plan: reset_kibana_state_session

Four essential checks of the AAP job template **Reset Kibana
storeInSessionStorage**: that it reaches every deployment, changes the setting
in every space, is safe to re-run, and fixes the error.

Launch the template from **Templates** and note each job ID in the results
table. Only TC-2 changes anything, on one deployment agreed with the change
owner.

---

### TC-1 — Dry run reaches every deployment and changes nothing

Tick `all`, Run mode `dry-run`, everything else at its defaults.

**Expected:** job is green; the **RUN SUMMARY** shows `deployments in report :
6` and `failures : 0`. For one deployment, the number of spaces listed matches
**Stack Management → Spaces** in its Kibana. Nothing is changed.

### TC-2 — Execute resets every space

Tick the agreed deployment, Run mode `execute`.

**Expected:** job is green; every space ends `reset` or `already-false`, with
no failures. In Kibana, **Stack Management → Advanced Settings** in two or
three of its spaces shows `storeInSessionStorage` off.

### TC-3 — Re-running is safe

Repeat TC-2 exactly.

**Expected:** job is green; every space shows `already-false` and the summary
shows `spaces reset to false : 0`.

### TC-4 — The error is gone

In that deployment, open a dashboard, change the time range, open another
dashboard, then go back with the browser's Back button.

**Expected:** no "Unable to completely restore the URL" message, and the URL
contains `_g=(` rather than `_g=h@`. (Bookmarks saved before the reset may
still fail; that is expected.)

---

## Results

| ID | Check | Result (Pass / Fail) | AAP job ID | Notes |
| --- | --- | --- | --- | --- |
| TC-1 | Dry run reaches every deployment and changes nothing | | | |
| TC-2 | Execute resets every space | | | |
| TC-3 | Re-running is safe | | | |
| TC-4 | The error is gone | | | |

For a failure, add the job ID, the survey answers, and expected versus actual
to the Jira task.
