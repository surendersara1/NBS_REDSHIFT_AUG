/*
======================================================================================
MODULE 54: STRING & REGEX FUNCTIONS — 20 ENTERPRISE SCENARIOS
======================================================================================
TARGET AUDIENCE: Application Developers & Senior Data Engineers
BUSINESS SCENARIO: 
Data cleaning, URL parsing, PII redaction, token extraction, and fuzzy matching 
in high-throughput analytical queries.

THE GOAL:
Provide 20 runnable, production-grade string and regular expression functions in Amazon Redshift.
======================================================================================
*/

-- ===================================================================================
-- DATA GENERATION
-- ===================================================================================
DROP TABLE IF EXISTS demo_raw_text CASCADE;
CREATE TABLE demo_raw_text (
    id INT,
    raw_name VARCHAR(100),
    raw_email VARCHAR(100),
    raw_phone VARCHAR(50),
    url_path VARCHAR(255),
    description VARCHAR(MAX)
);

INSERT INTO demo_raw_text VALUES 
(1, '  JOHN DOE  ', 'John.Doe@ACME.COM', '(555) 123-4567', 'https://shop.acme.com/products/item?id=9921&ref=email', 'Customer reported error code ERR_404_TIMEOUT on checkout.'),
(2, 'jane smith', 'jane_smith99@gmail.com', '555.987.6543', 'https://shop.acme.com/cart?promo=SUMMER26', 'Urgent ticket: payment failed with status DECLINED_INSUFFICIENT_FUNDS.'),
(3, ' Robert-Paulson ', 'robert@corp.co.uk', '+1-555-000-1122', 'https://blog.acme.com/2026/08/news', 'General inquiry regarding enterprise pricing tiers.');

ANALYZE demo_raw_text;


-- ===================================================================================
-- 20 ENTERPRISE STRING & REGEX FUNCTIONS
-- ===================================================================================

-- 1. TRIM / BTRIM, LTRIM, RTRIM (Removing surrounding whitespace and custom characters)
SELECT id, TRIM(raw_name) AS clean_name, BTRIM(raw_phone, '+1-() .') AS stripped_phone FROM demo_raw_text;

-- 2. INITCAP (Title casing names)
SELECT id, INITCAP(TRIM(raw_name)) AS formatted_name FROM demo_raw_text;

-- 3. LOWER & UPPER (Standardizing casing for joins and lookups)
SELECT id, LOWER(raw_email) AS clean_email FROM demo_raw_text;

-- 4. SPLIT_PART (Extracting delimited tokens by position)
-- Extract domain from email:
SELECT id, raw_email, SPLIT_PART(raw_email, '@', 2) AS domain_name FROM demo_raw_text;

-- 5. REGEXP_SUBSTR (Extracting regex pattern matches)
-- Extract error code pattern ERR_...
SELECT id, REGEXP_SUBSTR(description, 'ERR_[0-9]+_[A-Z]+') AS extracted_error_code FROM demo_raw_text;

-- 6. REGEXP_REPLACE (Sanitizing or redacting text patterns)
-- Strip all non-numeric characters from phone numbers:
SELECT id, raw_phone, REGEXP_REPLACE(raw_phone, '[^0-9]', '') AS digits_only_phone FROM demo_raw_text;

-- 7. REGEXP_INSTR (Finding character position of regex pattern)
SELECT id, description, REGEXP_INSTR(description, 'status [A-Z_]+') AS status_pos FROM demo_raw_text;

-- 8. REGEXP_COUNT (Counting occurrences of a pattern)
SELECT id, url_path, REGEXP_COUNT(url_path, '/') AS slash_count FROM demo_raw_text;

-- 9. SUBSTRING / SUBSTR (Extracting substrings by index and length)
SELECT id, SUBSTRING(clean_email, 1, 4) FROM (SELECT LOWER(raw_email) AS clean_email FROM demo_raw_text);

-- 10. POSITION / STRPOS (Finding literal substring positions)
SELECT id, url_path, POSITION('?' IN url_path) AS query_param_pos FROM demo_raw_text;

-- 11. LPAD / RPAD (Padding strings with zeros or characters)
SELECT id, LPAD(id::VARCHAR, 8, '0') AS padded_account_number FROM demo_raw_text;

-- 12. REPLACE (Replacing exact literal strings)
SELECT id, REPLACE(url_path, 'https://', '') AS protocol_free_url FROM demo_raw_text;

-- 13. TRANSLATE (Character-by-character replacement mapping)
SELECT id, TRANSLATE(raw_name, '-_', '  ') AS normalized_separators FROM demo_raw_text;

-- 14. REPEAT (Repeating string patterns)
SELECT REPEAT('*', 8) || '1234' AS masked_cc_preview;

-- 15. REVERSE (Reversing string order)
SELECT id, REVERSE(TRIM(raw_name)) AS reversed_name FROM demo_raw_text;

-- 16. LENGTH / CHAR_LENGTH (Measuring string length in characters)
SELECT id, LENGTH(TRIM(raw_name)) AS name_char_count FROM demo_raw_text;

-- 17. OCTET_LENGTH (Measuring string size in bytes — UTF8 awareness)
SELECT id, OCTET_LENGTH(description) AS byte_length FROM demo_raw_text;

-- 18. CONCAT / Pipe Operator || (Combining string columns)
SELECT id, TRIM(raw_name) || ' <' || LOWER(raw_email) || '>' AS full_contact_header FROM demo_raw_text;

-- 19. SOUNDEX / DIFFERENCE (Phonetic fuzzy sound matching)
SELECT SOUNDEX('Smith') AS smith_sound, SOUNDEX('Smyth') AS smyth_sound, DIFFERENCE('Smith', 'Smyth') AS similarity_score;

-- 20. PII Redaction Masking (Masking email usernames with asterisks)
SELECT id, 
       REGEXP_REPLACE(LOWER(raw_email), '(^.{2})(.*)(@.*$)', '\\1***\\3') AS masked_email
FROM demo_raw_text;
