# L13 · Users, Roles and GRANT

> **Module 01 · Lesson 13** · ~40 min

**Slide:** [`_render/L13-users-roles-grant.html`](_render/L13-users-roles-grant.html)

## What it is

Who is allowed. Two rules carry most of the value:

> **Grant to roles, never to people. Grant at schema level, never table by table.**

Table-by-table grants become unauditable within a month, and nobody ever dares revoke one.

## Users, groups, roles

**Roles** can be granted to other roles and can carry system privileges. **Groups** are the older mechanism. Use roles for anything new.

```sql
CREATE USER etl_svc PASSWORD DISABLE;      -- IAM auth, no password
CREATE ROLE etl_writer;
CREATE ROLE bi_reader;

GRANT ROLE etl_writer TO etl_svc;
```

`PASSWORD DISABLE` forces IAM authentication — there is no password to leak, rotate or share.

## The grant pattern that works

```sql
-- readers
GRANT USAGE  ON SCHEMA rpt TO ROLE bi_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA rpt TO ROLE bi_reader;

-- and so tomorrow's tables are covered without anyone remembering
ALTER DEFAULT PRIVILEGES IN SCHEMA rpt
  GRANT SELECT ON TABLES TO ROLE bi_reader;

-- writers
GRANT USAGE, CREATE ON SCHEMA gold TO ROLE etl_writer;
GRANT ALL ON ALL TABLES IN SCHEMA gold TO ROLE etl_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA gold
  GRANT ALL ON TABLES TO ROLE etl_writer;
```

**`ALTER DEFAULT PRIVILEGES` is the statement people forget**, and it is the reason "the new table is invisible to BI" keeps happening. Without it, every table created tomorrow needs a manual grant.

## Column-level and row-level

```sql
-- column level: the ungranted column does not appear at all
GRANT SELECT (customer_sk, region, signup_date)
  ON gold.dim_customer TO ROLE bi_reader;

-- row level
CREATE RLS POLICY region_west
  WITH (region VARCHAR(32))
  USING (region = 'WEST');

ATTACH RLS POLICY region_west ON gold.dim_store TO ROLE west_analyst;
ALTER TABLE gold.dim_store ROW LEVEL SECURITY ON;
```

Both are applied **by the engine**, not by whoever wrote the dashboard. That is the difference between a control and a convention.

For PII — the Epsilon customer data — this is the mechanism. **Mask at the column; never keep a second filtered copy.** A copy is another thing to secure, another thing to keep in sync, and another thing to leak.

## The pattern that matters most

**Reader / writer separation.**

- The **ETL role** writes. It is assumed by jobs, never by people.
- The **BI role** reads reporting views only — not base tables.
- **No human account holds both.**

## Try it

```sql
-- who has what on a schema?
SELECT nspname, nspacl FROM pg_namespace WHERE nspname IN ('gold','rpt');

-- role membership
SELECT role_name, user_name FROM svv_user_grants ORDER BY 1, 2;
SELECT * FROM svv_role_grants;

-- what can a specific role actually see?
SELECT schema_name, object_name, privilege_type
FROM   svv_relation_privileges
WHERE  identity_name = 'bi_reader'
ORDER  BY 1, 2;

-- lock down the default dumping ground
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
```

## Gotchas

- **Without `ALTER DEFAULT PRIVILEGES`, new tables are invisible** to everyone but their owner.
- **Grants clicked in a console are orphans** — no author, no reason, no reviewer, and nobody will ever dare remove them. Put every grant in Terraform.
- **Object ownership matters.** The owner can always drop the object regardless of grants; make schemas owned by a role, not a person.
- **Test masking from a real consumer role**, not from an admin session. An admin sees everything, which makes admin a useless place to test from.

## Checklist

- [ ] Grants go to roles, never to individual users
- [ ] Grants are at schema level, with `ALTER DEFAULT PRIVILEGES` set
- [ ] `CREATE ON SCHEMA public` revoked from `PUBLIC`
- [ ] PII masked with column grants, not a filtered copy
- [ ] ETL role and BI role are separate, and no human holds both
- [ ] Every grant lives in Terraform
- [ ] Masking verified from a consumer role

## You've got it when you can…

…be asked for "a copy of the customer table without the personal columns" and set up a column-level grant instead — then prove it works from the requester's own login.
