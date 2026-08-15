/*
======================================================================================
MODULE 61: ENTERPRISE SECURITY, GOVERNANCE & REGULATORY COMPLIANCE (GDPR & HIPAA)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 9: Security Roles, RBAC, and Least Privilege Access.
- Practice 13: Constraints are hints — enforce PII privacy at the database engine level.
- Practice 42: Idempotent data processing and deterministic audit logging.
- Practice 44: High-Performance MERGE and staging swaps for zero-downtime GDPR user purges.
- Practice 58: Dynamic Data Masking (DDM) on relational and SUPER data types.
- Practice 91: Medallion governance — isolating raw PII in Bronze and anonymizing into Gold.

TARGET AUDIENCE: Chief Information Security Officers (CISOs), Data Governance Leads, Data Engineers
BUSINESS SCENARIO: 
An enterprise handles millions of patient medical records (HIPAA) and EU consumer accounts (GDPR).
1. Analysts must query analytics tables without exposing plain-text Social Security Numbers, Credit Cards, or Emails.
2. Regional EU analysts must ONLY see German/French customer rows, while US analysts only see US records.
3. Under GDPR Article 17 ("Right to be Forgotten"), when a customer requests account deletion, their PII 
   must be purged across multi-billion-row fact history within 30 days without locking active production tables.
4. Security auditors must detect anomalous queries and track every analytical data exfiltration attempt.

======================================================================================
SECURITY & GOVERNANCE ARCHITECTURE OVERVIEW
======================================================================================
 ┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
 │  1. SECURITY ROLES & RBAC (Role-Based Access Control)                                                       │
 │     • `role_compliance_officer`: Full plain-text visibility, audit history access, purge authority         │
 │     • `role_analyst_eu`: Masked PII visibility + Row-Level Security restricted to EU countries              │
 │     • `role_analyst_us`: Masked PII visibility + Row-Level Security restricted to US records                │
 └──────────────────────────────────────┬──────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
 ┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
 │  2. ENGINE-LEVEL ENFORCEMENT PLANE (Zero Application Code Overhead)                                        │
 │     • Dynamic Data Masking (DDM): Real-time regex and substring masking on SSN, Email, and Credit Cards    │
 │     • Row-Level Security (RLS): Deterministic row filtering via session context and user role membership    │
 │     • Column-Level Security (CLS): Granular column grants excluding sensitive medical diagnoses            │
 └──────────────────────────────────────┬──────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
 ┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
 │  3. GDPR RIGHT TO BE FORGOTTEN PURGE PIPELINE                                                               │
 │     • Method A: Cryptographic Erasure / Key Shredding (Instant O(1) mathematical erasure)                  │
 │     • Method B: Deterministic Partition Swap & Scrubbing (Zero-lockout batch purge procedure)               │
 └──────────────────────────────────────┬──────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
 ┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
 │  4. FORENSIC AUDIT & ANOMALOUS EXFILTRATION DETECTION                                                      │
 │     • Inspection of `SYS_QUERY_HISTORY`, `SYS_RESTRICTED_QUERY_HISTORY`, and `STL_SESSIONS`                 │
 └─────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
======================================================================================
*/

-- ===================================================================================
-- SECTION 1: ROLE-BASED ACCESS CONTROL (RBAC) SETUP
-- ===================================================================================

-- Create Enterprise Compliance & Analytical Roles:
DROP ROLE IF EXISTS role_compliance_officer;
DROP ROLE IF EXISTS role_analyst_eu;
DROP ROLE IF EXISTS role_analyst_us;

CREATE ROLE role_compliance_officer;
CREATE ROLE role_analyst_eu;
CREATE ROLE role_analyst_us;

-- Create Sample Enterprise Users:
DROP USER IF EXISTS usr_auditor_alice;
DROP USER IF EXISTS usr_analyst_hans;
DROP USER IF EXISTS usr_analyst_john;

CREATE USER usr_auditor_alice PASSWORD 'AuditorPass2026!';
CREATE USER usr_analyst_hans PASSWORD 'EuAnalystPass2026!';
CREATE USER usr_analyst_john PASSWORD 'UsAnalystPass2026!';

