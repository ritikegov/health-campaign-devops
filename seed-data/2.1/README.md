# HCM 2.1 seed data (tenant `mz`)

This bundle carries the runtime data that the HCM 2.1 install needs **beyond**
the Helm charts and service config — the data that otherwise lives only in a
running cluster's databases. Hand it over **with** the devops/config repo changes
so a fresh one-click install reproduces a working environment without any manual
cluster surgery.

Everything is **idempotent** (`INSERT ... WHERE NOT EXISTS`, update-if-changed,
`DROP NOT NULL`), so re-applying is safe.

## What each file seeds

| File | Contents | DB |
|---|---|---|
| `01-mdms.sql` | MDMS master data: HCM admin console (Hierarchy/Admin/Drawer/ReadMe configs), service registry, PGR, expense, attendance, notification. **SSO rows excluded** (see #08). | mdms-v2 (`eg_mdms_data`, `eg_mdms_schema_definition`) |
| `02-accesscontrol.sql` | Roles, actions, roleactions — grants the UI cards/menus incl. **PGR-ADMIN** (Complaints) and **HRMS_ADMIN** (User Management). | egov-accesscontrol / mdms |
| `03-workflow.sql` | `businessservice` workflow definitions. | egov-workflow |
| `04-pgr.sql` | PGR (complaints) service config. | mdms / pgr |
| `05-localization.sql` | `en_MZ` / `pt_MZ` / `fr_MZ` UI messages. | egov-localization |
| `06-hierarchyschema-handover.sql` | Repoints the `campaign` HierarchySchema row `ADMIN → HANDOVER` (COUNTRY..VILLAGE) so **campaign template generation** works. | mdms-v2 |
| `07-project-department-nullable.sql` | Makes `project.department` nullable so departmentless campaign projects persist. *(Belongs in the project-service Flyway migration — see note in file.)* | project |
| `08-sso-identityproviders.TEMPLATE.sql` | **Template only.** OIDC/SSO providers are environment-specific (per-env OAuth clientId + URLs); fill placeholders per environment. Skip if not using SSO. | mdms-v2 |

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

Then refresh MDMS caches:

```
kubectl rollout restart deploy/mdms-v2 deploy/project-factory -n egov
```

## Not included (needs a live load, not a seed file)

- **20k HANDOVER boundary hierarchy + boundary data.** This is bulk runtime data
  loaded through the boundary bulk/excel-ingestion flow, not a static SQL seed.
  Load it post-install via the boundary upload (HANDOVER hierarchy definition +
  the boundary workbook) once services are up.

## Provenance / safety

- No credentials or secrets are committed. SSO client secrets are not stored in
  MDMS; SSO clientId/URLs are templated (#08). The HCMADMIN password comes from a
  K8s Secret. DB creds are read at runtime by `apply.sh`, never written to disk.
