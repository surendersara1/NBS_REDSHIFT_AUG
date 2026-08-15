# L37 · User-Defined Functions

> **Module 01 · Lesson 37** · ~35 min

**Slide:** [`_render/L37-udfs.html`](_render/L37-udfs.html)

## What it is

A **function returns a value and can appear in a `SELECT`**. A procedure cannot. That single difference decides which one you write.

```sql
SELECT f_net_of_vat(gross_amount) FROM ...   -- function ✅
CALL   etl.load_sales_day('2026-08-10', 0);  -- procedure ✅
SELECT etl.load_sales_day(...)               -- ❌ not a thing
```

A UDF takes scalars and returns one scalar. **It cannot read a table and it cannot write anything** — that is exactly what makes it safe to call a billion times.

## 1 · SQL UDFs — always the first choice

A single `SELECT` expression. The planner folds it into the query, so it costs the same as writing the expression by hand.

```sql
CREATE OR REPLACE FUNCTION f_net_of_vat(gross DECIMAL(18,4))
RETURNS DECIMAL(18,4)
IMMUTABLE
AS $$
  SELECT $1 / 1.15
$$ LANGUAGE sql;
```

⚠️ **Arguments are `$1`, `$2` — positional, not by name.** The name in the signature is documentation only. This trips up everyone once.

More useful examples:

```sql
-- one agreed definition of the fiscal year
CREATE OR REPLACE FUNCTION f_fiscal_year(d DATE)
RETURNS SMALLINT IMMUTABLE
AS $$ SELECT CASE WHEN EXTRACT(month FROM $1) >= 4
                  THEN EXTRACT(year FROM $1) ELSE EXTRACT(year FROM $1) - 1 END $$
LANGUAGE sql;

-- safe division, used everywhere
CREATE OR REPLACE FUNCTION f_safe_div(n DECIMAL(18,4), d DECIMAL(18,4))
RETURNS DECIMAL(18,6) IMMUTABLE
AS $$ SELECT $1 / NULLIF($2, 0) $$ LANGUAGE sql;

-- the SCD2 hash, defined once so every dimension load agrees
CREATE OR REPLACE FUNCTION f_row_hash(a VARCHAR, b VARCHAR, c VARCHAR)
RETURNS VARCHAR(32) IMMUTABLE
AS $$ SELECT MD5(COALESCE($1,'') || '|' || COALESCE($2,'') || '|' || COALESCE($3,'')) $$
LANGUAGE sql;
```

That last one is the real argument for UDFs: **four dimension loads that each write their own hash expression will eventually disagree.** One function means they cannot.

## 2 · Python UDFs — do not use

> **Confirmed against AWS documentation.** Amazon Redshift stopped supporting the *creation* of new scalar Python UDFs after **patch 198 (30 October 2025)**, and existing Python UDFs reached **end of support on 30 June 2026** — a date that has now passed. AWS directs users to **Lambda UDFs** as the replacement.

They are covered here only so you recognise one if you inherit it:

```sql
-- legacy — you may find this in an old codebase. Migrate it.
CREATE OR REPLACE FUNCTION f_parse_sku(sku VARCHAR)
RETURNS VARCHAR STABLE
AS $$
  import re
  m = re.match(r'^([A-Z]{3})-(\d+)$', sku)
  return m.group(1) if m else None
$$ LANGUAGE plpythonu;
```

Two migration routes, in order of preference:

1. **Rewrite it in SQL.** Most Python UDFs in the wild are string manipulation that `SPLIT_PART`, `REGEXP_SUBSTR`, `TRANSLATE` and `POSITION` handle natively — and the SQL version is faster.
2. **Move it to a Lambda UDF** (L38) when the logic genuinely needs a library.

Find them before they bite:

```sql
SELECT n.nspname AS schema, p.proname AS name, l.lanname AS language
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
JOIN   pg_language  l ON l.oid = p.prolang
WHERE  l.lanname LIKE 'plpython%'
ORDER  BY 1, 2;
```

Run that on any inherited cluster on day one.

## 3 · Lambda UDFs — the escape hatch

Any language, any library, any external call. Covered fully in **L38**. The short version: right for a lookup no SQL can do, wrong for anything you could have precomputed into a column at load time.

## 4 · Volatility — STABLE, IMMUTABLE, VOLATILE

This tells the planner what it is allowed to skip:

| Category | Meaning | Planner may |
|---|---|---|
| `IMMUTABLE` | Same inputs always give the same result, forever | Evaluate once and reuse; fold constants |
| `STABLE` | Same result within a single statement | Reuse within the statement |
| `VOLATILE` | May differ every call (default) | Nothing — call it per row |

**Mark pure functions `IMMUTABLE`.** It is free performance. But get it wrong — mark something `IMMUTABLE` that reads changing state — and you cache a wrong answer with no error to tell you.

`VOLATILE` is the default, so an unmarked function is the slow case.

## Naming and permissions

```sql
-- convention: f_ prefix, so a UDF is visibly not a built-in
CREATE OR REPLACE FUNCTION f_net_of_vat(...) ...

-- functions are schema-scoped like everything else
GRANT EXECUTE ON FUNCTION f_net_of_vat(DECIMAL) TO ROLE analyst;
```

The `f_` prefix is an AWS convention and worth keeping — it means nobody has to wonder whether `net_of_vat` is something Redshift ships or something your team wrote. It also protects you if AWS later adds a built-in with the same name.

## Gotchas

- **Arguments are `$1`, `$2`, not names.**
- **A UDF cannot query a table.** Lookups belong in a join, not in a function. This is the single most common request and the answer is always "join to a dimension".
- **`NULL` in usually means `NULL` out.** Handle it explicitly with `COALESCE` or `NULLIF`.
- **Changing the argument types creates an overload**, not a replacement. `DROP FUNCTION` the old signature.
- **`VOLATILE` is the default** — mark pure functions `IMMUTABLE`.
- **A wrong `IMMUTABLE` gives silently wrong answers.**
- **UDFs are not in git unless you put them there.** Same rule as procedures (L35).
- **No aggregate UDFs.** You cannot write your own `SUM`-like function.

## Try it

1. Write `f_safe_div` and `f_row_hash`, and replace the hand-written hash in your `dim_store` load with the function. Confirm the load still produces zero changes on a rerun.
2. Create the same function twice with different argument types and watch both exist. Then drop one properly.
3. Run the `plpython%` audit query against every cluster you have access to.
4. Take any Python UDF you find and rewrite it in SQL. Time both if the Python one still runs.

## Checklist

- [ ] SQL UDF if it fits in one `SELECT` expression
- [ ] No new Python UDFs — the runtime is out of support
- [ ] I have audited for existing Python UDFs
- [ ] Pure functions marked `IMMUTABLE`
- [ ] `f_` prefix on everything
- [ ] `NULL` handled explicitly
- [ ] Shared definitions (VAT, fiscal year, row hash) live in exactly one function
- [ ] Function source is in git and deployed by CI

## You've got it when you can…

…find three reports that each compute "net of VAT" slightly differently, replace all three with one `IMMUTABLE` SQL UDF, and show that the numbers now agree.