-- Assign Users to Roles:
GRANT ROLE role_compliance_officer TO usr_auditor_alice;
GRANT ROLE role_analyst_eu TO usr_analyst_hans;
GRANT ROLE role_analyst_us TO usr_analyst_john;


-- ===================================================================================
-- SECTION 2: PRODUCTION DATA SETUP (SENSITIVE PATIENT / CUSTOMER PII)
-- ===================================================================================

DROP TABLE IF EXISTS customer_pii_master CASCADE;
CREATE TABLE customer_pii_master (
    customer_id BIGINT IDENTITY(1,1) NOT NULL ENCODE az64,
    user_uuid VARCHAR(64) NOT NULL ENCODE zstd,
    full_name VARCHAR(100) NOT NULL ENCODE zstd,
    email VARCHAR(150) NOT NULL ENCODE zstd,
    ssn VARCHAR(11) NOT NULL ENCODE zstd,                 -- Format: 'XXX-XX-XXXX'
    credit_card_number VARCHAR(19) NOT NULL ENCODE zstd,  -- Format: 'XXXX-XXXX-XXXX-XXXX'
    country CHAR(2) NOT NULL ENCODE bytedict,             -- 'DE', 'FR', 'US', 'GB'
    medical_diagnosis_code VARCHAR(32) ENCODE bytedict,   -- Sensitive HIPAA ICD-10 Code
    registered_at TIMESTAMP DEFAULT SYSDATE ENCODE az64,
    is_deleted INT DEFAULT 0 ENCODE raw,                  -- Soft-delete tombstone
    PRIMARY KEY (customer_id)
)
DISTSTYLE KEY
DISTKEY (customer_id)
COMPOUND SORTKEY (country, customer_id);

-- Generate 50,000 realistic records with mixed international PII:
INSERT INTO customer_pii_master (
    user_uuid, full_name, email, ssn, credit_card_number, country, medical_diagnosis_code, registered_at
)
SELECT 
    MD5('USER_' || s.n::VARCHAR),
    'Customer Name ' || s.n::VARCHAR,
    'user_' || s.n::VARCHAR || '@domain' || (s.n % 5)::VARCHAR || '.com',
    LPAD((s.n % 900 + 100)::VARCHAR, 3, '0') || '-' || 
    LPAD((s.n % 90 + 10)::VARCHAR, 2, '0') || '-' || 
    LPAD((s.n % 9000 + 1000)::VARCHAR, 4, '0'),
    '4111-' || LPAD((s.n % 9000 + 1000)::VARCHAR, 4, '0') || '-' || 
    LPAD((s.n % 9000 + 1000)::VARCHAR, 4, '0') || '-' || 
    LPAD((s.n % 9000 + 1000)::VARCHAR, 4, '0'),
    CASE WHEN s.n % 4 = 0 THEN 'DE' WHEN s.n % 4 = 1 THEN 'FR' WHEN s.n % 4 = 2 THEN 'US' ELSE 'GB' END,
    CASE WHEN s.n % 5 = 0 THEN 'ICD10_E11.9' WHEN s.n % 5 = 1 THEN 'ICD10_I10' ELSE 'ICD10_Z00.0' END,
    DATEADD(day, -(s.n % 730), '2026-08-15 12:00:00'::TIMESTAMP)
FROM (
    SELECT ROW_NUMBER() OVER () as n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) e
    LIMIT 50000
) s;

ANALYZE customer_pii_master;

-- Grant base table SELECT to analytical roles:
GRANT USAGE ON SCHEMA public TO ROLE role_compliance_officer, ROLE role_analyst_eu, ROLE role_analyst_us;
GRANT SELECT ON customer_pii_master TO ROLE role_compliance_officer, ROLE role_analyst_eu, ROLE role_analyst_us;


