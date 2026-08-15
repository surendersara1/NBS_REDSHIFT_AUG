# L17 · Compression and Encodings

> **Module 01 · Lesson 17** · ~35 min

**Slide:** [`_render/L17-compression-encodings.html`](_render/L17-compression-encodings.html)

## What it is

Compression is chosen **per column**, not per table — which is only possible because storage is columnar.

A column of repeated country codes and a column of unique receipt numbers want completely different schemes. In a row store you could not give them one.

**Fewer bytes on disk means fewer bytes read**, so compression is a speed feature before it is a storage one.

## The encodings you will use

| Encoding | Good for |
|---|---|
| **`az64`** | numbers, dates, timestamps — AWS's own, usually best |
| **`zstd`** | text, wide `VARCHAR`s, almost anything |
| **`bytedict`** | low-cardinality columns (< 256 distinct values) |
| **`runlength`** | repeated values that sit next to each other after sorting |
| **`delta`** | slowly-incrementing integers |
| **`raw`** | deliberate: often the first sort-key column |

## Why the sort key is often `raw`

The first sort-key column is checked against zone maps on **every** scan. Leaving it uncompressed keeps that range check as cheap as possible — you trade a little space for faster block elimination on the hottest path.

It is a deliberate exception, not an oversight, and worth knowing so you do not "fix" it.

## Let Redshift tell you

```sql
ANALYZE COMPRESSION gold.fct_sales_line;
```

Returns a recommended encoding per column, measured against **your actual data**. Do not guess from the type name — a `VARCHAR` full of three distinct values wants something very different from a `VARCHAR` of unique IDs.

```sql
-- what is in effect right now?
SELECT "column", type, encoding, distkey, sortkey
FROM   pg_table_def
WHERE  schemaname = 'gold'
  AND  tablename  = 'fct_sales_line'
ORDER  BY "column";

-- which tables have any encoding at all?
SELECT "table", encoded, size AS mb, tbl_rows
FROM   svv_table_info
WHERE  encoded = 'N' AND size > 500
ORDER  BY size DESC;
```

That last query finds large uncompressed tables — usually created by a `CTAS` that nobody gave encodings to.

## Applying it

```sql
-- on an existing column, for supported transitions
ALTER TABLE gold.fct_sales_line
  ALTER COLUMN net_amount ENCODE az64;

-- or at create time, which is cleaner
CREATE TABLE gold.fct_sales_line (
    sale_date   DATE           NOT NULL ENCODE raw,      -- sort key
    store_sk    BIGINT         NOT NULL ENCODE az64,
    product_sk  BIGINT         NOT NULL ENCODE az64,
    country     VARCHAR(2)              ENCODE bytedict,
    net_amount  DECIMAL(14,2)           ENCODE az64,
    notes       VARCHAR(500)            ENCODE zstd
)
DISTKEY (store_sk)
COMPOUND SORTKEY (sale_date);
```

## COPY and automatic compression

When you `COPY` into an **empty** table with no encodings declared, Redshift samples the incoming data and applies compression automatically. That is usually good.

It does **not** happen when the table already has rows, or when you have declared encodings yourself. So a table built by an early `CTAS` and grown by appends can end up entirely uncompressed without anyone noticing.

## Try it

```sql
-- 1. build a staging copy and ask for recommendations
CREATE TABLE staging.sales_sample (LIKE gold.fct_sales_line);
INSERT INTO staging.sales_sample
SELECT * FROM gold.fct_sales_line WHERE sale_date > DATEADD(day, -7, GETDATE());

ANALYZE COMPRESSION staging.sales_sample;

-- 2. compare sizes before and after applying the recommendations
SELECT "table", size AS mb, tbl_rows, encoded
FROM   svv_table_info
WHERE  "table" IN ('fct_sales_line', 'sales_sample');
```

## Gotchas

- **`ANALYZE COMPRESSION` takes a table lock.** Run it on a staging copy, never on a production table mid-day.
- **It only recommends.** You still have to apply the encodings.
- **A `CTAS` inherits nothing** unless you say so — it is the most common source of uncompressed tables.
- **Sample data gives bad recommendations.** Run it against realistic volumes and real value distributions.

## Checklist

- [ ] Large tables are encoded — I have checked `encoded = 'N'`
- [ ] Encodings came from `ANALYZE COMPRESSION`, not from guessing
- [ ] The first sort-key column is `raw` deliberately
- [ ] I ran `ANALYZE COMPRESSION` on a staging copy, not production
- [ ] `CTAS`-created tables were given encodings explicitly
- [ ] I re-check after a big change in data shape

## You've got it when you can…

…find every large uncompressed table in a schema with one query, and produce a measured recommendation for the worst one without touching production.
