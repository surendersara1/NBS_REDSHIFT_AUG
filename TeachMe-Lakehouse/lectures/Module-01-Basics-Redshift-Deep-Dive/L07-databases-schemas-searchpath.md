# L07 · Databases, Schemas and search_path

> **Module 01 · Lesson 07** · ~30 min

**Slide:** [`_render/L07-databases-schemas-searchpath.html`](_render/L07-databases-schemas-searchpath.html)

## What it is

The hierarchy is **database → schema → table**, and you **cannot join across databases**.

That last part surprises people arriving from MySQL, where `db1.table` and `db2.table` in one query is routine. Here, one connection is to one database, and **schemas** — not databases — are how you separate layers, teams and environments inside it.

## The four things that decide which table you hit

### Database — a hard boundary
To read another database you need a **datashare** or an **external schema**. There is no three-part name that works.

### Schema — where separation actually happens
One schema per layer. Grants applied at schema level rather than table by table (L13).

```
raw        -- landed, untouched
staging    -- being processed, safe to truncate
gold       -- modelled facts and dimensions
rpt        -- reporting views, what BI sees
lake_ext   -- external schema over S3
```

### search_path — the one that catches people
An **ordered list of schemas** searched for an unqualified table name. It is a **session** setting, so two people can run identical SQL and read different tables.

```sql
SHOW search_path;
SET  search_path TO gold, staging, public;
```

This is the `PATH` variable of SQL. *"It works on my machine"* has exactly the same cause here as it does in a shell.

### public — the default dumping ground
Exists by default, and by default everyone can create in it. Revoke that on day one or it fills with somebody's `test_2`, `test_2_final`, `test_2_final_v3`.

```sql
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
```

## The rule

> **Always schema-qualify in anything committed to a repository.**

```sql
-- fine interactively, a bug in a repo
SELECT * FROM fct_sales_line;

-- correct anywhere
SELECT * FROM gold.fct_sales_line;
```

An unqualified name in a dbt model, a stored procedure or a Node query string is a bug waiting for someone else's `search_path`.

## Try it

```sql
-- what schemas exist, and what kind are they?
SELECT database_name, schema_name, schema_owner, schema_type
FROM   svv_all_schemas
ORDER  BY 1, 2;

-- what tables live in each?
SELECT table_schema, COUNT(*) AS tables
FROM   svv_all_tables
GROUP  BY 1
ORDER  BY 2 DESC;

-- who can create in public? (should be nobody)
SELECT nspname, nspacl FROM pg_namespace WHERE nspname = 'public';
```

`svv_all_schemas` and `svv_all_tables` include **external** schemas too, which the older `pg_*` catalogue views do not. Prefer the `svv_all_*` views.

## Creating a schema properly

```sql
CREATE SCHEMA IF NOT EXISTS gold;
ALTER  SCHEMA gold OWNER TO etl_role;

GRANT USAGE ON SCHEMA gold TO ROLE bi_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA gold TO ROLE bi_reader;

-- and so tomorrow's tables are covered without anyone remembering
ALTER DEFAULT PRIVILEGES IN SCHEMA gold
  GRANT SELECT ON TABLES TO ROLE bi_reader;
```

That last statement is the one people forget, and the reason "the new table is invisible to BI" keeps happening (L13).

## Gotchas

- **No cross-database joins. None.** Use a datashare or an external schema.
- **`search_path` is per session.** A stored procedure may run with a different one than you tested with.
- **Dropping a schema with `CASCADE` drops everything in it**, including tables other people depend on.
- **Object names are lower-cased** unless you double-quote them. Do not double-quote them.

## Checklist

- [ ] I know you cannot join across databases
- [ ] I use schemas as the layer boundary
- [ ] I schema-qualify everything I commit
- [ ] I have revoked `CREATE ON SCHEMA public FROM PUBLIC`
- [ ] I set `ALTER DEFAULT PRIVILEGES` when creating a schema
- [ ] I use `svv_all_schemas` rather than the `pg_*` views

## You've got it when you can…

…debug "the query returns different rows for her than for me" by asking about `search_path` before looking at the data.
