# L10 · SUPER and Semi-Structured Data

> **Module 01 · Lesson 10** · ~40 min · **for people arriving from Mongo**

**Slide:** [`_render/L10-super-and-json.html`](_render/L10-super-and-json.html)

## What it is

`SUPER` is Redshift's schemaless column type, queried with **PartiQL** — dot and bracket navigation that will feel immediately familiar from JavaScript.

It is excellent for landing an API payload whole. It is a poor permanent home for any column people filter, join or report on.

## Navigation is JavaScript-like

```sql
SELECT payload.order_id,
       payload.customer.email,
       payload.items[0].sku
FROM   bronze.orders;
```

A missing path returns `NULL` rather than raising an error — convenient, and a good reason to validate rather than assume.

## Unnesting arrays

An array becomes rows by putting it in the `FROM` clause. This is how one order document becomes one row per line:

```sql
SELECT o.payload.order_id::BIGINT        AS order_id,
       o.payload.customer.email::VARCHAR AS email,
       i.sku::VARCHAR                    AS sku,
       i.qty::INT                        AS qty,
       i.price::DECIMAL(12,2)            AS price
FROM   bronze.orders o,
       o.payload.items i;
```

Note the comma join to `o.payload.items` — that is the unnest. Nested arrays chain the same way.

## Always cast on the way out

```sql
-- wrong: comparing SUPER to a number uses PartiQL's rules, not yours
SELECT * FROM bronze.orders WHERE payload.total > 100;

-- right
SELECT * FROM bronze.orders WHERE payload.total::DECIMAL(12,2) > 100;
```

Uncast `SUPER` values compare by PartiQL semantics, which order types before values. The result is not wrong so much as *not what you meant*.

## Loading JSON

```sql
-- from JSON files on S3
COPY bronze.orders (payload)
FROM 's3://bucket/orders/dt=2026-08-12/'
IAM_ROLE 'arn:aws:iam::...:role/redshift-loader'
FORMAT AS JSON 'auto'
SERIALIZETOJSON;

-- or build SUPER in SQL
SELECT JSON_PARSE('{"a":1,"b":[1,2,3]}') AS doc;
```

## The cost: it is not columnar

A `SUPER` column is stored **whole**. Filtering on a field inside it reads the entire document — no zone maps, no block skipping, none of the machinery that makes Redshift fast (L14, L16).

That is fine for a landing table nobody reports off. It is not fine for `fct_sales_line`.

## The pattern: shred what you query

```
bronze.orders     payload SUPER          -- land the document whole
      ↓
silver.order_line  order_id BIGINT        -- typed, real columns
                   sku      VARCHAR(40)
                   qty      INT
                   price    DECIMAL(12,2)
```

```sql
INSERT INTO silver.order_line
SELECT o.payload.order_id::BIGINT,
       i.sku::VARCHAR(40),
       i.qty::INT,
       i.price::DECIMAL(12,2)
FROM   bronze.orders o, o.payload.items i;
```

**A gold table should contain no `SUPER` at all.**

## Try it

```sql
-- what shape is the document, really?
SELECT DISTINCT JSON_TYPEOF(payload.items) FROM bronze.orders LIMIT 10;

-- how often is a field missing?
SELECT COUNT(*)                                        AS rows,
       COUNT(payload.customer.email)                   AS with_email,
       COUNT(*) - COUNT(payload.customer.email)        AS missing
FROM   bronze.orders;
```

That second query is the one to run before you promise anyone a column exists.

## Gotchas

- **Cast on the way out, always.**
- **No zone maps on SUPER** — a filter on a nested field scans everything.
- **A schema change upstream is silent.** A renamed field becomes `NULL`, not an error. Add a test that counts non-null on fields you depend on.
- **`SUPER` has a size limit per value** — very large documents will be rejected on load.

## Checklist

- [ ] I can navigate and unnest a document from memory
- [ ] I cast every value on the way out
- [ ] I know `SUPER` has no zone maps and why that matters
- [ ] Landed documents live in bronze; typed columns live in silver
- [ ] No gold table contains `SUPER`
- [ ] I have a test that catches an upstream field disappearing

## You've got it when you can…

…take an unfamiliar API payload, land it as `SUPER`, and produce a typed silver table from it in one statement — then explain why leaving it as `SUPER` would have been slower and more fragile.
