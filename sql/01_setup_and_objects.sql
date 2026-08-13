-- =========================================================================
-- 01 — Databases, schemas, users, groups, and every object type Redshift has
--
-- Run as: nbsadmin, connected to the `coaching` database.
-- Tool:   Redshift Query Editor v2 (console) — no VPN or psql needed.
--
-- READ THIS FIRST if you come from application development:
--   Redshift is PostgreSQL 8.0.2 wire-compatible, and that similarity is a
--   trap. It has no enforced foreign keys, no enforced unique constraints,
--   no SERIAL that behaves like Postgres, and no indexes at all. What it has
--   instead is distribution and sort keys. File 04 is about that difference.
-- =========================================================================


-- -------------------------------------------------------------------------
-- 1.1  Databases
--
-- The cluster was created with db_name='coaching'. A cluster can hold many
-- databases, but cross-database queries are read-only and RA3-only.
-- Convention on real projects: one database per environment, schemas for
-- domain separation. Do not create a database per team.
-- -------------------------------------------------------------------------
SELECT current_database(), current_user, version();

SELECT database_name, database_owner, database_type
FROM   svv_redshift_databases
ORDER  BY database_name;


-- -------------------------------------------------------------------------
-- 1.2  Schemas — the layer boundary
--
-- staging       COPY lands here. Truncate-and-load. No consumers.
-- analytics     Modelled tables + materialized views. Gold layer.
-- spectrum_raw  external schema -> Glue catalog        (file 02)
-- s3t           external schema -> S3 Tables catalog   (file 03)
-- admin         the awslabs admin views                (file 06)
-- -------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS admin;

COMMENT ON SCHEMA staging   IS 'COPY landing zone. Truncate-and-load, no direct consumers.';
COMMENT ON SCHEMA analytics IS 'Modelled gold layer. Tables + MVs that BI and apps read.';
COMMENT ON SCHEMA admin     IS 'Operational views (awslabs amazon-redshift-utils).';

-- Schema quota — the single most effective guard against one learner filling
-- managed storage for the whole room.
ALTER SCHEMA staging   QUOTA 20 GB;
ALTER SCHEMA analytics QUOTA 50 GB;


-- -------------------------------------------------------------------------
-- 1.3  Users and groups (RBAC)
--
-- Redshift has BOTH the legacy GROUP model and the newer ROLE model.
-- Use ROLEs for new work — they nest, groups do not. Both appear here
-- because you will meet groups in every existing codebase.
--
-- CREDENTIALS: this file deliberately contains no passwords. Create the
-- eight learner logins with scripts/create_learners.sh, which generates a
-- random password per learner, stores it in Secrets Manager, and prints the
-- retrieval command. Never commit a CREATE USER ... PASSWORD literal — it
-- lands in git history, in STL_QUERYTEXT, and in the Query Editor v2 history
-- of whoever ran it.
--
-- After running that script you will have learner01..learner08.
-- -------------------------------------------------------------------------

-- Role model (preferred)
CREATE ROLE analyst_role;
CREATE ROLE engineer_role;
CREATE ROLE ops_role;

GRANT USAGE  ON SCHEMA analytics TO ROLE analyst_role;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO ROLE analyst_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics
  GRANT SELECT ON TABLES TO ROLE analyst_role;
-- ALTER DEFAULT PRIVILEGES is the line people forget. Without it, every
-- table created tomorrow is invisible to the role you granted today.

GRANT ROLE analyst_role TO ROLE engineer_role;      -- roles nest
GRANT ALL    ON SCHEMA staging   TO ROLE engineer_role;
GRANT CREATE ON SCHEMA analytics TO ROLE engineer_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA staging
  GRANT ALL ON TABLES TO ROLE engineer_role;

-- System privileges are role-only; a GROUP cannot hold them.
GRANT ACCESS SYSTEM TABLE TO ROLE ops_role;

GRANT ROLE engineer_role TO learner01, learner02, learner03, learner04,
                            learner05, learner06, learner07, learner08;
GRANT ROLE ops_role      TO learner01;   -- rotate the "on-call" learner daily

-- Why the learner accounts are created with SYSLOG ACCESS UNRESTRICTED in
-- that script: without it a non-superuser sees only their OWN rows in the
-- SYS_/STL_ views, and every monitoring lab in file 06 returns one row.
-- It exposes other users' query text, so it is a teaching-cluster setting
-- only — never carry it to production.


-- -------------------------------------------------------------------------
-- 1.4  Every object type, so nothing is a surprise later
-- -------------------------------------------------------------------------

-- (a) Permanent table
CREATE TABLE IF NOT EXISTS analytics.dim_country (
    country_code  CHAR(2)      NOT NULL,
    country_name  VARCHAR(64)  NOT NULL,
    region        VARCHAR(32)
)
DISTSTYLE ALL                 -- tiny lookup: replicate to every node
SORTKEY (country_code);

-- (b) Temporary table — session-scoped, dropped at disconnect.
--     '#name' and 'TEMP' are equivalent. Temp tables live in a per-session
--     schema that shadows permanent ones: create #dim_country and every
--     unqualified reference in that session silently hits the temp copy.
CREATE TEMP TABLE tmp_scratch (id BIGINT, note VARCHAR(256));

-- (c) View — logical, no storage. WITH NO SCHEMA BINDING lets it survive a
--     DROP of its base table, and is REQUIRED for views over external tables.
CREATE OR REPLACE VIEW analytics.v_country_regions AS
    SELECT region, COUNT(*) AS country_count
    FROM   analytics.dim_country
    GROUP  BY region
WITH NO SCHEMA BINDING;

-- (d) Scalar SQL UDF.
--     NOTE: Redshift Python UDFs reached end of support on 2026-06-30.
--     Do not write them. Use SQL UDFs for expressions, and Lambda UDFs when
--     you need procedural logic or an external call.
CREATE OR REPLACE FUNCTION analytics.f_net_amount(gross DECIMAL(18,2), rate DECIMAL(5,4))
RETURNS DECIMAL(18,2)
STABLE
AS $$
    SELECT ROUND($1 * (1 - $2), 2)
$$ LANGUAGE sql;

-- (e) Identity column — Redshift's SERIAL equivalent.
--     Values are unique but NOT gapless and NOT ordered across slices.
--     Never expose an identity value as a business key.
CREATE TABLE IF NOT EXISTS analytics.audit_log (
    audit_id    BIGINT IDENTITY(1,1),
    event_ts    TIMESTAMP DEFAULT SYSDATE,
    actor       VARCHAR(128) DEFAULT current_user,
    event_type  VARCHAR(64),
    detail      VARCHAR(2000)
)
DISTSTYLE EVEN
SORTKEY (event_ts);

INSERT INTO analytics.dim_country VALUES
    ('US','United States','AMER'), ('CA','Canada','AMER'),
    ('BR','Brazil','AMER'),        ('GB','United Kingdom','EMEA'),
    ('DE','Germany','EMEA'),       ('FR','France','EMEA'),
    ('AE','United Arab Emirates','EMEA'),
    ('IN','India','APAC'),         ('AU','Australia','APAC'),
    ('JP','Japan','APAC');

-- Constraints exist but are NOT enforced. They are optimizer hints only.
-- Declaring them is still worthwhile: the planner uses PK/FK for join
-- elimination and better row estimates. Declaring a PK that is actually
-- duplicated produces WRONG results, so only declare what you enforce
-- upstream.
ALTER TABLE analytics.dim_country ADD PRIMARY KEY (country_code);

SELECT 'setup complete' AS status, COUNT(*) AS countries FROM analytics.dim_country;
