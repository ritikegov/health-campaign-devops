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
# Idempotent, but by MIXED mechanisms -- measured per file, 2026-08-19:
#   INSERT ... WHERE NOT EXISTS : 01 (127), 02 (66), 03 (67), 08 (2), 09 (1), 11 (19)
#   ON CONFLICT ... DO NOTHING  : 04 (76), 05 (26), 10 (88979), 12 (11885)
#   bare UPDATE                 : 06, and 09's POLIO row
#   ALTER TABLE ... DROP NOT NULL : 07
# Re-running is safe against the DB each file was dumped from. Two caveats:
#   - There is NO cross-file atomicity. 01/02/03/05 wrap in BEGIN/COMMIT; the rest do
#     not, and each file is a separate psql invocation, so a failure at file N leaves
#     1..N-1 committed with no marker and no rollback path.
#   - 06 and 09's UPDATEs carry "IS DISTINCT FROM" predicates, so 0 rows affected is the
#     CORRECT outcome on a re-run. Do NOT add a ROW_COUNT=0 failure guard: it would abort
#     a legitimate re-apply. A row-EXISTENCE assertion is the right check if one is wanted.
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

APPLIED=(); SKIPPED=()

for f in 01-mdms.sql 02-accesscontrol.sql 03-workflow.sql 04-pgr.sql \
         05-localization.sql 06-hierarchyschema-handover.sql \
         07-project-department-nullable.sql; do
  if [ ! -f "$f" ]; then
    # A curated subset of this bundle (e.g. the HCM-2.1-Migration package, which ships
    # without 05/10/12) must not hard-abort here: with set -e + ON_ERROR_STOP a missing
    # file used to kill the run and silently leave 06 and 07 unapplied.
    echo ">> SKIP  $f  (not present in this copy of the bundle)"
    SKIPPED+=("$f")
    continue
  fi
  echo ">> applying $f"
  psql -v ON_ERROR_STOP=1 -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -f "$f"
  APPLIED+=("$f")
done

# ---- summary. Deliberately loud: a partial apply must never look like a clean run. ----
echo
echo "=============================== SEED APPLY SUMMARY ==============================="
echo "applied (${#APPLIED[@]}): ${APPLIED[*]:-none}"
if [ "${#SKIPPED[@]}" -gt 0 ]; then
  echo
  echo "!! SKIPPED (${#SKIPPED[@]}): ${SKIPPED[*]}"
  echo "!! This run is INCOMPLETE. The cluster is NOT fully seeded, even though this"
  echo "!! script is exiting 0. Obtain the missing files and re-run before treating the"
  echo "!! environment as installed."
fi

# Files that exist in this bundle but are NOT in the loop above. Stated explicitly because
# silence here previously read as "everything was applied".
NOT_WIRED=()
for f in 09-project-types-active.sql 10-localization-ui-labels-mirror.sql \
         11-mdms-adminschema-checklist-mirror.sql 12-localization-labels-full-mirror.sql; do
  [ -f "$f" ] && NOT_WIRED+=("$f")
done
if [ "${#NOT_WIRED[@]}" -gt 0 ]; then
  echo
  echo "!! PRESENT BUT NOT APPLIED BY THIS SCRIPT (${#NOT_WIRED[@]}): ${NOT_WIRED[*]}"
  echo "!! These are deliberately NOT wired in pending review -- 10 and 12 would"
  echo "!! permanently resolve ~1,184 conflicting translations by apply order under"
  echo "!! ON CONFLICT DO NOTHING, which is a one-way migration with no rollback."
  echo "!! Apply them by hand only after deciding that. Note 09/11 carry the POLIO and"
  echo "!! adminSchema/ChecklistTemplates records, so master data is INCOMPLETE without them."
fi
echo "=================================================================================="
echo

echo ">> SSO (optional): fill and apply 08-sso-identityproviders.TEMPLATE.sql per environment."
echo ">> POST-APPLY, both steps are REQUIRED:"
echo ">>   1. Refresh the MDMS cache:"
echo ">>        kubectl rollout restart deploy/mdms-v2 deploy/project-factory -n egov"
echo ">>   2. Bust the localization cache. egov-localization caches in Redis under the HASH"
echo ">>      keys 'messages' and 'computedMessages', and THEY SURVIVE POD RESTARTS -- so"
echo ">>      step 1 alone does NOT make newly seeded messages served:"
echo ">>        kubectl exec -n backbone deploy/redis -- redis-cli DEL messages computedMessages"
echo ">>      (adjust the selector to your redis workload; see POST-APPLY-localization-cache-bust.md)"
echo ">> Browsers additionally cache localisation in IndexedDB -- use Clear-site-data, not reload."
echo ">> done."