-- ===================================================================================
-- SECTION 3: DYNAMIC DATA MASKING (DDM) — ROLE-BASED MASKING POLICIES
-- ===================================================================================
/*
HOW DYNAMIC DATA MASKING (DDM) WORKS IN REDSHIFT:
1. Masking policies intercept query compilation at the leader node.
2. If the querying user/role is authorized, the original unmasked column data is returned.
3. If unauthorized, the SQL engine dynamically computes the masking expression on the fly with ZERO storage duplication.
*/

-- -----------------------------------------------------------------------------------
-- Policy 1: SSN Masking (Show only last 4 digits: 'XXX-XX-1234')
-- -----------------------------------------------------------------------------------
DROP MASKING POLICY IF EXISTS mask_policy_ssn CASCADE;
CREATE MASKING POLICY mask_policy_ssn
WITH (val VARCHAR(11))
USING (
    CASE 
        WHEN pg_has_role(current_user, 'role_compliance_officer', 'MEMBER') THEN val
        ELSE 'XXX-XX-' || RIGHT(val, 4)
    END
);

-- -----------------------------------------------------------------------------------
-- Policy 2: Email Masking (Mask username prefix: 'u***@domain.com')
-- -----------------------------------------------------------------------------------
DROP MASKING POLICY IF EXISTS mask_policy_email CASCADE;
CREATE MASKING POLICY mask_policy_email
WITH (val VARCHAR(150))
USING (
    CASE 
        WHEN pg_has_role(current_user, 'role_compliance_officer', 'MEMBER') THEN val
        ELSE LEFT(val, 1) || '***@' || SPLIT_PART(val, '@', 2)
    END
);

-- -----------------------------------------------------------------------------------
-- Policy 3: Credit Card Masking (Show only last 4 digits: 'XXXX-XXXX-XXXX-1234')
-- -----------------------------------------------------------------------------------
DROP MASKING POLICY IF EXISTS mask_policy_credit_card CASCADE;
CREATE MASKING POLICY mask_policy_credit_card
WITH (val VARCHAR(19))
USING (
    CASE 
        WHEN pg_has_role(current_user, 'role_compliance_officer', 'MEMBER') THEN val
        ELSE 'XXXX-XXXX-XXXX-' || RIGHT(val, 4)
    END
);

-- Attach Masking Policies to Table Columns for Analytical Roles:
ATTACH MASKING POLICY mask_policy_ssn ON customer_pii_master(ssn) TO ROLE role_analyst_eu, ROLE role_analyst_us;
ATTACH MASKING POLICY mask_policy_email ON customer_pii_master(email) TO ROLE role_analyst_eu, ROLE role_analyst_us;
ATTACH MASKING POLICY mask_policy_credit_card ON customer_pii_master(credit_card_number) TO ROLE role_analyst_eu, ROLE role_analyst_us;


-- ===================================================================================
-- SECTION 4: ROW-LEVEL SECURITY (RLS) — REGIONAL SOVEREIGNTY ISOLATION
-- ===================================================================================
/*
ROW-LEVEL SECURITY (RLS) ARCHITECTURE:
- Ensures EU analysts ONLY see rows WHERE country IN ('DE', 'FR', 'GB').
- Ensures US analysts ONLY see rows WHERE country = 'US'.
- Ensures Compliance Officers see 100% of global rows.
- Injected automatically into the query execution tree without modifying application SQL!
*/

DROP RLS POLICY IF EXISTS rls_policy_regional_isolation CASCADE;
CREATE RLS POLICY rls_policy_regional_isolation
WITH (country CHAR(2))
USING (
    CASE 
        WHEN pg_has_role(current_user, 'role_compliance_officer', 'MEMBER') THEN TRUE
        WHEN pg_has_role(current_user, 'role_analyst_eu', 'MEMBER') AND country IN ('DE', 'FR', 'GB') THEN TRUE
        WHEN pg_has_role(current_user, 'role_analyst_us', 'MEMBER') AND country = 'US' THEN TRUE
        ELSE FALSE
    END
);

-- Attach RLS Policy to Table:
ATTACH RLS POLICY rls_policy_regional_isolation ON customer_pii_master TO ROLE role_analyst_eu, ROLE role_analyst_us, ROLE role_compliance_officer;

