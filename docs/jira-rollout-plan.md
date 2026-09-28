# Jira epic and tasks: `state:storeInSessionStorage` fleet rollout

Ready to paste into Jira. Estimates and priorities are placeholders — adjust to
your team's conventions. Issue descriptions deliberately avoid tables and nested
formatting so they paste cleanly into Jira's editor.

---

## EPIC

**Summary:** Eliminate Kibana "Unable to completely restore the URL" error fleet-wide by resetting `state:storeInSessionStorage`

**Issue Type:** Epic
**Epic Name:** Kibana storeInSessionStorage Reset
**Priority:** High
**Labels:** `kibana`, `advanced-settings`, `fleet-rollout`, `cdm`

**Description:**

Kibana 8.19.2 users see "Unable to completely restore the URL, be sure to use the share functionality" when navigating between dashboards.

**Root cause:** The advanced setting `state:storeInSessionStorage` is explicitly set to `true` on affected deployments (ICAP, FDB and others). When true, Kibana stores global app state in the browser's `sessionStorage` and puts only a short hash in the URL (e.g. `?_g=h@8c48049`). After a cluster change or upgrade those sessionStorage entries go stale, the hash becomes unresolvable, and the error appears. It was initially assumed to be a broken-link problem; it is a Kibana setting.

**Fix:** Reset `state:storeInSessionStorage` to its default of `false`. Validated manually in the ICAP deployment — the error no longer occurs.

**Scope:** 100+ deployments, each with multiple Kibana spaces. The setting is space-scoped, so every space in every deployment must be reset. Automated via `reset_kibana_state_session.sh`, which reads deployments from `deployments.txt`, pulls Kibana credentials per deployment from AWS Secrets Manager (`cdm-fed` → `federal_store`, `cdm-<agency>` → `agency_<agency>_store`), enumerates all spaces via `GET /api/spaces/space`, and posts to `/s/<space_id>/api/kibana/settings/state:storeInSessionStorage`.

**Out of scope:** Any other Kibana advanced setting; the Kibana upgrade itself.

**Definition of done:**
- `state:storeInSessionStorage` is `false` in every space of every deployment, with a report as evidence
- The source that set it to `true` is identified and corrected so the fix does not regress on the next deploy
- A drift check is in place and the runbook is handed to Ops

---

## Suggested order and dependencies

| # | Task | Blocked by |
|---|---|---|
| 1 | Review and merge the reset automation script | — |
| 2 | Confirm secret schema and naming across all deployments | — |
| 3 | Verify IAM and Kibana privileges for the rollout account | — |
| 4 | Build the full deployment inventory (`deployments.txt`) | — |
| 5 | Fleet-wide dry run and triage the report | 1, 2, 3, 4 |
| 6 | Identify what set the value to `true` (regression source) | — |
| 7 | Raise the change request for the fleet rollout | 5 |
| 8 | Pilot rollout on ICAP and FDB | 5, 7 |
| 9 | Wave rollout to all remaining deployments | 8 |
| 10 | Post-rollout validation and evidence capture | 9 |
| 11 | Fix the provisioning source so the setting stays `false` | 6 |
| 12 | Add a recurring drift check | 9, 11 |
| 13 | Runbook and Ops handoff | 9, 11 |
| 14 | Stakeholder comms and close out user tickets | 10 |

Tasks 1–4 and 6 can run in parallel; 6 and 11 are the ones that stop this from recurring.

---

## TASK 1

**Summary:** Review and merge the `state:storeInSessionStorage` reset automation script
**Issue Type:** Task
**Priority:** High
**Estimate:** 3 points
**Labels:** `kibana`, `automation`, `code-review`

**Description:**

Peer-review and merge `reset_kibana_state_session.sh` (branch `claude/jolly-bohr-cofew7` in `olajio/reset_kibana_state_session`).

What the script does per deployment: derives the Secrets Manager secret name, reads the Kibana URL and credentials, enumerates all spaces via `GET /api/spaces/space`, posts `{"value": false}` to `/s/<space_id>/api/kibana/settings/state:storeInSessionStorage` for each space, re-reads the setting to verify, and prints a per-space report with optional CSV.

Decision to make during review: write an explicit `false` (default behaviour, leaves a visible, auditable override in Advanced Settings) versus `--reset-to-default`, which sends `{"value": null}` and removes the override entirely, matching the manual UI fix click-for-click. Both end up behaving identically. Record the choice so the pilot and rollout are consistent.

