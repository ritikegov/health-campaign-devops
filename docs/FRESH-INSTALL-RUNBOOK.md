# HCM 2.1 fresh-install runbook (proven end-to-end 2026-08-23)

Every step below was executed and verified live on an empty cluster + empty database
(testhealth-k8supgrade, tenant `mz`, db `testhealthdb21`): install → seed → HCMADMIN bootstrap →
public-domain smoke → unified CO-DELIVERY campaign to `created` with **5 projects persisted**.

## 0. Prerequisites
- A clone of this repo at a path **without spaces** — the deployer joins shell commands unquoted,
  so `~/eGov 2/...` breaks every helm call with `read …: is a directory`.
- Go (1.26 tested), helm (v4.2.4 tested), kubectl with the target cluster as current-context.
- helm 4 is nil-strict: this repo renders 70/70 release-chart services clean as of `8bcccaf9`.
  Re-verify after chart edits: render every service with
  `helm template -f <env> -f <env>-secrets --set image.tag=<pin> .` from each chart dir.

## 1. Environment file
Copy `config-as-code/environments/egov-demo.yaml` → `egov-<name>.yaml` (+ `-secrets.yaml`) and set:
- `global.domain` and the egov-config `domain` / `egov-services-fqdn-name`.
- `db-host` = **plain hostname, no `:port`** (a `:5432` suffix breaks the airflow migration's DNS
  lookup); `db-name`; `db-url`/`db-url-no-schema` with explicit `:5432`.
- `egov-filestore` section: real bucket name; secrets file: real db + S3 creds.
- **Non-central-instance cluster (bare Kafka topics, `public` schema):** flip every
  `central-instance-enabled: true` to `false` (24 sections; `console` may keep `true`) and
  project-factory's `IS_ENVIRONMENT_CENTRAL_INSTANCE` to `"false"`. Symptoms of missing this:
  project-factory refuses to boot; excel-ingestion queries schema `<tenant>.` and produces to
  `<tenant>-`-prefixed topics that nothing consumes — silently.
- `custom-js-injection` script URLs per environment (globalConfigs assets).

## 2. Deploy
```
cd deploy-as-code/deployer
go run main.go deploy -c -p -e egov-<name> "<comma-separated services from the release chart>"   # preview
go run main.go deploy -c -e egov-<name> "<same list>"                                             # apply
```
- Build the list from `config-as-code/product-release-charts/Health/dependancy_chart-health-demo-v2.1.yaml`
  (keep module order: backbone → authn-authz → core → …).
- If nginx-ingress/cert-manager are ALREADY live (reinstall case), exclude them — the env pins an
  old controller image and re-applying could break the existing LoadBalancer/DNS.
- `-c` applies cluster-configs (namespaces, secrets, egov-config); `-p` never touches the cluster.
- "Duplicate service found" warnings from the chart index are benign (last-wins, correct dirs).

## 3. Expected mid-state, then seed
~7 services crash-loop on an EMPTY database (egov-user, egov-enc-service, egov-workflow-v2,
worker-registry, inbox, individual, egov-malware-detection) — they need MDMS data and CANNOT go
green before seeding. All Flyway migrations complete regardless. Then:
```
cd seed-data/2.1 && export PG* creds && ./apply.sh          # or FROM_POD=1 with a kubeconfig
kubectl -n egov rollout restart deploy/mdms-v2 deploy/project-factory
kubectl -n backbone exec deploy/redis -- redis-cli DEL messages computedMessages
```
The loopers self-heal within minutes (delete their pods to skip the backoff).

## 4. HCMADMIN bootstrap
```
kubectl -n egov create secret generic hcmadmin-seed --from-literal=password='<pass>'
cd config-as-code/helm/charts/core-services/egov-user
helm template -f <env-file> -f egov-user-values.yaml --set hcmSeed.enabled=true --set image.tag=<pin> . \
  | <filter kind: Job> | kubectl -n egov apply -f -
```

## 5. Boundary data (runtime, by design not in the seed)
Load hierarchies + trees via boundary-service APIs or the boundary excel flow. Minimal smoke tree:
hierarchy-definition `_create`, boundary `_create`, boundary-relationships `_create` per node.

## 6. Verification gates (all passed 2026-08-23)
1. `POST /user/oauth/token` through the public domain issues a token for HCMADMIN.
2. Localization + MDMS serve the seeded data (5 active projectTypes, seeded labels).
3. All API ingress paths back onto `gateway:8080`.
4. Unified campaign e2e: draft → excel-ingestion `generate/_init` (`unified-console`, needs
   `referenceId`+`referenceType=campaign`) → fill Boundary List target columns (ALL mandatory) →
   filestore upload → `project-type/update` action=create (startDate must be a FUTURE date) →
   status `created` → `SELECT count(*) FROM project WHERE referenceid='<campaign number>'` > 0.

## Known cosmetics / open
- kibana readiness 503 on a fresh es-cluster (monitoring UI only).
- Several charts still render duplicate env names (harmless on create; can break strategic-merge
  patches — fix pattern: `8bcccaf9`).
