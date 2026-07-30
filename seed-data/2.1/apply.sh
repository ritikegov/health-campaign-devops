#!/usr/bin/env bash
# apply.sh — apply the HCM 2.1 seed data (tenant mz) in order.
#
# DB credentials are taken from the environment at runtime and NEVER stored here.
# Provide them one of two ways:
#
#   A) Direct psql env (from a host that can reach the DB):
#        export PGHOST=... PGPORT=5432 PGDATABASE=... PGUSER=... PGPASSWORD=...
#        ./apply.sh
#
#   B) Pull creds from a running egov-user pod (in-cluster DB):
#        export KUBECONFIG=/path/to/kubeconfig
#        FROM_POD=1 ./apply.sh
#
# Idempotent: every file is INSERT ... WHERE NOT EXISTS / UPDATE-if-changed /
# DROP NOT NULL, so re-running is safe.
set -euo pipefail
cd "$(dirname "$0")"

if [ "${FROM_POD:-0}" = "1" ]; then
  NS="${NS:-egov}"
  UP=$(kubectl get pods -n "$NS" -l app=egov-user --no-headers | awk '$3=="Running"{print $1; exit}')
  [ -n "$UP" ] || { echo "no running egov-user pod in ns $NS"; exit 1; }
  URL=$(kubectl exec -n "$NS" "$UP" -c egov-user -- printenv SPRING_DATASOURCE_URL)
  export PGUSER=$(kubectl exec -n "$NS" "$UP" -c egov-user -- printenv SPRING_DATASOURCE_USERNAME)
  export PGPASSWORD=$(kubectl exec -n "$NS" "$UP" -c egov-user -- printenv SPRING_DATASOURCE_PASSWORD)
  hp=${URL#jdbc:postgresql://}; export PGHOST=${hp%%:*}; rest=${hp#*:}
  export PGPORT=${rest%%/*}; db=${rest#*/}; export PGDATABASE=${db%%\?*}
fi

: "${PGHOST:?set PGHOST or FROM_POD=1}"; : "${PGDATABASE:?}"; : "${PGUSER:?}"
echo ">> target ${PGUSER}@${PGHOST}:${PGPORT:-5432}/${PGDATABASE}"

for f in 01-mdms.sql 02-accesscontrol.sql 03-workflow.sql 04-pgr.sql \
         05-localization.sql 06-hierarchyschema-handover.sql \
         07-project-department-nullable.sql; do
  echo ">> applying $f"
  psql -v ON_ERROR_STOP=1 -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -f "$f"
done

echo ">> SSO (optional): fill and apply 08-sso-identityproviders.TEMPLATE.sql per environment."
echo ">> Then refresh MDMS caches: kubectl rollout restart deploy/mdms-v2 deploy/project-factory -n egov"
echo ">> done."
