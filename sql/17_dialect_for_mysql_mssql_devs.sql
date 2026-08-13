-- =========================================================================
-- 17 — Redshift SQL for MySQL and SQL Server developers
--
-- Read this BEFORE writing any SQL. You know SQL; you do not know THIS SQL,
-- and the differences are the kind that fail at 4pm on a Friday.
--
-- Redshift is PostgreSQL 8.0.2 wire-compatible. So:
--   * if you come from SQL Server, almost none of your T-SQL habits port
--   * if you come from MySQL, the quoting and the functions are different
--   * and even Postgres developers hit the columnar/MPP differences
--
-- Run every statement in this file. The failures are the point.
-- =========================================================================


-- =========================================================================
-- 17.1  Row limiting
-- =========================================================================
--  SQL Server:  SELECT TOP 10 * FROM t
--  MySQL:       SELECT * FROM t LIMIT 10
--  Redshift:    LIMIT works; TOP also works. Prefer LIMIT.
SELECT * FROM analytics.dim_country LIMIT 3;
SELECT TOP 3 * FROM analytics.dim_country;      -- also valid, less portable

-- Pagination. There is no OFFSET/FETCH in the T-SQL form:
SELECT * FROM analytics.dim_country ORDER BY country_code LIMIT 3 OFFSET 3;
-- OFFSET on a large table is a full scan to the offset. For real
-- pagination, use a keyset: WHERE country_code > <last_seen> ORDER BY ... LIMIT n


-- =========================================================================
-- 17.2  NULL handling — the function names are all different
-- =========================================================================
--  SQL Server ISNULL(a,b)   MySQL IFNULL(a,b)   Redshift NVL(a,b) or COALESCE
SELECT NVL(NULL, 'fallback')            AS nvl_works,
       COALESCE(NULL, NULL, 'third')    AS coalesce_works,
       NULLIF('same','same')            AS nullif_gives_null,
       NVL2(NULL, 'not_null', 'is_null') AS nvl2_works;
-- ISNULL() and IFNULL() DO NOT EXIST. They fail with "function does not exist".

-- SQL Server's ISNULL(col, 0) in an aggregate is usually wrong anyway:
SELECT SUM(NVL(quantity, 0)) AS treats_null_as_zero,
       SUM(quantity)         AS ignores_null_entirely
FROM   analytics.fct_customer_orders;


-- =========================================================================
-- 17.3  Dates — the biggest source of ported-code bugs
-- =========================================================================
--  SQL Server GETDATE()      MySQL NOW()      Redshift SYSDATE / GETDATE()
SELECT SYSDATE                         AS sysdate_no_parens,
       GETDATE()                       AS getdate_works,
       CURRENT_DATE                    AS current_date_no_parens,
       CURRENT_TIMESTAMP               AS current_timestamp;
-- SYSDATE takes NO parentheses. SYSDATE() is a syntax error.
-- NOW() exists but returns the TRANSACTION start time, not the statement
-- time — inside a long procedure it does not advance.

-- DATEADD / DATEDIFF: the argument ORDER differs from SQL Server.
--   SQL Server: DATEADD(day, 7, @d)     Redshift: DATEADD(day, 7, d)   same
--   SQL Server: DATEDIFF(day, a, b)     Redshift: DATEDIFF(day, a, b)  same
--   MySQL:      DATEDIFF(a, b)          <- 2 args, OPPOSITE sign. Different.
SELECT DATEADD(day, 7, '2026-01-01'::DATE)                AS plus_seven,
       DATEDIFF(day, '2026-01-01', '2026-01-08')          AS diff_is_7,
       DATE_TRUNC('month', '2026-01-15'::DATE)            AS month_start,
       EXTRACT(year FROM '2026-01-15'::DATE)              AS year_part,
       TO_CHAR('2026-01-15'::DATE, 'YYYY-MM')             AS formatted;

-- CONVERT(VARCHAR(10), d, 120) and FORMAT() do not exist. Use TO_CHAR.
-- And remember file 11: never put any of these around a SORT KEY in WHERE.


-- =========================================================================
-- 17.4  Strings
-- =========================================================================
--  SQL Server:  'a' + 'b'          -- + is concat
--  MySQL:       CONCAT('a','b')    -- + is ARITHMETIC
--  Redshift:    'a' || 'b'         -- || is concat; + on strings is an ERROR
SELECT 'a' || 'b'                      AS pipe_concat,
       CONCAT('a', 'b')                AS concat_two_args_only,
       LEN('hello')                    AS len_works,
       LENGTH('hello')                 AS length_also_works,
       SUBSTRING('abcdef', 2, 3)       AS substring_works,
       POSITION('c' IN 'abcdef')       AS position_works,
       STRPOS('abcdef', 'c')           AS strpos_works,
       UPPER('x'), LOWER('X'), TRIM('  x  '),
       REPLACE('a-b','-','_')          AS replace_works,
       SPLIT_PART('a,b,c', ',', 2)     AS split_part_gives_b;
