-- =========================================================================
-- 09 — Users, roles, GRANT, and the two controls the engine enforces
--
-- Two rules carry most of the value:
--
--   1. Grant to ROLES, never to people.
--   2. Grant at SCHEMA level, never table by table.
--
-- Table-by-table grants become unauditable within a month, and nobody ever
-- dares revoke one because nobody can prove what it was for.
-- =========================================================================


-- =========================================================================
-- 9.1  Users, groups, roles — and why ROLE wins
--
--   USER   a login. A person or a service.
--   GROUP  the older mechanism. Flat: a group cannot contain a group, and
--          a group cannot hold system privileges.
--   ROLE   can be granted to other ROLES, and can carry system privileges
--          (ALTER USER, ACCESS SYSTEM TABLE, CREATE SCHEMA...).
--
-- Use roles for anything new. Groups appear here only because you will meet
-- them in every existing codebase.
-- =========================================================================

-- Service account: PASSWORD DISABLE forces IAM authentication. There is no
-- password to leak, rotate, or share — and no credential in any config file.
CREATE USER etl_svc PASSWORD DISABLE;
CREATE USER bi_svc  PASSWORD DISABLE;

CREATE ROLE etl_writer;
CREATE ROLE bi_reader;
CREATE ROLE west_analyst;

GRANT ROLE etl_writer TO etl_svc;
GRANT ROLE bi_reader  TO bi_svc;

-- Roles nest. bi_reader's privileges flow into etl_writer without repeating
-- a single GRANT — this is the thing groups cannot do.
GRANT ROLE bi_reader TO ROLE etl_writer;

-- The legacy form, for recognition only. Do not write new code this way:
--   CREATE GROUP reporting_group;
--   ALTER GROUP reporting_group ADD USER learner01;
--   GRANT SELECT ON ALL TABLES IN SCHEMA rpt TO GROUP reporting_group;


-- =========================================================================
-- 9.2  The grant pattern that works
--
-- Three statements per role per schema. The third is the one everyone
-- forgets, and it is the reason "the new table is invisible to BI" keeps
-- happening: without it, every table created tomorrow needs a manual grant.
-- =========================================================================

-- readers
GRANT USAGE  ON SCHEMA rpt TO ROLE bi_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA rpt TO ROLE bi_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA rpt
  GRANT SELECT ON TABLES TO ROLE bi_reader;

-- writers
GRANT USAGE, CREATE ON SCHEMA analytics TO ROLE etl_writer;
GRANT ALL ON ALL TABLES IN SCHEMA analytics TO ROLE etl_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics
  GRANT ALL ON TABLES TO ROLE etl_writer;

GRANT USAGE, CREATE ON SCHEMA staging TO ROLE etl_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA staging
  GRANT ALL ON TABLES TO ROLE etl_writer;

-- ALTER DEFAULT PRIVILEGES GOTCHA, and it is a nasty one: the default
-- applies only to objects created by the user who RAN the statement. If
-- nbsadmin runs it and then etl_svc creates a table, the default does NOT
-- apply. For shared schemas, run it FOR the creating role explicitly:
ALTER DEFAULT PRIVILEGES FOR USER etl_svc IN SCHEMA analytics
  GRANT SELECT ON TABLES TO ROLE bi_reader;


-- =========================================================================
-- 9.3  Column-level security — the ungranted column does not appear
-- =========================================================================
CREATE TABLE IF NOT EXISTS analytics.dim_customer_pii (
    customer_sk    BIGINT      NOT NULL,
    customer_id    BIGINT      NOT NULL,
    region         VARCHAR(32),
    signup_date    DATE,
    email          VARCHAR(256),      -- PII
    phone          VARCHAR(32),       -- PII
    tax_id         VARCHAR(32)        -- PII
)
DISTSTYLE ALL SORTKEY (customer_sk);

INSERT INTO analytics.dim_customer_pii
SELECT customer_id, customer_id,
       CASE WHEN country IN ('US','CA','BR') THEN 'WEST' ELSE 'EAST' END,
       signup_date,
       'user' || customer_id || '@example.com',
       '+1-555-' || LPAD(customer_id::VARCHAR, 4, '0'),
       'TAX' || LPAD(customer_id::VARCHAR, 9, '0')
FROM   s3t_bronze.bronze_customers;

-- Grant only the non-PII columns. bi_reader cannot see email/phone/tax_id
-- at all — not masked, absent. SELECT * fails rather than returning nulls.
GRANT SELECT (customer_sk, customer_id, region, signup_date)
  ON analytics.dim_customer_pii TO ROLE bi_reader;

-- For PII, this is the mechanism. Mask at the column; never keep a second
-- filtered copy. A copy is another thing to secure, another thing to keep
-- in sync, and another thing to leak.


-- =========================================================================
-- 9.4  Row-level security — narrowing which rows a role sees
-- =========================================================================
CREATE RLS POLICY region_west
WITH (region VARCHAR(32))
USING (region = 'WEST');

