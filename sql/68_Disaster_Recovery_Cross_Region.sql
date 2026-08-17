/*
======================================================================================
MODULE 68: DISASTER RECOVERY, CROSS-REGION SNAPSHOTS & HIGH AVAILABILITY
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 109: "Snapshot or back up before destructive operations."
- Practice 82: "Design every operation to be retry-safe."
- Practice 80: "Use transactions to keep target data consistent."
- Practice 8: "Keep the original safe — copy into version control before editing."

TARGET AUDIENCE: Platform Engineers, SREs, Compliance Architects
BUSINESS SCENARIO:
A healthcare data platform in us-east-1 stores 80TB of HIPAA-regulated patient analytics.
Regulatory requirements mandate:
  • RPO (Recovery Point Objective): < 1 hour data loss
  • RTO (Recovery Time Objective): < 4 hours to full recovery
  • Cross-region replica in us-west-2 for regional disaster scenarios
  • 35-day retention of daily snapshots for audit and compliance

ARCHITECTURE:
┌──────────────────────────────────────────────────────────────────────────────┐
│                   DISASTER RECOVERY ARCHITECTURE                             │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  PRIMARY REGION (us-east-1)          DR REGION (us-west-2)                  │
│  ┌─────────────────────────┐        ┌─────────────────────────┐            │
│  │  Production Cluster     │        │  DR Cluster (Standby)   │            │
│  │  RA3.4xlarge × 8 nodes  │        │  RA3.4xlarge × 8 nodes  │            │
│  │  80TB Managed Storage   │───────▶│  (Restored from snapshot)│            │
│  │                         │  Cross │                          │            │
│  │  Auto Snapshot: hourly  │ Region │  OR:                     │            │
│  │  Manual Snapshot: daily │  Copy  │  Serverless namespace    │            │
│  │  Retention: 35 days     │        │  (auto-restore on demand)│            │
│  └────────────┬────────────┘        └──────────────────────────┘            │
│               │                                                              │
│               ▼                                                              │
│  ┌─────────────────────────┐                                                │
│  │  S3 Snapshot Storage    │   Snapshots are stored in S3 (managed by AWS)  │
│  │  • Incremental (blocks) │   • Only changed 1MB blocks are copied         │
│  │  • Compressed           │   • First snapshot: full; subsequent: delta    │
│  │  • Encrypted (KMS)      │   • Cross-region copy adds ~30 min latency    │
│  └─────────────────────────┘                                                │
│                                                                              │
│  RECOVERY TIMELINE:                                                         │
│  ┌──────┬──────────┬──────────┬──────────┬──────────┐                      │
│  │ T=0  │ T+5 min  │ T+30 min │ T+2 hr   │ T+4 hr   │                      │
│  │Detect│ Declare  │ Restore  │ Validate │ Cutover  │                      │
│  │outage│ disaster │ from snap│ data     │ DNS/app  │                      │
│  └──────┴──────────┴──────────┴──────────┴──────────┘                      │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘

======================================================================================
*/

-- These schemas are referenced throughout this module but are not created by
-- sql/01 (staging, analytics, admin) or sql/07 (rpt). Without these lines every
-- qualified reference below fails with 'schema does not exist'.
CREATE SCHEMA IF NOT EXISTS gold;

-- ============================================================================
-- SECTION 1: AUTOMATED SNAPSHOTS (BUILT-IN, ZERO CONFIG)
-- ============================================================================
-- IMPLEMENTS: Best Practice #109

-- Redshift automatically takes snapshots every 8 hours (or every 5GB of changes).
-- Default retention: 1 day for Provisioned, 24 hours for Serverless recovery points.

-- View existing automated snapshots:
SELECT
    snapshot_identifier,
    cluster_identifier,
    snapshot_create_time,
    snapshot_type,              -- 'automated' or 'manual'
    status,                    -- 'available', 'creating', 'deleting'
    total_backup_size_in_mega_bytes / 1024.0 AS backup_size_gb,
    elapsed_time_in_seconds,
    estimated_seconds_to_completion
FROM SVV_REDSHIFT_SNAPSHOTS
WHERE snapshot_type = 'automated'
ORDER BY snapshot_create_time DESC
LIMIT 20;

-- Modify automated snapshot retention (up to 35 days for compliance):
-- aws redshift modify-cluster \
--     --cluster-identifier my-warehouse \
--     --automated-snapshot-retention-period 35


-- ============================================================================
-- SECTION 2: MANUAL SNAPSHOTS (BEFORE DESTRUCTIVE OPERATIONS)
-- ============================================================================
-- IMPLEMENTS: Best Practice #109, #8

