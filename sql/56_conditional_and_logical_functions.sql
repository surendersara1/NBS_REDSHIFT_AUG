/*
======================================================================================
MODULE 56: CONDITIONAL & LOGICAL FUNCTIONS — 20 ENTERPRISE SCENARIOS
======================================================================================
TARGET AUDIENCE: Application Developers & Senior Data Engineers
BUSINESS SCENARIO: 
Complex business rule evaluation, tiered threshold classification, NULL safety, 
and short-circuit boolean expressions in high-performance analytical pipelines.

THE GOAL:
Provide 20 runnable, production-grade conditional and logical SQL functions in Amazon Redshift.
======================================================================================
*/

-- ===================================================================================
-- DATA GENERATION
-- ===================================================================================
DROP TABLE IF EXISTS demo_conditional_eval CASCADE;
CREATE TABLE demo_conditional_eval (
    id INT,
    account_tier VARCHAR(20),
    annual_spend DECIMAL(12,2),
    credit_score INT,
    discount_override DECIMAL(5,2),
    secondary_email VARCHAR(100),
    primary_email VARCHAR(100)
);

INSERT INTO demo_conditional_eval VALUES 
(1, 'ENTERPRISE', 150000.00, 810, 0.25, 'billing@corp.com', 'admin@corp.com'),
(2, 'MIDMARKET',   45000.00, 720, NULL, NULL,               'owner@startup.io'),
(3, 'STARTUP',      8500.00, NULL, NULL, 'backup@gmail.com', NULL),
(4, 'UNKNOWN',         0.00,  580, 0.05, NULL,               NULL);

ANALYZE demo_conditional_eval;


-- ===================================================================================
-- 20 ENTERPRISE CONDITIONAL & LOGICAL FUNCTIONS
-- ===================================================================================

-- 1. COALESCE (First non-null fallback chain)
SELECT id, COALESCE(primary_email, secondary_email, 'no-reply@system.com') AS active_email FROM demo_conditional_eval;

-- 2. NVL (Two-argument null replacement alias for COALESCE)
SELECT id, NVL(credit_score, 600) AS safe_credit_score FROM demo_conditional_eval;

-- 3. NVL2 (If-Not-Null-Then-Else: NVL2(expr, val_if_not_null, val_if_null))
SELECT id, NVL2(discount_override, 'CUSTOM_DISCOUNT', 'STANDARD_RATE') AS pricing_model FROM demo_conditional_eval;

-- 4. NULLIF (Return NULL if two expressions match — vital for safe division!)
SELECT id, annual_spend, 
       ROUND(annual_spend / NULLIF(credit_score, 0), 2) AS spend_per_credit_point 
FROM demo_conditional_eval;

-- 5. Simple CASE (Exact match on single expression)
SELECT id, account_tier,
       CASE account_tier
           WHEN 'ENTERPRISE' THEN 'Tier 1 Priority Support'
           WHEN 'MIDMARKET'  THEN 'Tier 2 Support'
           WHEN 'STARTUP'    THEN 'Self-Serve Community'
           ELSE 'Unassigned Tier'
       END AS support_level
FROM demo_conditional_eval;

-- 6. Searched CASE (Complex boolean conditions with ranges)
SELECT id, annual_spend,
       CASE 
           WHEN annual_spend >= 100000 THEN 'Platinum Club'
           WHEN annual_spend >= 25000  THEN 'Gold Club'
           WHEN annual_spend > 0       THEN 'Silver Club'
           ELSE 'Inactive Account'
       END AS loyalty_segment
FROM demo_conditional_eval;

-- 7. DECODE (Oracle-style equality switch: DECODE(expr, search1, result1, default))
SELECT id, DECODE(account_tier, 'ENTERPRISE', 1, 'MIDMARKET', 2, 'STARTUP', 3, 99) AS tier_priority_code FROM demo_conditional_eval;

-- 8. GREATEST (Returning largest value across multiple columns, ignoring nulls if possible)
SELECT GREATEST(100, 250, 85, 420) AS max_metric;