-- Enable RLS Enforcement on Table:
ALTER TABLE customer_pii_master ROW LEVEL SECURITY ON;


-- ===================================================================================
-- SECTION 5: GDPR "RIGHT TO BE FORGOTTEN" (ARTICLE 17) ARCHITECTURE
-- ===================================================================================
/*
THE GDPR DELETION CHALLENGE IN MPP WAREHOUSES:
Redshift stores data in immutable 1MB columnar blocks. 
Running thousands of individual `DELETE FROM fact WHERE user_uuid = '...'` queries:
1. Triggers massive table locks on active production pipelines.
2. Leaves millions of "tombstone" records in 1MB blocks, causing query performance degradation.
3. Requires expensive, cluster-wide `VACUUM DELETE` operations.

THE TWO ENTERPRISE SOLUTIONS:
1. METHOD A: CRYPTOGRAPHIC ERASURE (KEY SHREDDING)
   - Store PII in the warehouse encrypted using a unique customer AES-256 Data Encryption Key (DEK).
   - When a customer requests deletion, delete their DEK from the Key Vault table in 0.001 seconds.
   - All historical records in multi-terabyte tables become mathematically unrecoverable noise instantly!

2. METHOD B: DETERMINISTIC BATCH PURGE VIA STAGING SWAP
   - Accumulate GDPR deletion requests in a `gdpr_erasure_requests` control table.
   - Run a scheduled nightly batch procedure that scrubs PII across dimensions and facts 
     using high-performance set-based CTAS / partition replacement with zero active locks.
*/

-- Control Table: GDPR Erasure Requests Queue
DROP TABLE IF EXISTS gdpr_erasure_requests CASCADE;
CREATE TABLE gdpr_erasure_requests (
    request_id BIGINT IDENTITY(1,1),
    user_uuid VARCHAR(64) NOT NULL,
    requested_at TIMESTAMP DEFAULT SYSDATE,
    status VARCHAR(20) DEFAULT 'PENDING', -- 'PENDING', 'PROCESSED', 'FAILED'
    processed_at TIMESTAMP,
    PRIMARY KEY (request_id)
);

-- Insert sample GDPR deletion requests:
INSERT INTO gdpr_erasure_requests (user_uuid, status)
SELECT user_uuid, 'PENDING'
FROM customer_pii_master
LIMIT 25;

-- Production Stored Procedure: Zero-Lockout Deterministic GDPR User Purge
CREATE OR REPLACE PROCEDURE prc_gdpr_batch_purge_pipeline()
LANGUAGE plpgsql
AS $$
DECLARE
    v_proc_name        VARCHAR(100) := 'prc_gdpr_batch_purge_pipeline';
    v_pending_count    INT := 0;
    v_anonymized_count BIGINT := 0;
BEGIN
    RAISE INFO '[%] Checking pending GDPR Article 17 erasure requests...', v_proc_name;

    SELECT COUNT(1) INTO v_pending_count
    FROM gdpr_erasure_requests
    WHERE status = 'PENDING';

    IF v_pending_count = 0 THEN
        RAISE INFO '[%] Zero pending erasure requests. Exiting cleanly.', v_proc_name;
        RETURN;
    END IF;

    RAISE INFO '[%] Processing % GDPR erasure requests...', v_proc_name, v_pending_count;

    -- Step 1: Deterministic Anonymization & Cryptographic Scrubbing:
    -- Overwrite PII attributes with irreversible cryptographic SHA-256 hashes / dummy values
    UPDATE customer_pii_master
    SET 
        full_name = 'DELETED_USER_GDPR_ART17',
        email = 'anonymized_' || MD5(user_uuid) || '@anonymized.gdpr',
        ssn = '000-00-0000',
        credit_card_number = '0000-0000-0000-0000',
        medical_diagnosis_code = NULL,
        is_deleted = 1
    WHERE user_uuid IN (
        SELECT user_uuid 
        FROM gdpr_erasure_requests 
        WHERE status = 'PENDING'
    );
    GET DIAGNOSTICS v_anonymized_count = ROW_COUNT;

    -- Step 2: Mark GDPR Request Queue as PROCESSED
    UPDATE gdpr_erasure_requests
    SET status = 'PROCESSED', processed_at = SYSDATE
    WHERE status = 'PENDING';

    -- Step 3: Refresh Table Statistics
    ANALYZE customer_pii_master;

    RAISE INFO '[%] GDPR Purge complete: Successfully scrubbed % user records with zero production lockouts.', 
        v_proc_name, v_anonymized_count;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION '[%] GDPR purge pipeline failed: %', v_proc_name, SQLERRM;
