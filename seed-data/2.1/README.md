# HCM 2.1 seed data (tenant `mz`)

This bundle carries the runtime data that the HCM 2.1 install needs **beyond** the Helm
charts and service config — the data that otherwise lives only in a running cluster's
databases. Hand it over **with** the devops/config repo changes.

> ## ⚠️ Read this before treating the bundle as sufficient (audited 2026-08-19)
>
> The previous version of this paragraph promised that a fresh one-click install would
> "reproduce a working environment without any manual cluster surgery." **That is not
> established, and the claim has been withdrawn.** What an audit against the live demo
> reference and both clusters actually found:
>
> 1. **This bundle is a *delta*, not a baseline.** It was authored against an
>    already-populated `mz` tenant and captures the changes applied there. Several files
>    (`06`, `09`, `11`) mutate MDMS rows that **no file here creates** — verified: zero
>    `HCM-ADMIN-CONSOLE.HierarchySchema` INSERTs across all 12 SQL files, and `01` carries
>    no `HCM-PROJECT-TYPES`, `adminSchema` or `ChecklistTemplates` data rows. Where a row
>    is absent the `UPDATE` matches nothing, `psql` still exits 0, and you get a
>    partially-seeded cluster that looks seeded. **What the prerequisite baseline is
>    remains an open question** — it is *not* mdms-v2's Flyway (two DDL files, zero
>    INSERTs) and *not* `health-campaign-mdms@DEV` (no HierarchySchema at all; its
>    projectTypes file is an MDMS **v1 file-based** master under tenant `default`).
> 2. **`apply.sh` applies only `01`–`07`.** `09`, `10`, `11` and `12` are present and are
>    **not** wired in — see the table below. The script now says so loudly at the end of a
>    run instead of staying silent.
> 3. **Everything here is hardcoded to tenant `mz` and locales `en_MZ`/`pt_MZ`/`fr_MZ`**
>    (≈125,453 localization rows across `05`/`10`/`12`), and `apply.sh` parameterises only
>    the DB connection. **Treat this as the `mz` reference install.** Installing on a
>    different tenant needs a substitution pass that does not exist yet.
> 4. **The one-click installer itself had a separate hard stop** — five chart keys named
>    db-migration images that resolved to no Helm chart, so the install panicked ~27% in,
>    before Kafka/ES/Redis and every health service. That is fixed in
>    `dependancy_chart-health-demo-v2.1.yaml` as of 2026-08-19, but it means **this seed
>    bundle has never been exercised on an install produced by this chart.**
>
> Full evidence, the ranked blocker list and the outstanding decisions are in the repo at
> `.ai/` (`confidence.yaml`, `rca-review-packet.md`). The RCA sufficiency gate did **not**
> clear; the changes made on 2026-08-19 are the subset an adversarial review authorised.

## Idempotency

Re-applying is safe against the DB each file was dumped from, but by **mixed** mechanisms —
the previous blanket claim of `INSERT ... WHERE NOT EXISTS` was inaccurate:

| Mechanism | Files |
|---|---|
| `INSERT ... WHERE NOT EXISTS` | `01` (127 guards), `02` (66), `03` (67), `08` (2), `09` (1), `11` (19) |
| `ON CONFLICT ... DO NOTHING` | `04` (76), `05` (26), `10` (88,979), `12` (11,885) |
| bare `UPDATE` | `06`, and `09`'s POLIO row |
| `ALTER TABLE ... DROP NOT NULL` | `07` |

Two caveats:

- **No cross-file atomicity.** `01`/`02`/`03`/`05` wrap in `BEGIN`/`COMMIT`; the rest do
  not, and each file is a separate `psql` invocation. A failure at file *N* leaves
  `1..N-1` committed with no marker and no rollback path.
- **`06` and `09`'s UPDATEs carry `IS DISTINCT FROM` predicates, so 0 rows affected is the
  *correct* outcome on a re-run.** Do not add a `ROW_COUNT = 0` failure guard — it would
  abort a legitimate re-apply and leave `07` unapplied. A row-*existence* assertion is the
  right check if one is wanted.

## What each file seeds