-- ALWAYS take a manual snapshot before:
--   • Large DELETE/UPDATE operations
--   • Schema migrations (ALTER TABLE, DROP TABLE)
--   • Cluster resizes
--   • Major ETL changes going to production

-- Create a manual snapshot (via AWS CLI):
-- aws redshift create-cluster-snapshot \
--     --cluster-identifier my-warehouse \
--     --snapshot-identifier "pre-migration-2026-08-15" \
--     --tags Key=Purpose,Value=PreMigration Key=Ticket,Value=JIRA-1234

-- Create a manual snapshot (via SQL — Serverless recovery points):
-- Serverless uses "recovery points" instead of traditional snapshots.
-- They are created automatically but can be manually triggered:
-- aws redshift-serverless create-snapshot \
--     --namespace-name my-namespace \
--     --snapshot-name "pre-migration-2026-08-15"

-- Verify snapshot completion:
SELECT
    snapshot_identifier,
    status,
    total_backup_size_in_mega_bytes / 1024.0 AS backup_gb,
    snapshot_create_time
FROM SVV_REDSHIFT_SNAPSHOTS
WHERE snapshot_identifier = 'pre-migration-2026-08-15';


-- ============================================================================
-- SECTION 3: CROSS-REGION SNAPSHOT COPY (THE DR BACKBONE)
-- ============================================================================
-- IMPLEMENTS: Best Practice #109

-- Enable automatic cross-region snapshot copy:
-- Every automated snapshot is copied to the DR region within ~30 minutes.

-- aws redshift enable-snapshot-copy \
--     --cluster-identifier my-warehouse \
--     --destination-region us-west-2 \
--     --retention-period 7 \
--     --snapshot-copy-grant-name my-kms-grant  -- Required for encrypted clusters

-- NOTE: Cross-region snapshot copy:
--   • Uses S3 cross-region replication under the hood
--   • Only copies incremental changes (not full snapshots every time)
--   • Encrypted clusters require a KMS grant in the destination region
--   • Adds ~$0.02/GB/month for cross-region S3 transfer

-- Verify cross-region copy status:
-- aws redshift describe-cluster-snapshots \
--     --cluster-identifier my-warehouse \
--     --snapshot-type automated \
--     --region us-west-2


-- ============================================================================
-- SECTION 4: RESTORING FROM A SNAPSHOT (THE ACTUAL DR PROCEDURE)
-- ============================================================================
-- IMPLEMENTS: Best Practices #82 (Retry-safe), #80 (Transaction consistency)

-- STEP 1: Restore to a new cluster in the DR region
-- aws redshift restore-from-cluster-snapshot \
--     --cluster-identifier dr-warehouse \
--     --snapshot-identifier my-warehouse-2026-08-15-06-00 \
--     --availability-zone us-west-2a \
--     --node-type ra3.4xlarge \
--     --number-of-nodes 8 \
--     --region us-west-2

-- STEP 2: Monitor restore progress
-- aws redshift describe-clusters \
--     --cluster-identifier dr-warehouse \
--     --region us-west-2

-- STEP 3: Validate data integrity after restore
-- Run these queries on the restored cluster:

-- Validate row counts for critical tables.
-- SVV_TABLE_INFO's columns are "schema" and "table" -- there is no schemaname or
-- tablename. "table" is a reserved word, so it must be double-quoted.
SELECT
    schema || '.' || "table" AS full_table_name,
    tbl_rows AS row_count
FROM SVV_TABLE_INFO
WHERE schema = 'gold'
ORDER BY tbl_rows DESC;

-- Compare checksums between primary and DR (run on BOTH clusters and diff the output).
-- Commented out because gold.fact_orders is illustrative -- substitute your own
-- critical table before running this on a restored cluster.
-- SELECT
--     'gold.fact_orders' AS table_name,
--     COUNT(*)           AS row_count,
--     SUM(CHECKSUM(order_id::VARCHAR || order_date::VARCHAR || total_amount::VARCHAR))
--                        AS checksum
-- FROM gold.fact_orders;

-- STEP 4: Update DNS / application connection strings to point to DR cluster
-- This is typically handled by Route 53 failover or application config changes.


-- ============================================================================
-- SECTION 5: POINT-IN-TIME RESTORE (SERVERLESS)
-- ============================================================================

-- Serverless supports point-in-time restore within the recovery window.
-- This is useful for recovering from accidental DELETE/UPDATE operations.

-- aws redshift-serverless restore-from-recovery-point \
--     --namespace-name my-namespace \
--     --recovery-point-id "rp-abc123def456" \
--     --workgroup-name "dr-workgroup"