**Acceptance criteria:**
- PR reviewed and merged to the default branch
- `tests/run_tests.sh` passes (runs against a mock Kibana and a stub `aws`; needs no AWS or live cluster)
- Explicit-`false` vs `--reset-to-default` decision recorded on this ticket
- Reviewers confirm the script is read-only in `--dry-run` mode

---

## TASK 2

**Summary:** Confirm Secrets Manager secret schema and naming across all deployments
**Issue Type:** Task
**Priority:** Highest
**Estimate:** 3 points
**Labels:** `kibana`, `aws`, `secrets-manager`, `blocker`

**Description:**

The script needs the Kibana URL and credentials out of each deployment's secret, but the JSON key names were never confirmed beyond the known naming convention for the secrets themselves. It currently auto-detects the common spellings (`kibana_url`, `kibana_username`, `kibana_password`, plus `elastic_*`, bare `url`/`username`/`password`, and API-key variants) and takes the first match. Key names can be overridden without a code change via `SECRET_KEYS_URL`, `SECRET_KEYS_USERNAME`, `SECRET_KEYS_PASSWORD`, `SECRET_KEYS_API_KEY`.

Confirm the actual schema so the fleet run does not fail deployment-by-deployment on credential parsing.

**Acceptance criteria:**
- Actual JSON key names documented for `federal_store` and a representative sample of `agency_<agency>_store` secrets
- Confirmed whether the schema is consistent across all 100+ secrets, and any exceptions listed
- Confirmed whether secrets contain the Kibana URL; if not, a `KIBANA_URL_TEMPLATE` pattern is agreed (supports `{{deployment}}` and `{{agency}}`)
- Confirmed the secret-name mapping holds for every deployment: `cdm-fed` → `federal_store`, `cdm-<agency>` → `agency_<agency>_store`, with any exceptions recorded
- Required `SECRET_KEYS_*` overrides (if any) recorded on this ticket

---

## TASK 3

**Summary:** Verify IAM and Kibana privileges for the rollout account
**Issue Type:** Task
**Priority:** High
**Estimate:** 2 points
**Labels:** `kibana`, `iam`, `access`

**Description:**

Confirm the identity running the rollout can complete it end to end, before the fleet run rather than during it.

Two distinct permission layers: AWS (`secretsmanager:GetSecretValue` on every deployment secret) and Kibana (privilege to change advanced settings in every space — in practice a superuser role, since Advanced Settings are space-scoped saved objects and a space-limited role will fail on spaces it cannot reach).

**Acceptance criteria:**
- Confirmed `secretsmanager:GetSecretValue` covers `federal_store` and all `agency_*_store` secrets, in the correct region and account(s)
- Confirmed the Kibana user or API key in each secret can write advanced settings in every space
- Confirmed whether one AWS profile/region covers the whole fleet or the run must be split (`--profile` / `--region` are supported per run)
- Network path from the run host to every Kibana endpoint confirmed, including whether a custom CA bundle is needed (`--ca-bundle`)
- Any deployment needing different credentials is listed for separate handling

---

## TASK 4

**Summary:** Build the full deployment inventory for the rollout
**Issue Type:** Task
**Priority:** High
**Estimate:** 2 points
**Labels:** `kibana`, `inventory`

**Description:**

Produce the authoritative list of deployments to process, one per line, in the format the script consumes (`deployments.txt`; `#` comments and blank lines ignored). The repo currently holds a four-line sample.

The list drives the entire rollout, so a deployment missing here is a deployment that keeps the error.

**Acceptance criteria:**
- Complete list of all 100+ deployments, in `cdm-<agency>` form, committed or stored in an agreed location
- Cross-checked against the source of truth for deployments so none are missed
- Decommissioned or unreachable deployments excluded, with a note on each
- Deployments confirmed as already correct (or intentionally excluded) called out
- Agreed how the list is split into rollout waves

---

## TASK 5

**Summary:** Fleet-wide dry run and triage of the report
**Issue Type:** Task
**Priority:** High
**Estimate:** 3 points
**Labels:** `kibana`, `dry-run`, `validation`
**Blocked by:** Tasks 1, 2, 3, 4

**Description:**

Run `./reset_kibana_state_session.sh --dry-run --report-csv dryrun.csv` across the full inventory. Dry run reads the current value per space and reports what would change, without writing anything.

This is the first fleet-wide measurement of the blast radius, and it surfaces access and connectivity failures while they are still cheap to fix.

