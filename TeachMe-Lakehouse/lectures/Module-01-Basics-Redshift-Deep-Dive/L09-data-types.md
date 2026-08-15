# L09 · Data Types That Will Bite You

> **Module 01 · Lesson 09** · ~35 min

**Slide:** [`_render/L09-data-types.html`](_render/L09-data-types.html)

## What it is

The type list looks familiar. Four entries behave differently enough from Postgres to cause real bugs — and one of them silently loses money.

## 1 · VARCHAR width is not free

There is **no `TEXT` type**. Every `VARCHAR` has a declared width, and that width affects how much memory a query reserves **per row** for sorts, joins and aggregations.

Declaring everything `VARCHAR(65535)` "to be safe" makes hash joins and sorts spill to disk, and turns a fast query into a slow one for no benefit.

```sql
-- measure before you size
SELECT MAX(octet_length(product_name)) AS max_bytes,
       MAX(length(product_name))       AS max_chars,
       AVG(octet_length(product_name)) AS avg_bytes
FROM   staging.products;
```

Size from `max_bytes`, with a sensible margin — not from imagination.

## 2 · VARCHAR counts bytes, not characters

`VARCHAR(20)` means **20 bytes**. A multi-byte character can consume up to four.

```sql
SELECT length('محمد')        AS chars,   -- 4
       octet_length('محمد')  AS bytes;   -- 8
```

**This matters directly on this data.** Arabic product and store names, and any emoji in a customer field, will overflow columns sized by counting letters. `COPY` then fails on a value one byte too long, and the error names the row rather than the cause.

## 3 · DECIMAL for money — never FLOAT

`FLOAT4` / `FLOAT8` are **approximate**. Sum a million of them and the total will not reconcile, and nobody will be able to explain the pennies.

```sql
SELECT SUM(v) FROM (SELECT 0.1::FLOAT8 AS v FROM stl_scan LIMIT 10) t;
-- 0.9999999999999999

SELECT SUM(v) FROM (SELECT 0.1::DECIMAL(10,2) AS v FROM stl_scan LIMIT 10) t;
-- 1.00
```

**Rule:** anything that is money, quantity or a measure people reconcile → `DECIMAL(p,s)`. `FLOAT` is for scientific measures and ratios you never sum.

Watch the scale in arithmetic too — `DECIMAL(14,2) / DECIMAL(14,2)` does not give you two decimal places by default. Cast explicitly when it matters.

## 4 · TIMESTAMP vs TIMESTAMPTZ

`TIMESTAMP` carries **no time zone**. `TIMESTAMPTZ` does.

Mixing them across a warehouse produces off-by-one-day bugs that survive for years, because they only show up at the boundaries of a reporting period.

**Pick one convention, write it down, and apply it everywhere.** The usual choice: store `TIMESTAMP` in UTC, convert at the reporting layer only.

```sql
SELECT CONVERT_TIMEZONE('Asia/Riyadh', event_ts_utc) AS local_ts
FROM   gold.fct_sales_line;
```

## The types you will actually use

| Type | Use for |
|---|---|
| `SMALLINT` / `INTEGER` / `BIGINT` | keys, counts |
| `DECIMAL(p,s)` | **money, quantities, anything summed** |
| `DOUBLE PRECISION` | ratios, scientific values |
| `VARCHAR(n)` | text — sized to the data, in bytes |
| `CHAR(n)` | fixed-width codes only; pads with spaces |
| `DATE` | calendar dates |
| `TIMESTAMP` | UTC instants (the house convention) |
| `BOOLEAN` | flags |
| `SUPER` | landed JSON only (L10) |

## Try it

```sql
-- audit every VARCHAR in a schema against its real content width
SELECT schemaname, tablename, "column", type
FROM   pg_table_def
WHERE  schemaname = 'gold'
  AND  type LIKE 'character varying%'
ORDER  BY 1, 2, 3;

-- and for a specific table, what widths are actually used
SELECT MAX(octet_length(receipt_no)) AS receipt_no_bytes,
       MAX(octet_length(merge_key))  AS merge_key_bytes
FROM   gold.fct_sales_line;
```

## Gotchas

- **`COPY` fails on one over-long value**, and reports the row, not the fix. L22 covers the diagnosis.
- **Widening a column later means a rebuild** on large tables — size it right the first time.
- **`CHAR` pads with spaces** and will surprise you in comparisons and joins. Use `VARCHAR`.
- **Implicit casts in a join** (`VARCHAR` to `INT`) prevent Redshift from using the distribution properly. Match your key types.

## Checklist

- [ ] No `VARCHAR(65535)` anywhere I control
- [ ] Column widths measured from `octet_length`, not guessed
- [ ] All money and quantities are `DECIMAL`, never `FLOAT`
- [ ] One timestamp convention, written down
- [ ] Join keys have matching types on both sides
- [ ] I have checked Arabic text fits the columns sized for it

## You've got it when you can…

…be handed a `CREATE TABLE` full of `VARCHAR(65535)` and `FLOAT` and explain, with a specific consequence for each, why it needs changing before anything is loaded.