-- 9. LEAST (Returning smallest value across multiple columns)
SELECT LEAST(100, 250, 85, 420) AS min_metric;

-- 10. Single-line ternary — NOTE: Redshift has NO IFF (Snowflake) or IIF (SQL Server).
-- Its conditional expressions are exactly: CASE, DECODE, GREATEST/LEAST, NVL/COALESCE,
-- NVL2 and NULLIF. A compact CASE is the portable ternary; DECODE covers equality-only
-- tests but cannot express the range comparison below.
SELECT id, annual_spend,
       CASE WHEN annual_spend > 50000 THEN 'HIGH_VALUE' ELSE 'STANDARD' END AS tier_flag
FROM demo_conditional_eval;

-- 11. Short-Circuiting Boolean Logic (AND evaluation order safety)
SELECT id, annual_spend,
       CASE 
           WHEN annual_spend > 0 AND (100000.0 / annual_spend) < 2.0 THEN 'HIGH_EFFICIENCY'
           ELSE 'STANDARD_EFFICIENCY'
       END AS efficiency_flag
FROM demo_conditional_eval;

-- 12. Bool Aggregations: BOOL_AND / EVERY (True only if all rows evaluate to True)
SELECT BOOL_AND(annual_spend >= 0) AS all_spends_non_negative FROM demo_conditional_eval;

-- 13. Bool Aggregations: BOOL_OR / ANY (True if at least one row evaluates to True)
SELECT BOOL_OR(account_tier = 'ENTERPRISE') AS has_enterprise_accounts FROM demo_conditional_eval;

-- 14. Complex Multi-Tiered Discount Waterfall (Evaluating precedence)
SELECT id,
       COALESCE(
           discount_override,
           CASE WHEN account_tier = 'ENTERPRISE' AND credit_score >= 800 THEN 0.20
                WHEN annual_spend > 100000 THEN 0.15
                WHEN account_tier = 'MIDMARKET' THEN 0.10
                ELSE 0.00 END
       ) AS final_discount_pct
FROM demo_conditional_eval;

-- 15. IS DISTINCT FROM (NULL-Safe Inequality Comparison)
-- Evaluates TRUE if one value is NULL and the other is NOT NULL!
SELECT id, account_tier, (account_tier IS DISTINCT FROM 'ENTERPRISE') AS is_not_enterprise FROM demo_conditional_eval;

-- 16. IS NOT DISTINCT FROM (NULL-Safe Equality Comparison)
SELECT id, discount_override, (discount_override IS NOT DISTINCT FROM NULL) AS is_null_safe_check FROM demo_conditional_eval;

-- 17. Conditional Counting: COUNT(CASE WHEN ...) vs COUNT(*)
SELECT 
    COUNT(1) AS total_accounts,
    COUNT(CASE WHEN account_tier = 'ENTERPRISE' THEN 1 END) AS enterprise_count,
    COUNT(credit_score) AS accounts_with_known_credit -- Ignores NULLs automatically
FROM demo_conditional_eval;

-- 18. Conditional Summation with Sign Flipping (Debits vs Credits)
SELECT 
    SUM(CASE WHEN account_tier = 'ENTERPRISE' THEN annual_spend ELSE 0 END) AS enterprise_revenue,
    SUM(CASE WHEN account_tier != 'ENTERPRISE' THEN annual_spend ELSE 0 END) AS non_enterprise_revenue
FROM demo_conditional_eval;

-- 19. Threshold Floor / Ceiling Clamping with GREATEST / LEAST
SELECT id, credit_score,
       LEAST(GREATEST(NVL(credit_score, 600), 500), 800) AS clamped_credit_score
FROM demo_conditional_eval;

-- 20. Safe Regex Conditional Validation Flag
SELECT id, primary_email,
       CASE 
           WHEN primary_email IS NULL THEN 'MISSING'
           WHEN primary_email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' THEN 'VALID_FORMAT'
           ELSE 'MALFORMED'
       END AS email_syntax_status
FROM demo_conditional_eval;