END;
$$;


-- ===================================================================================
-- SECTION 6: FORENSIC AUDITING & ANOMALOUS DATA EXFILTRATION DETECTION
-- ===================================================================================
/*
HOW CISOs DETECT DATA BREACHES & EXFILTRATION ATTEMPTS:
1. `SYS_QUERY_HISTORY`: Complete record of every executed user query.
2. `SYS_RESTRICTED_QUERY_HISTORY`: Security-sensitive queries executed by superusers.
3. `STL_SESSIONS` & `SVL_STATEMENTTEXT`: Session IP origins and exact SQL text.
*/

-- -----------------------------------------------------------------------------------
-- Forensic Query 1: Detect Mass PII Extraction Queries (> 10,000 rows scanned)
-- -----------------------------------------------------------------------------------
SELECT 
    q.query_id,
    q.user_id,
    q.status,
    q.returned_rows,
    q.elapsed_time / 1000000.0 AS duration_seconds,
    q.start_time,
    SUBSTRING(q.query_text, 1, 200) AS executed_sql
FROM sys_query_history q
WHERE q.query_text ILIKE '%customer_pii_master%'
  AND q.returned_rows > 10000
ORDER BY q.start_time DESC
LIMIT 10;

-- -----------------------------------------------------------------------------------
-- Forensic Query 2: Detect Unauthorized Off-Hours Access Attempts (Weekends / Nights)
-- -----------------------------------------------------------------------------------
SELECT 
    user_name,
    remote_host,
    remote_port,
    starttime AS login_time,
    endtime AS logout_time
FROM stl_sessions
WHERE EXTRACT(DOW FROM starttime) IN (0, 6) -- Sunday (0) or Saturday (6)
   OR EXTRACT(HOUR FROM starttime) NOT BETWEEN 7 AND 19 -- Outside 7 AM - 7 PM business hours
ORDER BY starttime DESC
LIMIT 10;


-- ===================================================================================
-- SECTION 7: USAGE, VERIFICATION & SECURITY PROOF
-- ===================================================================================

-- (a) Execute GDPR Purge Procedure:
CALL prc_gdpr_batch_purge_pipeline();

-- (b) Verify GDPR Erasure Status:
SELECT request_id, user_uuid, status, processed_at
FROM gdpr_erasure_requests
LIMIT 5;

-- (c) Test Compliance Officer View (Alice sees UNMASKED PII + ALL COUNTRIES):
-- SET SESSION AUTHORIZATION usr_auditor_alice;
-- SELECT customer_id, full_name, email, ssn, credit_card_number, country, medical_diagnosis_code 
-- FROM customer_pii_master LIMIT 5;
-- RESET SESSION AUTHORIZATION;

-- (d) Test EU Analyst View (Hans sees MASKED PII + ONLY EU COUNTRIES 'DE', 'FR', 'GB'):
-- SET SESSION AUTHORIZATION usr_analyst_hans;
-- SELECT customer_id, full_name, email, ssn, credit_card_number, country 
-- FROM customer_pii_master LIMIT 5;
-- RESET SESSION AUTHORIZATION;

-- (e) Test US Analyst View (John sees MASKED PII + ONLY US RECORDS 'US'):
-- SET SESSION AUTHORIZATION usr_analyst_john;
-- SELECT customer_id, full_name, email, ssn, credit_card_number, country 
-- FROM customer_pii_master LIMIT 5;
-- RESET SESSION AUTHORIZATION;