-- List available recovery points:
-- aws redshift-serverless list-recovery-points \
--     --namespace-name my-namespace


-- ============================================================================
-- SECTION 6: TABLE-LEVEL RESTORE (SURGICAL RECOVERY)
-- ============================================================================

-- Instead of restoring the entire cluster, restore a single table from a snapshot.
-- This is perfect for "someone dropped the wrong table" scenarios.

-- aws redshift restore-table-from-cluster-snapshot \
--     --cluster-identifier my-warehouse \
--     --snapshot-identifier pre-migration-2026-08-15 \
--     --source-database-name analytics \
--     --source-schema-name gold \
--     --source-table-name dim_customer \
--     --target-database-name analytics \
--     --target-schema-name gold_restored \
--     --new-table-name dim_customer_restored

-- After restore, validate and swap:
-- BEGIN;
-- ALTER TABLE gold.dim_customer RENAME TO dim_customer_deleted;
-- ALTER TABLE gold_restored.dim_customer_restored RENAME TO dim_customer;
--   -- the renamed table still lives in gold_restored, so move it FROM there.
--   -- ("ALTER TABLE gold.dim_customer SET SCHEMA gold" names a table that does not
--   --  exist at this point, and moving gold -> gold would be a no-op anyway.)
-- ALTER TABLE gold_restored.dim_customer SET SCHEMA gold;
-- COMMIT;


-- ============================================================================
-- SECTION 7: DR RUNBOOK PROCEDURE (AUTOMATED VALIDATION)
-- ============================================================================
-- IMPLEMENTS: Best Practices #97-101 (Observability)

CREATE OR REPLACE PROCEDURE admin.sp_validate_dr_restore()
LANGUAGE plpgsql
AS $$
DECLARE
    v_table_name   VARCHAR(256);
    v_row_count    BIGINT;
    v_total_tables INT := 0;
    v_passed       INT := 0;
    v_failed       INT := 0;
    rec            RECORD;
BEGIN
    RAISE INFO '======= DR VALIDATION STARTED =======';
    RAISE INFO 'Cluster: % | Time: %', CURRENT_DATABASE(), SYSDATE;

    -- Check critical Gold tables have rows:
    FOR rec IN
        SELECT schema || '.' || "table" AS tbl, tbl_rows
        FROM SVV_TABLE_INFO
        WHERE schema = 'gold'
        ORDER BY tbl_rows DESC
    LOOP
        v_total_tables := v_total_tables + 1;
        IF rec.tbl_rows > 0 THEN
            v_passed := v_passed + 1;
            RAISE INFO '  ✅ % — % rows', rec.tbl, rec.tbl_rows;
        ELSE
            v_failed := v_failed + 1;
            RAISE WARNING '  ❌ % — EMPTY TABLE!', rec.tbl;
        END IF;
    END LOOP;

    RAISE INFO '======= DR VALIDATION COMPLETE =======';
    RAISE INFO 'Total: % | Passed: % | Failed: %', v_total_tables, v_passed, v_failed;

    IF v_failed > 0 THEN
        RAISE EXCEPTION 'DR VALIDATION FAILED: % tables are empty!', v_failed;
    END IF;
END;
$$;

-- CALL admin.sp_validate_dr_restore();


-- ============================================================================
-- SECTION 8: DR STRATEGY COMPARISON
-- ============================================================================
/*
┌───────────────────────┬─────────────┬─────────────┬──────────────────────────┐
│ Strategy              │ RPO         │ RTO         │ Cost                     │
├───────────────────────┼─────────────┼─────────────┼──────────────────────────┤
│ Auto snapshots only   │ ~8 hours    │ 2-4 hours   │ Free (included)          │
│ + Cross-region copy   │ ~8 hours    │ 2-4 hours   │ + S3 transfer ($0.02/GB) │
│ + Manual snapshots    │ Minutes     │ 2-4 hours   │ + snapshot storage       │
│ + Hot standby cluster │ Minutes     │ ~30 minutes │ + 2× compute cost        │
│ + Data sharing (live) │ Real-time   │ Minutes     │ + consumer cluster cost  │
│ Serverless recovery   │ ~30 minutes │ ~30 minutes │ Per-RPU-second           │
└───────────────────────┴─────────────┴─────────────┴──────────────────────────┘

RECOMMENDATION:
• Most production workloads: Auto snapshots + cross-region copy + manual pre-migration
• Regulated industries (HIPAA/SOX): Add hot standby + data sharing for near-zero RPO
• Cost-sensitive: Serverless with recovery points (auto-pause saves cost when idle)
*/