**Acceptance criteria:**
- Dry run completed against every deployment in the inventory
- CSV report attached to this ticket
- Counts established: spaces needing reset, already `false`, and failures
- Every `failed` row triaged and classified (credentials, network, permissions, unreachable deployment)
- All non-deployment-related failures resolved, or the affected deployments explicitly deferred with a reason
- Total space count known, for rollout duration planning (roughly three HTTP calls per space, sequential)

---

## TASK 6

**Summary:** Identify what set `state:storeInSessionStorage` to `true`
**Issue Type:** Task
**Priority:** Highest
**Estimate:** 5 points
**Labels:** `kibana`, `root-cause`, `iac`, `regression-risk`

**Description:**

The setting was explicitly set to `true` on affected deployments — it is not the Kibana default. Something set it: a provisioning script, Terraform/Ansible, a deployment template, a saved-object import, or a manual change copied across deployments as a pattern.

Until that source is found, the fleet reset is a temporary fix. The next deploy or cluster rebuild can set it back to `true` and the error returns across the fleet.

**Acceptance criteria:**
- Source of the `true` value identified (repo, pipeline, template or documented manual step) and linked on this ticket
- Confirmed whether it is applied at deployment provisioning time, on upgrade, or per space
- Confirmed whether new deployments would also be created with `true`
- Original reason for setting it to `true` established, so the change is not reversing a deliberate decision (it is sometimes set to shorten URLs — confirm no one relies on that)
- Findings feed Task 11

---

## TASK 7

**Summary:** Raise and get approval for the fleet-wide change request
**Issue Type:** Task
**Priority:** High
**Estimate:** 2 points
**Labels:** `kibana`, `change-management`
**Blocked by:** Task 5

**Description:**

Submit the change request covering the configuration change across all deployments and spaces, for CAB or equivalent approval.

**Acceptance criteria:**
- CR raised with scope (deployment and space counts from the dry run), root cause, and the API call being made
- Backout plan documented: re-running with the value set to `true` restores the previous state per space; the dry-run CSV records the prior value of every space
- Risk assessment included — the change is a per-space advanced setting, takes effect on page load, requires no restart and causes no downtime
- Maintenance window agreed if required
- Approval recorded before Task 8 starts

---

## TASK 8

**Summary:** Pilot rollout on ICAP and FDB
**Issue Type:** Task
**Priority:** High
**Estimate:** 2 points
**Labels:** `kibana`, `pilot`, `rollout`
**Blocked by:** Tasks 5, 7

**Description:**

Run the script for real against the two deployments where the problem is already understood, ICAP having been fixed manually. Small enough to inspect every row of the report, real enough to prove the automation end to end.

Command shape: `./reset_kibana_state_session.sh --yes --report-csv pilot.csv <deployment> <deployment>`

**Acceptance criteria:**
- Both deployments run with a clean report: every space `reset` or `already-false`, zero failures, exit code 0
- Setting confirmed as `false` in the Kibana UI (Stack Management → Kibana → Advanced Settings) in a sample of spaces, including at least one non-default space
- Error confirmed gone by navigating between dashboards in a previously affected space
- Idempotency confirmed: a second run reports `already-false` and writes nothing
- Report attached and the run duration recorded, to extrapolate the full rollout

---

## TASK 9

**Summary:** Wave rollout to all remaining deployments
**Issue Type:** Task
**Priority:** High
**Estimate:** 5 points
**Labels:** `kibana`, `rollout`
**Blocked by:** Task 8

**Description:**

Roll out to the rest of the fleet in the agreed waves, capturing a CSV report per wave.

The script is sequential, roughly three HTTP calls per space, so a full sweep takes a while; the deployment list can be split across parallel invocations if needed. A failing deployment does not stop the run — it is reported and the sweep continues — so each wave's report must be reviewed rather than relying on overall exit status alone.

**Acceptance criteria:**
- Every deployment in the inventory processed
- A CSV report retained per wave and attached
- Every `failed` row resolved and the deployment re-run to a clean result, or explicitly deferred with a reason and a follow-up ticket
- Any `reset-unverified` rows (write succeeded, re-read failed) re-run and confirmed
- Final tally reported against the dry-run baseline from Task 5

---

## TASK 10

**Summary:** Post-rollout validation and evidence capture
**Issue Type:** Task
**Priority:** Medium
**Estimate:** 2 points
**Labels:** `kibana`, `validation`
**Blocked by:** Task 9

