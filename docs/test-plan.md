# Test plan: reset_kibana_state_session

## Jira card

**Summary:** Test the storeInSessionStorage reset AAP job

**Issue Type:** Task · **Priority:** High · **Estimate:** 2 points (about 1–2
hours) · **Labels:** `kibana`, `testing`, `aap`

**Description:**

The AAP job template **Reset Kibana storeInSessionStorage** sets the Kibana
setting `state:storeInSessionStorage` to `false` in every space of each
deployment. That fixes the "Unable to completely restore the URL" error. It
needs an independent check that it works correctly, is safe to run, and
reports failures clearly.

Test plan: the six checks below. Before starting, agree with the change owner
which deployment to use (`TEST_DEP`), and which one of its spaces to use as the
test space. Only that deployment is changed; every other check is a dry run.

**Acceptance criteria:**

- All six checks pass, with AAP job IDs recorded in the results table.
- The test space was reset by the job (TC-3 shows `reset (true -> false)`, not
  only `already-false`).
- No deployment other than `TEST_DEP` was changed.
- Any failure is reported on the ticket with its job ID, survey answers, and
  expected versus actual result.
- The template copy from TC-6 is deleted.

---

## Setup

In `TEST_DEP`, pick one space that few people use: the **test space**. Note its
ID — shown under **Stack Management → Spaces**, and in the URL as
`/s/<id>/app/...`. The default space's ID is `default`.

In the test space, open **Stack Management → Advanced Settings**, search
`storeInSessionStorage`, turn it **on** and save. This briefly brings back the
old behaviour in that one space, so the checks below can see the job change
it.

Launch the template from **Templates** (not Relaunch) for every check.

---

### TC-1 — Dry run reaches every deployment and changes nothing

Tick `all`, Run mode `dry-run`, everything else at its defaults.

**Expected**

- Job is green. The **RUN SUMMARY** shows `deployments in report : 6` and
  `failures : 0`.
- For `TEST_DEP`, the number of spaces listed matches **Stack Management →
  Spaces** in its Kibana.
- The test space shows `DRY RUN - would set state:storeInSessionStorage to
  false (currently true)`.
- Afterwards, the setting in the test space is **still on**.

### TC-2 — Exclusions are respected

Tick `all`, Run mode `dry-run`. Under **Exclude deployments** tick any one
deployment other than `TEST_DEP`. In **Skip spaces**, enter the test space's ID.

**Expected:** `Excluding 1 deployment(s): ...`, and that deployment does not
appear in the output. In `TEST_DEP`, the test space shows `skipped` /
`excluded by --exclude-spaces`.

### TC-3 — Execute resets every space

Tick `TEST_DEP`, Run mode `execute`.

**Expected**

- Job is green, with no failures.
- The test space shows `state:storeInSessionStorage reset (true -> false)`.
- Every other space shows `reset` or `already-false`.
- In Kibana, **Advanced Settings** shows the setting **off** in the test space
  and in one other space.

### TC-4 — Re-running is safe

Repeat TC-3 exactly.

**Expected:** job is green; every space shows `already-false`, and the summary
shows `spaces reset to false : 0`.

### TC-5 — The error is gone

In the test space, open a dashboard, change the time range, open another
dashboard, then go back with the browser's Back button.

**Expected:** no "Unable to completely restore the URL" message, and the URL
contains `_g=(` rather than `_g=h@`. (Bookmarks saved before the reset may
still fail; that is expected.)

### TC-6 — A failure is reported, not hidden

On the template, **⋮ → Copy**. In the copy's **Extra variables** add
`aws_region: us-west-2` (where the secrets do not exist) and save. Launch the
copy: tick `TEST_DEP`, Run mode `dry-run`. Delete the copy afterwards.

**Expected:** the job is **red**, but the output still shows the run, and the
**RUN SUMMARY** shows `deployments with failures : 1` with a **Needs
attention** row naming the secret error. The last task says `1 of 1 job(s) did
not complete cleanly`.

---

## Results

| ID | Check | Result (Pass / Fail) | AAP job ID | Notes |
| --- | --- | --- | --- | --- |
| TC-1 | Dry run reaches every deployment and changes nothing | | | |
| TC-2 | Exclusions are respected | | | |
| TC-3 | Execute resets every space | | | |
| TC-4 | Re-running is safe | | | |
| TC-5 | The error is gone | | | |
| TC-6 | A failure is reported, not hidden | | | |

For a failure, add the job ID, the survey answers, and expected versus actual
to the Jira task.
