# L08 · CREATE TABLE, Anatomy Of

> **Module 01 · Lesson 08** · ~45 min

**Slide:** [`_render/L08-create-table-anatomy.html`](_render/L08-create-table-anatomy.html)

## What it is

In Postgres you create a table and add indexes later. In Redshift **physical layout is part of the schema**, declared at create time — and changing it means rebuilding the table.

That raises the stakes on `CREATE TABLE` considerably. Get `DISTKEY` and `SORTKEY` right; everything else is tunable later.

## The full anatomy

```sql
CREATE TABLE gold.fct_sales_line (
    sale_date     DATE            NOT NULL,
    store_sk      BIGINT          NOT NULL,
    product_sk    BIGINT          NOT NULL,
    receipt_no    VARCHAR(32),
    quantity      DECIMAL(12,3),
    net_amount    DECIMAL(14,2)   ENCODE az64,
    vat_amount    DECIMAL(14,2)   ENCODE az64,
    merge_key     VARCHAR(64)     NOT NULL,
    loaded_at     TIMESTAMP       DEFAULT SYSDATE
)
DISTSTYLE KEY
DISTKEY  (store_sk)
COMPOUND SORTKEY (sale_date, store_sk);
```

| Clause | What it does | Changeable later? |
|---|---|---|
| `DISTSTYLE` / `DISTKEY` | where rows land across slices | ❌ rebuild |
| `SORTKEY` | physical order on disk | ❌ rebuild |
| `ENCODE` | per-column compression | ⚠️ some, via `ALTER` |
| `NOT NULL` | **enforced** | ✅ |
| `PRIMARY KEY` / `UNIQUE` / `FOREIGN KEY` | **informational only** | ✅ |
| `DEFAULT` | default value | ✅ |

## The two that matter

**`DISTKEY`** — pick the column this table is most often **joined** on, ideally with high cardinality. For a fact table that is usually the busiest foreign key. Get it wrong and every join ships data between nodes (L15, L29).

**`SORTKEY`** — pick the column you most often **filter** on. For almost every retail fact that is the date. Redshift keeps min/max per block and skips blocks that cannot match (L16).

> A useful mnemonic: **DIST for joins, SORT for filters.**

## The clause that catches everyone

```sql
CREATE TABLE dim_store (
  store_sk BIGINT PRIMARY KEY,   -- NOT enforced
  store_id VARCHAR(20) UNIQUE,   -- NOT enforced
  ...
);

INSERT INTO dim_store VALUES (1, 'S001');
INSERT INTO dim_store VALUES (1, 'S001');   -- succeeds. twice.
```

`PRIMARY KEY`, `UNIQUE` and `FOREIGN KEY` are **informational only** — they inform the query planner and are otherwise ignored. Only `NOT NULL` is enforced.

Declare them anyway (the planner uses them), but **test for uniqueness separately** — in dbt, or with a query in your load job (L18).

## Other creation forms

```sql
-- from a query, inheriting nothing about layout unless you say so
CREATE TABLE staging.sales_tmp
  DISTKEY (store_sk) SORTKEY (sale_date)
AS SELECT * FROM raw.sales WHERE dt = '2026-08-12';

-- structure only, no rows — copies dist/sort/encodings
CREATE TABLE staging.sales_like (LIKE gold.fct_sales_line);

-- session-scoped, disappears on disconnect
CREATE TEMP TABLE t_recent AS SELECT ...;
```

`CREATE TABLE LIKE` is the right way to build a staging table that matches its target — it inherits the physical design, so the final swap is cheap.

## Try it

```sql
-- what did Redshift actually create?
SELECT "table", diststyle, sortkey1, sortkey_num, encoded
FROM   svv_table_info
WHERE  "schema" = 'gold';

-- the full DDL of an existing table
SELECT ddl FROM admin.v_generate_tbl_ddl WHERE tablename = 'fct_sales_line';
-- (v_generate_tbl_ddl is an AWS-published admin view; if it is not
--  installed, svv_table_info plus pg_table_def gets you most of the way)

SELECT "column", type, encoding, distkey, sortkey, "notnull"
FROM   pg_table_def
WHERE  schemaname = 'gold' AND tablename = 'fct_sales_line';
```

## Gotchas

- **You cannot `ALTER` a `DISTKEY` or `SORTKEY`.** You create a new table, load it, and swap names.
- **`CTAS` does not inherit dist/sort** unless you state them — a very common way to accidentally create an `EVEN`-distributed copy.
- **`DEFAULT SYSDATE` is evaluated at insert**, which makes it useful as a load timestamp.
- **There is no `SERIAL` you should rely on.** `IDENTITY` exists but values are not gap-free across slices; generate surrogate keys deliberately.

## Checklist

- [ ] I state `DISTKEY` and `SORTKEY` explicitly on every fact table
- [ ] I know only `NOT NULL` is enforced
- [ ] I test uniqueness rather than declaring it and trusting it
- [ ] I use `CREATE TABLE LIKE` for staging tables
- [ ] I remember `CTAS` needs dist/sort stated
- [ ] I can read `pg_table_def` to see what a table really is

## You've got it when you can…

…write a `CREATE TABLE` for a new fact, justify the `DISTKEY` and `SORTKEY` out loud in one sentence each, and say what you would have to do to change them later.