**Description:**

Independently confirm the fix from a user's point of view, not only from the script's own report, and assemble the evidence pack for the change record.

**Acceptance criteria:**
- Full verification re-run (or `--dry-run` over the whole fleet) showing every space `already-false` and zero spaces needing a reset
- Manual UI check on a sample across several agencies, including non-default spaces: navigate between dashboards, confirm no "Unable to completely restore the URL" error and that URLs carry full state rather than an `?_g=h@...` hash
- Confirmed with affected users that the error no longer reproduces
- Evidence pack attached (final report CSVs, sample screenshots) and linked to the change record

---

## TASK 11

**Summary:** Fix the provisioning source so the setting stays `false`
**Issue Type:** Task
**Priority:** Highest
**Estimate:** 3 points
**Labels:** `kibana`, `iac`, `regression-prevention`
**Blocked by:** Task 6

**Description:**

Correct whatever Task 6 identified so `state:storeInSessionStorage` is no longer set to `true` on deploy, upgrade or new deployment creation. Without this, the fleet reset is undone the next time the offending automation runs.

**Acceptance criteria:**
- Source corrected (setting removed, or explicitly set to `false`) and merged
- Change covers new deployments as well as existing ones
- Verified on a rebuild or redeploy of at least one deployment: the value is still `false` afterwards
- Any documentation or templates that told engineers to set it to `true` updated

---

## TASK 12

**Summary:** Add a recurring drift check for `state:storeInSessionStorage`
**Issue Type:** Task
**Priority:** Medium
**Estimate:** 3 points
**Labels:** `kibana`, `monitoring`, `automation`
**Blocked by:** Tasks 9, 11

**Description:**

Schedule the script in `--dry-run` mode on a recurring basis so any deployment or space drifting back to `true` is caught before users report it. Dry run makes no changes and exits non-zero on failures, which makes it usable as a check.

**Acceptance criteria:**
- Scheduled job (cron, pipeline or equivalent) running the dry run fleet-wide on an agreed cadence
- Alert or notification raised when any space reports `would-reset`, or on failures
- Job credentials provisioned and stored per the practice agreed in Task 3
- Runbook entry describing what to do when the check fires (run the script for that deployment)

---

## TASK 13

**Summary:** Runbook and handoff to Ops
**Issue Type:** Task
**Priority:** Medium
**Estimate:** 2 points
**Labels:** `kibana`, `documentation`, `handoff`
**Blocked by:** Tasks 9, 11

**Description:**

Document the problem, the fix and the tooling so this is resolvable by anyone on the team without rediscovering the root cause. The repo README covers the script; this task covers the operational side.

**Acceptance criteria:**
- Runbook published in the team's usual location, covering: the user-visible symptom, the root cause, how to run the script for one deployment or the whole fleet, how to read the report, and how to back the change out
- Prerequisites documented (`bash`, `curl`, `jq`, `aws` CLI; required AWS and Kibana privileges)
- Secret naming convention and confirmed JSON schema documented, including any `SECRET_KEYS_*` overrides
- Walkthrough session held with Ops, or recorded
- Runbook linked from the epic and from the drift-check alert

---

## TASK 14

**Summary:** Stakeholder comms and close out user-reported tickets
**Issue Type:** Task
**Priority:** Medium
**Estimate:** 1 point
**Labels:** `kibana`, `comms`
**Blocked by:** Task 10

**Description:**

Tell the people who reported the error that it is fixed, and close the loop on the original tickets — including the dev team who suspected a Kibana setting, since that read was correct.

**Acceptance criteria:**
- Affected agency stakeholders notified that the issue is resolved fleet-wide
- Original user-reported tickets updated with the root cause and linked to this epic, then closed
- Note circulated that users may need to open a fresh browser tab or clear an existing stale session URL
- Short root-cause summary shared with the wider team so the pattern is recognised if it recurs elsewhere

---

## Notes on sequencing

**Tasks 6 and 11 matter most.** Everything else resets a value that something
explicitly set to `true`. If that something still runs, the error comes back
fleet-wide and this epic gets reopened. Both are marked Highest priority, and 6
runs parallel to the rollout so it is not discovered late.

**Task 2 is a genuine blocker.** The script auto-detects secret JSON key names
among the common spellings because the real schema was never confirmed. If the
keys differ, the fleet run fails on every deployment at the credential step. It
is a short check against one or two secrets that de-risks the whole rollout.