-- CHARINDEX(), STUFF(), STRING_AGG() do not exist.
-- CONCAT() takes exactly TWO arguments in Redshift — chain || for more.

-- Aggregating strings: SQL Server STRING_AGG / MySQL GROUP_CONCAT
SELECT region, LISTAGG(country_code, ',') WITHIN GROUP (ORDER BY country_code)
FROM   analytics.dim_country GROUP BY region;
-- LISTAGG has a 65535-byte limit per group and will error above it.


-- =========================================================================
-- 17.5  Identifiers and quoting
-- =========================================================================
--  MySQL:      `backticks`
--  SQL Server: [brackets]
--  Redshift:   "double quotes" — backticks and brackets are SYNTAX ERRORS
SELECT country_code AS "Country Code" FROM analytics.dim_country LIMIT 1;

-- Unquoted identifiers FOLD TO LOWERCASE. These are the same object:
--   CREATE TABLE MyTable ...   ->   mytable
--   SELECT * FROM MYTABLE      ->   works
-- But "MyTable" (quoted) is a DIFFERENT, case-sensitive object. Never quote
-- identifiers in DDL — it creates objects nobody can reference without
-- quoting forever after. snake_case everywhere.

-- String literals are SINGLE quotes only. "abc" is an identifier, not text.
SELECT 'this is a string';
-- SELECT "this is not";     -- ERROR: column does not exist


-- =========================================================================
-- 17.6  Temp tables and variables
-- =========================================================================
--  SQL Server: #temp, ##global, @variable, DECLARE @x INT
--  Redshift:   #temp or CREATE TEMP TABLE. NO session variables at all.
CREATE TEMP TABLE #t_demo AS SELECT * FROM analytics.dim_country LIMIT 3;
SELECT COUNT(*) FROM #t_demo;

-- There is no DECLARE @x outside a stored procedure. Inside a procedure,
-- variables are PL/pgSQL DECLARE blocks (see file 05). At the session level
-- the substitutes are:
--   * a one-row temp table
--   * a CTE
--   * SET a runtime parameter (configuration only, not user values)


-- =========================================================================
-- 17.7  The things that DO NOT EXIST, and what to use instead
--
--   IDENTITY/AUTO_INCREMENT ->  IDENTITY(1,1), but values are NOT gapless
--                               and NOT ordered. Never a business key.
--   Indexes                 ->  SORTKEY + DISTKEY (files 10, 11)
--   Enforced PK/UNIQUE/FK   ->  tests (file 13)
--   Triggers                ->  nothing. Do it in the pipeline.
--   Cursors (freely)        ->  ONE at a time, cluster-wide (file 05)
--   MERGE (historically)    ->  MERGE now exists; DELETE+INSERT still
--                               preferred for whole-partition reloads
--   User-defined types      ->  nothing
--   Computed columns        ->  a view, or compute on load
--   Table variables         ->  temp tables
--   sp_executesql           ->  EXECUTE inside a procedure
--   TRY/CATCH               ->  BEGIN...EXCEPTION, but NO subtransactions,
--                               so partial rollback is not available
--   XML / JSON functions    ->  the SUPER type + PartiQL (see 17.9)
--   Python UDFs             ->  END OF SUPPORT 2026-06-30. SQL or Lambda UDFs.
-- =========================================================================


-- =========================================================================
-- 17.8  Data types — the mapping that matters
--
--   SQL Server            MySQL              Redshift
--   ----------            -----              --------
--   NVARCHAR(n)           VARCHAR(n)         VARCHAR(n)   bytes, not chars!
--   VARCHAR(MAX)          TEXT/LONGTEXT      VARCHAR(65535)  hard max
--   DATETIME/DATETIME2    DATETIME           TIMESTAMP
--   DATETIMEOFFSET        —                  TIMESTAMPTZ
--   BIT                   TINYINT(1)         BOOLEAN
--   MONEY                 DECIMAL            DECIMAL(18,2)
--   UNIQUEIDENTIFIER      CHAR(36)           CHAR(36) or VARCHAR(36)
--   TINYINT               TINYINT            SMALLINT   (no TINYINT)
--   NTEXT/IMAGE/BLOB      BLOB               —          not supported
--
-- VARCHAR(n) COUNTS BYTES, NOT CHARACTERS. A VARCHAR(10) holds ten ASCII
-- characters but only two or three emoji, and a multi-byte name silently
-- fails the load with "value too long". When migrating from NVARCHAR(50),
-- size to VARCHAR(200) unless you have measured otherwise.
-- =========================================================================
SELECT LEN('cafe')              AS ascii_len,
       OCTET_LENGTH('cafe')     AS ascii_bytes,
       LEN('café')              AS accented_len,
       OCTET_LENGTH('café')     AS accented_bytes;   -- bytes > length