CREATE RLS POLICY region_east
WITH (region VARCHAR(32))
USING (region = 'EAST');

ATTACH RLS POLICY region_west ON analytics.dim_customer_pii TO ROLE west_analyst;

-- Nothing is enforced until RLS is switched on for the table:
ALTER TABLE analytics.dim_customer_pii ROW LEVEL SECURITY ON;

-- Both CLS and RLS are applied by the ENGINE, not by whoever wrote the
-- dashboard. That is the difference between a control and a convention:
-- a convention is one careless WHERE clause away from failing.

-- Inspect policies:
SELECT * FROM svv_rls_policy;
SELECT * FROM svv_rls_attached_policy;
SELECT * FROM svv_rls_relation;

-- RLS gotchas worth stating:
--   * A superuser bypasses RLS entirely. Test as the actual role.
--     SET SESSION AUTHORIZATION west_analyst;  ... ; RESET SESSION AUTHORIZATION;
--   * A user with no attached policy on an RLS-enabled table sees NO rows,
--     not all rows. Fail-closed, which is correct but surprising.
--   * RLS and materialized views interact badly — an MV built by a
--     privileged role stores unfiltered rows, and reading the MV bypasses
--     the policy. Do not put RLS-protected data in an MV that others read.


-- =========================================================================
-- 9.5  The pattern that matters most — reader / writer separation
--
--   etl_writer   writes. Assumed by JOBS, never by people. PASSWORD DISABLE.
--   bi_reader    reads reporting views only. Never base tables.
--   No human account holds both.
--
-- The reason: an incident where a person with write access runs an UPDATE
-- against production at 2am is not a training problem, it is a design
-- problem. Remove the capability and the incident cannot happen.
-- =========================================================================

-- People get read. Jobs get write.
GRANT ROLE bi_reader TO learner01, learner02, learner03, learner04,
                        learner05, learner06, learner07, learner08;

-- Lock down the default dumping ground. Every Redshift database ships with
-- a `public` schema that PUBLIC can CREATE in — meaning any user can create
-- objects nobody governs. Revoke it on day one, every cluster:
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON DATABASE coaching FROM PUBLIC;


-- =========================================================================
-- 9.6  Verifying it — the queries to run after any grant change
-- =========================================================================

-- Who has what on a schema? nspacl is the raw ACL, and it is the ground
-- truth when the friendlier views disagree with your expectations.
SELECT nspname, nspacl
FROM   pg_namespace
WHERE  nspname IN ('analytics','rpt','staging','public');

-- Role membership.
SELECT role_name, user_name FROM svv_user_grants ORDER BY 1, 2;
SELECT * FROM svv_role_grants;                  -- role -> role nesting

-- What can a specific role actually see?
SELECT namespace_name, relation_name, privilege_type
FROM   svv_relation_privileges
WHERE  identity_name = 'bi_reader'
ORDER  BY 1, 2;

-- Column-level grants specifically — these do NOT show up in the
-- relation-level view, which is why a CLS grant looks "missing".
SELECT namespace_name, relation_name, column_name, identity_name, privilege_type
FROM   svv_column_privileges
WHERE  identity_name = 'bi_reader'
ORDER  BY 1, 2, 3;

-- System privileges (role-only).
SELECT * FROM svv_system_privileges WHERE identity_name IN ('ops_role','etl_writer');

-- Every user and their attributes — usesuper is the column to audit.
SELECT usename, usesysid, usecreatedb, usesuper, useconnlimit
FROM   pg_user ORDER BY usename;

-- Prove the boundary by becoming the role:
--   SET SESSION AUTHORIZATION bi_svc;
--   SELECT * FROM analytics.dim_customer_pii;   -- should fail on PII columns
--   SELECT customer_sk, region FROM analytics.dim_customer_pii;  -- should work
--   SELECT * FROM staging.orders;               -- should fail entirely
--   RESET SESSION AUTHORIZATION;


-- =========================================================================
-- 9.7  Gotchas, collected
--
--  1. ALTER DEFAULT PRIVILEGES applies only to objects created by the user
--     who ran it. Use FOR USER <creator> in shared schemas.
--  2. Ownership beats grants. The object owner keeps full control even
--     after a REVOKE. Transfer with ALTER TABLE ... OWNER TO.
--  3. Superusers bypass RLS and CLS entirely. Never test as superuser.
--  4. Revoking from a ROLE does not revoke a grant made directly to a USER.
--     Direct user grants are exactly why rule 1 exists.
--  5. Late-binding views do not carry base-table permissions the way bound
--     views do — grant on the view AND ensure the querying role can reach
--     what it references, or use a SECURITY DEFINER path.
--  6. External tables are governed by Lake Formation, not by these GRANTs.
--     See file 08 §8.4.
--  7. DROP USER fails while the user owns any object or holds any grant.
--     Reassign first: ALTER TABLE ... OWNER TO; then DROP USER.
-- =========================================================================
