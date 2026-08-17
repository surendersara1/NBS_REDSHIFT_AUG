/*
======================================================================================
MODULE 58: CRYPTOGRAPHIC & HASH FUNCTIONS — 20 ENTERPRISE SCENARIOS
======================================================================================
TARGET AUDIENCE: Application Developers & Senior Data Engineers
BUSINESS SCENARIO: 
Data masking, surrogate key generation, record change detection (CDC/SCD2), 
salted password verification, and distributed hash bucketing.

THE GOAL:
Provide 20 runnable, production-grade cryptographic and hashing SQL functions in Amazon Redshift.
======================================================================================
*/

-- ===================================================================================
-- DATA GENERATION
-- ===================================================================================
DROP TABLE IF EXISTS demo_crypto_users CASCADE;
CREATE TABLE demo_crypto_users (
    user_id INT,
    first_name VARCHAR(50),
    last_name VARCHAR(50),
    email VARCHAR(100),
    ssn VARCHAR(20),
    address VARCHAR(100),
    tier VARCHAR(20)
);

INSERT INTO demo_crypto_users VALUES 
(101, 'Alice', 'Smith', 'alice@company.com', '123-45-6789', '123 Pine St', 'VIP'),
(102, 'Bob',   'Jones', 'bob@test.com',    '987-65-4321', '456 Oak Ave', 'STANDARD'),
(103, 'Charlie','Brown', 'charlie@corp.io',  '555-12-3456', '789 Elm St',  'GOLD');

ANALYZE demo_crypto_users;


-- ===================================================================================
-- 20 ENTERPRISE CRYPTOGRAPHIC & HASH FUNCTIONS
-- ===================================================================================

-- 1. MD5 (32-character hexadecimal digest — standard for SCD2 row hashing)
SELECT user_id, MD5(first_name || '|' || last_name || '|' || address || '|' || tier) AS row_hash_md5 FROM demo_crypto_users;

-- 2. SHA (SHA-1 40-character hexadecimal digest)
SELECT user_id, SHA(email) AS sha1_hash FROM demo_crypto_users;

-- 3. SHA2 / SHA256 (256-bit secure cryptographic hash)
SELECT user_id, SHA2(email, 256) AS sha256_hash FROM demo_crypto_users;

-- 4. SHA2-512 (512-bit military-grade secure hash)
SELECT user_id, SHA2(ssn, 512) AS sha512_hash FROM demo_crypto_users;

-- 5. CHECKSUM (Fast INTEGER hash code — ideal for numeric partition distribution)
SELECT user_id, CHECKSUM(email) AS numeric_hash_code FROM demo_crypto_users;

-- 6. FNV_HASH (Fowler-Noll-Vo 64-bit non-cryptographic hash)
-- NAME MATTERS: the function is FNV_HASH. There is no FNVD32_1 or FNVD64_1 in Redshift.
-- The optional second argument is a SEED, which is how you fold several columns into a
-- single hash without concatenating them into a string first.
SELECT user_id,
       FNV_HASH(email)                        AS fnv_hash,
       FNV_HASH(last_name, FNV_HASH(first_name)) AS fnv_combined_name_hash
FROM demo_crypto_users;

-- 7. MURMUR3_32_HASH (High-performance Murmur3 hashing for distributed bucketing)
-- NAME MATTERS: the function is MURMUR3_32_HASH. There is no MURMUR3_32 or MURMUR3_128.
SELECT user_id, MURMUR3_32_HASH(user_id::VARCHAR) AS murmur32_code FROM demo_crypto_users;

-- 8. Salted Hashing for Identity Matching (Preventing rainbow table attacks)
SELECT user_id, SHA2('NBS_STATIC_SALT_2026_' || LOWER(TRIM(email)), 256) AS salted_identity_token FROM demo_crypto_users;

-- 9. Masking Sensitive PII with Partial Hashes
SELECT user_id, 
       SUBSTRING(ssn, 1, 3) || '-**-' || SUBSTRING(MD5(ssn), 1, 4) AS masked_ssn_token
FROM demo_crypto_users;

-- 10. Multi-Column Composite Deterministic Surrogate Key Generation
SELECT MD5(NVL(first_name,'') || '#' || NVL(last_name,'') || '#' || NVL(email,'')) AS generated_surrogate_sk
FROM demo_crypto_users;

-- 11. Consistent Modulo Hash Bucketing for A/B Experiment Testing (10 Equal Buckets 0-9)
SELECT user_id, ABS(CHECKSUM(user_id::VARCHAR)) % 10 AS experiment_bucket
FROM demo_crypto_users;

-- 12. Dynamic Change Data Capture (CDC) Comparison via Hashing
SELECT 
    a.user_id,
    CASE WHEN MD5(a.first_name || '|' || a.address) != MD5(b.first_name || '|' || b.address) 
         THEN 'ATTRIBUTES_MODIFIED' ELSE 'UNCHANGED' END AS change_status
FROM demo_crypto_users a
JOIN demo_crypto_users b ON a.user_id = b.user_id;

-- 13. Case-Insensitive Normalized Email Hashing (For cross-system CRM linkage)
SELECT user_id, SHA2(LOWER(TRIM(email)), 256) AS normalized_crm_hash FROM demo_crypto_users;

-- 14. Anonymized Data Sharing Tokenization (HIPAA / GDPR Pseudonymization)
SELECT 
    'ANON_USER_' || SUBSTRING(SHA2(user_id::VARCHAR || '_SECRET_KEY', 256), 1, 16) AS anonymized_subject_id,
    tier
FROM demo_crypto_users;

-- 15. CRC32-like Integer Fingerprinting with CRC Polynomial logic
SELECT user_id, ABS(CHECKSUM(ssn)) AS ssn_fingerprint FROM demo_crypto_users;

-- 16. Fast Table-Level Data Validation Hash (Checksumming entire table state)
SELECT SUM(CHECKSUM(first_name || last_name || email)) AS table_state_checksum FROM demo_crypto_users;

-- 17. Bitwise XOR Operations for Hash Combination
SELECT user_id, CHECKSUM(first_name) # CHECKSUM(last_name) AS combined_xor_hash FROM demo_crypto_users;

-- 18. Salted Password Verification Simulation
SELECT user_id, 
       (SHA2('user_input_password_123' || 'SALT_KEY_XYZ', 256) = SHA2('user_input_password_123' || 'SALT_KEY_XYZ', 256)) AS is_password_valid
FROM demo_crypto_users WHERE user_id = 101;

-- 19. Truncated Hash for Compact Short-URL Codes
SELECT user_id, SUBSTRING(MD5(email), 1, 8) AS short_url_token FROM demo_crypto_users;

-- 20. Redshift Native Data Masking Policies (Reference Pattern):
-- CREATE MASKING POLICY ssn_mask WITH (val VARCHAR) USING (SUBSTRING(val, 1, 3) || '-XX-XXXX');
-- ATTACH MASKING POLICY ssn_mask ON demo_crypto_users (ssn) TO ROLE bi_analysts;
SELECT user_id, 'Policy pattern configured for role-based masking.' AS masking_info;