-- =========================================================================
-- 17.9  Semi-structured data — SUPER and PartiQL
--
-- You will get JSON. This is how Redshift handles it natively, without
-- shredding it into columns first.
-- =========================================================================
DROP TABLE IF EXISTS analytics.events_json;

CREATE TABLE analytics.events_json (
    event_id   BIGINT,
    payload    SUPER            -- the semi-structured type
) DISTSTYLE EVEN;

INSERT INTO analytics.events_json
SELECT 1, JSON_PARSE('{"user":{"id":42,"tier":"gold"},"items":[{"sku":"A1","qty":2},{"sku":"B2","qty":1}]}')
UNION ALL
SELECT 2, JSON_PARSE('{"user":{"id":43,"tier":"silver"},"items":[{"sku":"C3","qty":5}]}');

-- Dot and bracket navigation — no JSON_VALUE, no OPENJSON.
SELECT event_id,
       payload.user.id::BIGINT      AS user_id,
       payload.user.tier::VARCHAR   AS tier,
       payload.items[0].sku::VARCHAR AS first_sku
FROM   analytics.events_json;

-- Unnest an array into rows — the PartiQL equivalent of CROSS APPLY /
-- JSON_TABLE. Note the FROM clause references the array directly.
SELECT e.event_id,
       i.sku::VARCHAR AS sku,
       i.qty::INTEGER AS qty
FROM   analytics.events_json e, e.payload.items AS i;

-- Casting is REQUIRED. Without ::VARCHAR you get a SUPER value, which
-- compares and sorts differently and will surprise you in a WHERE clause.
SELECT COUNT(*) FROM analytics.events_json
WHERE  payload.user.tier::VARCHAR = 'gold';

-- Loading JSON from S3 straight into SUPER:
--   COPY analytics.events_json FROM 's3://.../events/'
--   IAM_ROLE '...' FORMAT JSON 'auto';
--
-- WHEN NOT TO USE SUPER: if you always read the same five fields, shred
-- them into real columns on load. SUPER is stored as a single column, so
-- you lose columnar projection and the zone maps that make Redshift fast.
-- SUPER is for genuinely variable payloads, not for avoiding schema design.


-- =========================================================================
-- 17.10  Habits to unlearn, ranked by how much they will cost you
--
--   1. SELECT *              Columnar storage means you pay per column.
--                            Name your columns. Always.
--   2. Row-by-row DML        UPDATE ... WHERE id = ? in a loop is thousands
--                            of times slower here. Think in sets.
--   3. Single-row INSERT     INSERT ... VALUES one row at a time is the
--                            worst thing you can do to Redshift. COPY, or
--                            INSERT ... SELECT.
--   4. Trusting constraints  They are not enforced (file 13).
--   5. Adding an index       There are none (files 10, 11).
--   6. Small frequent commits Each commit has fixed overhead. Batch.
--   7. DISTINCT as a fix     Usually hides a join fan-out bug. Find the
--                            duplicate instead.
--   8. Wrapping WHERE columns Kills zone maps (file 11 §11.6).
--
-- The single sentence to remember: Redshift is optimised for reading a lot
-- of rows and a few columns, in bulk. Every OLTP instinct is backwards.
-- =========================================================================


-- =========================================================================
-- 17.11  Checklist
--
--   [ ] I use || for concatenation, not +
--   [ ] I use NVL/COALESCE, not ISNULL/IFNULL
--   [ ] I use double quotes for identifiers, never backticks or brackets
--   [ ] All my identifiers are snake_case and unquoted
--   [ ] I sized VARCHAR in BYTES, allowing for multi-byte characters
--   [ ] I never write single-row INSERTs in a loop
--   [ ] I name columns instead of SELECT *
--   [ ] I know SUPER exists and when NOT to use it
-- =========================================================================
