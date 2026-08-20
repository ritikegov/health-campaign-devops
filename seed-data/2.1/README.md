# HCM 2.1 seed data (tenant `mz`) — sourced from hcm-demo

This bundle carries the runtime data a fresh HCM 2.1 one-click install needs **beyond** the Helm charts
and service config. The authoritative files are **exported from the hcm-demo reference environment
(tenant `demo`) and rewritten to tenant `mz`** (demo→mz), so a fresh install reproduces demo.

## Authoritative demo-sourced files (applied by `apply.sh`)

| File | Rows | Source | Notes |
|---|---|---|---|
| `19-demo-mdms-schema-def-mz.sql` | 311 | demo `eg_mdms_schema_definition` | MDMS schema defs; apply first |
| `21-demo-mdms-data-mz.sql` | 6,573 | demo `eg_mdms_data` | ALL MDMS masters (access control, project types, targetConfigs, adminSchema, ChecklistTemplates, service registry, …). Excludes runtime-generated `FormConfig`/`TransformedFormConfig`/`AppConfigCache`/`AppFlowConfig`. |
| `22-demo-products-mz.sql` | 109 products + 99 variants | demo `product` + `product_variant` | The product catalogue campaigns reference (incl. CO-DELIVERY's `PVAR-2026-07-06-000909/910`). |
| `20-demo-localization-mz.sql` | 79,631 | demo localization API | 25 reusable UI-label modules × en/pt/fr_MZ. Excludes boundary-name, per-campaign (`CMP-*`), DSS-data and `hcm-base-*` DATA (pollution). |

Still needed for the non-MDMS/non-product/non-localization parts (kept as-is, hand-built):
`03-workflow.sql` (eg_wf_* business services), `04-pgr.sql` (PGR + departments), `06-hierarchyschema-handover.sql`
(campaign HierarchySchema repoint — largely redundant now that 21 carries HierarchySchema), `07-project-department-nullable.sql`
(project.department ALTER), `08-sso-identityproviders.TEMPLATE.sql` (SSO, environment-specific template).

## Superseded (NOT applied — kept for history)
`01-mdms`, `02-accesscontrol`, `05-localization`, `09-project-types-active`, `10-localization-ui-labels-mirror`,
`11-mdms-adminschema-checklist-mirror`, `12-localization-labels-full-mirror` — all replaced by the complete
demo-sourced `19`/`20`/`21`.

## demo→mz substitution applied to the demo export
`tenantid` `demo`→`mz`; locales `en_DEMO`/`pt_DEMO`/`fr_DEMO`→`en_MZ`/`pt_MZ`/`fr_MZ`; `"demo"` value→`"mz"`;
`demo-`→`mz-` (index/topic prefixes); `demo.`→`mz.` (schema qualifiers). English words (`demography`…) and
mixed-case `Demo` are preserved. Verified on a throwaway Postgres: all files apply, are idempotent
(`ON CONFLICT DO NOTHING`), and leak zero `demo`-tenant/locale rows.

## Idempotency (per file)
`19`/`21` `ON CONFLICT (tenantid,…) DO NOTHING`; `22` `ON CONFLICT (id) DO NOTHING`; `20`
`ON CONFLICT (tenantid,locale,module,code) DO NOTHING`. `21` uses fresh `gen_random_uuid()` ids to avoid
colliding with any existing row's `id`. Re-running the whole bundle is safe.

## Apply
```
# A) direct psql
export PGHOST=... PGPORT=5432 PGDATABASE=... PGUSER=... PGPASSWORD=... ; ./apply.sh
# B) pull creds from a running egov-user pod (in-cluster DB)
export KUBECONFIG=/path/to/kubeconfig ; FROM_POD=1 ./apply.sh
```

### Post-apply (BOTH required)
```
# 1. refresh MDMS cache
kubectl rollout restart deploy/mdms-v2 deploy/project-factory -n egov
# 2. bust the localization Redis cache (survives pod restarts; step 1 alone is NOT enough)
kubectl exec -n backbone deploy/redis -- redis-cli DEL messages computedMessages
```
Browsers cache localisation + the boundary tree in IndexedDB — a user seeing raw codes or a truncated
boundary picker needs **Clear-site-data**, not a reload.

## Campaign creation — what `21` enables and one demo-inherited limitation
`21` carries the `HCM-ADMIN-CONSOLE.schemas` rows `target-<projectType>` (e.g. `target-CO-DELIVERY`,
`target-INT-CAMP`, `target-POLIO`). excel-ingestion **requires** the matching `target-<projectType>` row
or campaign processing fails with `Schema 'target-<projectType>' not found in MDMS`. These are ordinary
MDMS **data** rows (not schema defs), so `apply.sh` handles them by running `21`. A unified campaign then
reaches status `created` (UI "Upcoming") end-to-end via API — verified on `mz` for CO-DELIVERY.

**Known limitation (inherited from demo, NOT a seed defect):** the deployed excel-ingestion
(`dynamic-target-columns` build) generates boundary target columns per projectType *product*
(`..._TARGET_CO-DELIVERY_VITAMIN_A_SUPPLEMENT`, `..._AZITHROMYCIN`), but `HCM-ADMIN-CONSOLE.targetConfigs`
still lists legacy column names (CO-DELIVERY → `SPAQ1/SPAQ2/NOPV2/IVERMETCIN/ALBENDAZOLE`; MR-DN → `SMC_*`).
project-factory extracts targets by those stale names → no match → **0 projects** are created for new
campaigns (mappings then fail non-blockingly; the campaign still reaches `created`). This mismatch is
present in hcm-demo itself (confirmed live), so the seed reproduces demo faithfully. To make new campaigns
create projects, update `targetConfigs` per projectType to the dynamic per-product column names — an
upstream/demo data decision, deliberately **not** baked into this demo-mirroring seed.

## Not included (by design — runtime, not seed)
- **20k HANDOVER boundary hierarchy + data** — bulk runtime load via boundary/excel-ingestion.
- **The 2.0-era Postman collections** — GitBook attachments on the docs site.

## Provenance
Exported from hcm-demo on 2026-08-20 (`eg_mdms_data`, `eg_mdms_schema_definition`, `product`,
`product_variant` via pgAdmin CSV; localization via demo's open `localization/messages/v1/_search`).