| File | Contents | DB |
|---|---|---|
| `01-mdms.sql` | MDMS master data: HCM admin console (Hierarchy/Admin/Drawer/ReadMe configs), service registry, PGR, expense, attendance, notification. **SSO rows excluded** (see #08). | mdms-v2 (`eg_mdms_data`, `eg_mdms_schema_definition`) |
| `02-accesscontrol.sql` | Roles, actions, roleactions — **38 roleactions**. ⚠️ The earlier claim that this grants **PGR-ADMIN** (Complaints) and **HRMS_ADMIN** (User Management) cards was **false and is withdrawn**: those two strings appeared only in a comment and the file has **zero** roleaction rows for either role. Live demo carries ~929 further `(rolecode, actionid)` pairs; live `mz` has 2,708. | egov-accesscontrol / mdms |
| `03-workflow.sql` | `businessservice` workflow definitions. ⚠️ Guards on the literal `uuid` via 67 `WHERE NOT EXISTS`, **not** on the real unique keys (`uk_eg_wf_businessservice (tenantid, businessService)` and `uk_eg_wf_state_v2 (state, businessserviceid)`). On a DB where these services already exist under different uuids it can raise `23505` and abort the run. Not fixed — pending review. | egov-workflow |
| `04-pgr.sql` | PGR (complaints) service config. 3 junk test departments removed 2026-08-19 (29 → 26 rows); 13 `system-mdms-seed` hex-id rows deliberately kept. See the file header for the `23503` FK risk. | mdms / pgr |
| `05-localization.sql` | UI messages. ⚠️ **Locale coverage is badly skewed:** 24,589 rows total, of which `en_MZ` is **52 rows — 51 of them module `expense`** plus one `hcm-test` placeholder. Practically, **English HCM UI is absent from this file**; the ~35,727 `en_MZ` rows live in `10`, which is not applied. | egov-localization |
| `06-hierarchyschema-handover.sql` | Repoints the `campaign` HierarchySchema row `ADMIN → HANDOVER`. ⚠️ Does **not create** the row — it is a bare `UPDATE`, so it is a silent no-op on a fresh tenant. Its sole consumer is project-factory's `getBoundaryOnWhichWeSplit` (`campaignUtils.ts:4032`), which is **bypassed when `isUnifiedCampaign` is true** (generation is delegated to excel-ingestion). Retained because that flag is a per-campaign request-body field with no server-side default, and four other call sites are unassessed. See the file header. | mdms-v2 |
| `07-project-department-nullable.sql` | Makes `project.department` nullable so departmentless campaign projects persist. *(Belongs in the project-service Flyway migration — see note in file.)* | project |
| `08-sso-identityproviders.TEMPLATE.sql` | **Template only.** OIDC/SSO providers are environment-specific (per-env OAuth clientId + URLs); fill placeholders per environment. Skip if not using SSO. | mdms-v2 |

### Present in this bundle but **NOT applied** by `apply.sh`

These four were authored on 2026-07-30 *after* `apply.sh` was written and were never wired
in. They are still not wired in — that is a **pending decision**, not an oversight, and
`apply.sh` now prints a warning naming them. Applying them by hand is the current option.

| File | Contents | Why it is not wired in |
|---|---|---|
| `09-project-types-active.sql` | Activates `POLIO`, inserts `CO-DELIVERY` in `HCM-PROJECT-TYPES.projectTypes`. | Its POLIO half is a bare `UPDATE` against a row nothing here creates, so on a fresh tenant it would activate `CO-DELIVERY` and silently not activate `POLIO` — inconsistent master data. Gated on the baseline question. |
| `10-localization-ui-labels-mirror.sql` | 88,979 rows — the demo→mz UI-label sweep. Carries **35,727 `en_MZ`** rows and the only copy of `hcm-campaignmanager` (7,278 keys). | Shares 5,278 `(locale, module, code)` keys with `05`, of which **1,184 have different text**. Under `ON CONFLICT DO NOTHING` the apply *order* silently and permanently picks the winner — a one-way migration with no rollback. Also ships ~8,079 DSS boundary-name passthrough rows and 76 campaign-instance checklist codes. Needs a curate-or-ship decision. |
| `11-mdms-adminschema-checklist-mirror.sql` | 19 rows: `adminSchema` + `ChecklistTemplates`. | Its `adminSchema` half is already satisfied on live `mz` (10 of 11 rows present); its `ChecklistTemplates` half is a genuine gap (0 of 8 present) but is **incomplete** — the live gap is 19 identifiers and it covers 8. It also lacks `boundary.POLIO`, the one `adminSchema` row live `mz` actually misses. |
| `12-localization-labels-full-mirror.sql` | 11,885 rows — 3-locale label mirror. | Same `ON CONFLICT` ordering hazard as `10`. All 76 of its `hcm-checklist` rows are anomalous (question sentences used as codes, literal `pt_MZ`/`Yes`/`No` as code values). |

## The HCMADMIN bootstrap user

The HCM console admin (`HCMADMIN`, tenant `mz`, roles BOUNDARY_MANAGER,
SUPERUSER, HRMS_ADMIN, PGR-ADMIN, CAMPAIGN_MANAGER) is seeded **declaratively**,
not by SQL — see `charts/core-services/egov-user/templates/hcmadmin-seed-job.yaml`
(a post-install Helm hook). Enable it with `hcmSeed.enabled=true` after creating
the password secret:

```
kubectl -n egov create secret generic hcmadmin-seed --from-literal=password='<strong-pass>'
```

The login password is **never** stored in git.

## Apply

```
# A) direct psql
export PGHOST=... PGPORT=5432 PGDATABASE=... PGUSER=... PGPASSWORD=...
./apply.sh
# B) pull creds from a running egov-user pod (in-cluster DB)
export KUBECONFIG=/path/to/kubeconfig
FROM_POD=1 ./apply.sh
```

`apply.sh` skips any file that is absent (logging it loudly) rather than aborting — a
curated subset such as the `HCM-2.1-Migration` package, which ships without `05`/`10`/`12`,
used to die at the first missing file and silently leave `06` and `07` unapplied.
**Read the summary block it prints at the end**; a skipped file means the cluster is not
fully seeded even though the script exits 0.

### Post-apply — both steps are required

```
# 1. refresh the MDMS cache
kubectl rollout restart deploy/mdms-v2 deploy/project-factory -n egov

# 2. bust the localization cache — step 1 alone is NOT enough
kubectl exec -n backbone deploy/redis -- redis-cli DEL messages computedMessages
```

Step 2 is not optional: `egov-localization` caches in Redis under the HASH keys `messages`
and `computedMessages`, and **those survive pod restarts**, so newly seeded messages are not
served until they are deleted. Adjust the selector to your redis workload — see
`POST-APPLY-localization-cache-bust.md`. Browsers additionally cache localisation in
IndexedDB, so a user seeing raw codes needs **Clear-site-data**, not a reload.

## Not included

- **20k HANDOVER boundary hierarchy + boundary data.** Bulk runtime data loaded through the
  boundary bulk/excel-ingestion flow, not a static SQL seed. Load it post-install via the
  boundary upload (HANDOVER hierarchy definition + the boundary workbook) once services are
  up. *(This is by design.)*
- **The base MDMS master data these files assume.** See the warning at the top — `06`, `09`
  and `11` mutate rows nothing here creates, and the prerequisite is an open question.
  **This is not by design; it is an unresolved gap.**
- **The 2.0-era Postman collections** (`HCM_seed.postman_collection.json`,
  `Localization_Seed_Script.postman_collection.json`, ~104,747 entries). They exist only as
  GitBook attachments on the docs site — `find -iname '*postman*'` across both one-click
  repos returns nothing. An installer following the docs needs them and cannot get them
  from git.
- **A tenant/locale substitution pass.** See warning item 3.
- **Files `09`–`12`.** Present but not applied — see the table above.

## Provenance / safety

- No credentials or secrets are committed. SSO client secrets are not stored in
  MDMS; SSO clientId/URLs are templated (#08). The HCMADMIN password comes from a
  K8s Secret. DB creds are read at runtime by `apply.sh`, never written to disk.
