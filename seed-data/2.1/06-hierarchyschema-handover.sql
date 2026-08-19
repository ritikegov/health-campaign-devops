-- 06-hierarchyschema-handover.sql  (HCM 2.1, tenant mz)
--
-- HEADER CORRECTED 2026-08-19 after code review. The previous version asserted that
-- "the base MDMS seed ships the 'campaign' HierarchySchema row pointing at hierarchy
-- 'ADMIN'". That sentence is DELETED because it is disproven: no file in this bundle
-- creates that row, mdms-v2's Flyway does not (its db/migration/main/ is two DDL files
-- creating eg_mdms_data + eg_mdms_schema_definition with zero INSERTs), and
-- health-campaign-mdms@DEV does not (it has no HierarchySchema at all; its one
-- projectTypes file is an MDMS v1 file-based master under tenantId 'default', a
-- different store from eg_mdms_data). Whether some other upstream baseline supplies it
-- is an OPEN QUESTION, not an established fact.
--
-- WHO CONSUMES THIS MASTER. Exactly one function reads it:
-- getBoundaryOnWhichWeSplit() at project-factory
-- src/server/utils/campaignUtils.ts:4032 (registered as
-- config.masterNameForSplitBoundariesOn = "HierarchySchema" in config/index.ts:22).
-- It returns data.splitBoundariesOn and throws MDMS_DATA_NOT_FOUND_ERROR at :4043-4045
-- when the query returns nothing.
--
-- IMPORTANT -- HOW IT FILTERS. The lookup asks whether ANY row has
-- data.hierarchy == CampaignDetails.hierarchyType. It does NOT filter on
-- uniqueidentifier. So this file matters only when a campaign's hierarchyType is
-- HANDOVER and no row yet carries hierarchy='HANDOVER'. It also means a baseline that
-- seeds these rows at 'ADMIN' does NOT remove the need for this repoint -- the two are
-- complementary, not alternatives.
--
-- WHEN THIS FILE IS A NO-OP (both are silent, and psql still exits 0):
--   * the row is absent entirely -- e.g. a fresh tenant, where eg_mdms_data is empty;
--   * the row already carries hierarchy='HANDOVER' -- excluded by the predicate below.
-- Do NOT convert either case into an error with a ROW_COUNT=0 guard: the second case is
-- the CORRECT outcome of a legitimate re-apply, and aborting would leave 07 unapplied.
-- A row-EXISTENCE assertion is the right check if one is wanted.
--
-- RELEVANCE UNDER isUnifiedCampaign. In callGenerateIfBoundariesOrCampaignTypeDiffer
-- (generateUtils.ts:119-122), when CampaignDetails.additionalDetails.isUnifiedCampaign
-- is true the flow calls excel-ingestion and returns early, skipping
-- triggerGenerate(boundary|user|facility) -- so the GENERATE path into
-- getBoundaryOnWhichWeSplit (boundary-generateClass.ts:116) is not reached. Two caveats
-- before concluding this master is unnecessary:
--   1. isUnifiedCampaign is a per-campaign REQUEST-BODY field, not a config, env var or
--      MDMS value. It has no server-side default in project-factory (the only default is
--      `|| false` at onGoingCampaignUpdateUtils.ts:206), so whether it is set depends on
--      the client -- typically the console -- not on this install.
--   2. FOUR other call sites of getBoundaryOnWhichWeSplit remain UNASSESSED for
--      reachability, all validation/process rather than generate:
--      boundaryValidation-processClass.ts:56, EnrichProcessConfigUtil.ts:33,
--      campaignApis.ts:992, campaignUtils.ts:3995. Since excel-ingestion produces
--      resources that are then validated, these may well be reachable.
-- This file is therefore retained, not deleted.
--
-- The schema pins data.type to enum [default,microplan,campaign,console] and marks it
-- x-unique, so this repoints the existing 'campaign' row rather than adding another
-- (console/boundary/microplan stay on ADMIN so admin screens keep working).
--
-- Requires an mdms-v2 cache refresh afterwards
-- (kubectl rollout restart deploy/mdms-v2 deploy/project-factory -n egov).

UPDATE eg_mdms_data
SET data = jsonb_set(jsonb_set(jsonb_set(
             data,
             '{hierarchy}',        '"HANDOVER"', true),
             '{lowestHierarchy}',  '"VILLAGE"',  true),
             '{highestHierarchy}', '"COUNTRY"',  true),
    lastmodifiedtime = (extract(epoch from now())*1000)::bigint
WHERE schemacode      = 'HCM-ADMIN-CONSOLE.HierarchySchema'
  AND uniqueidentifier = 'campaign'
  AND tenantid        = 'mz'
  AND (data->>'hierarchy') IS DISTINCT FROM 'HANDOVER';

-- Verify: expect one row, hierarchy=HANDOVER, lowestHierarchy=VILLAGE
--   SELECT uniqueidentifier, data->>'hierarchy', data->>'lowestHierarchy'
--   FROM eg_mdms_data
--   WHERE schemacode='HCM-ADMIN-CONSOLE.HierarchySchema' AND tenantid='mz';
