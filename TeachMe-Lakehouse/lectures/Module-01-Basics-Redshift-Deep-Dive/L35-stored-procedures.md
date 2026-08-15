# L35 · Stored Procedures

> **Module 01 · Lesson 35** · ~45 min · **Part F begins**

**Slide:** [`_render/L35-stored-procedures.html`](_render/L35-stored-procedures.html)

## What it is

PL/pgSQL running **inside** the warehouse. The right home for a multi-statement load that must succeed or fail as one thing.

No round trips. No rows crossing the network. One transaction around the whole load.

## The shape

```sql
CREATE OR REPLACE PROCEDURE etl.load_sales_day(
    p_batch_date   DATE,
    INOUT p_rows_loaded INTEGER DEFAULT 0
)
AS $$
DECLARE
    v_staged INTEGER;
BEGIN
    RAISE INFO 'load_sales_day starting for %', p_batch_date;

    -- 1. how much arrived?
    SELECT COUNT(*) INTO v_staged
    FROM   staging.sales_line
    WHERE  sale_date = p_batch_date;

    IF v_staged = 0 THEN
        RAISE INFO 'nothing staged for %, exiting clean', p_batch_date;
        p_rows_loaded := 0;
        RETURN;
    END IF;

    -- 2. clear the target slice (idempotent rerun)
    DELETE FROM gold.fct_sales_line WHERE sale_date = p_batch_date;

    -- 3. load it
    INSERT INTO gold.fct_sales_line (sale_date, store_sk, product_sk, qty, net_amount)
    SELECT s.sale_date, d.store_sk, p.product_sk, s.qty, s.net_amount
    FROM   staging.v_sales_line_latest s
    JOIN   gold.dim_store   d ON d.store_id = s.store_id AND d.is_current
    JOIN   gold.dim_product p ON p.product_id = s.product_id AND p.is_current
    WHERE  s.sale_date = p_batch_date;

    GET DIAGNOSTICS p_rows_loaded = ROW_COUNT;

    RAISE INFO 'loaded % rows for %', p_rows_loaded, p_batch_date;
END;
$$ LANGUAGE plpgsql;
```

Call it:

```sql
CALL etl.load_sales_day('2026-08-10', 0);
```

**`CALL`, never `SELECT`.** A procedure is not a function.

## Four things that surprise application developers

### 1 · It does not return rows

There is no `RETURN <result set>`. Two options:

**`INOUT` parameters** for scalars — the value comes back in the `CALL` result:

```sql
CALL etl.load_sales_day('2026-08-10', 0);
--  p_rows_loaded
--  -------------
--          48213
```

**A refcursor** for a result set:

```sql
CREATE OR REPLACE PROCEDURE etl.get_daily(p_date DATE, INOUT ref refcursor)
AS $$
BEGIN
    OPEN ref FOR SELECT store_sk, SUM(net_amount)
                 FROM gold.fct_sales_line WHERE sale_date = p_date GROUP BY 1;
END;
$$ LANGUAGE plpgsql;

BEGIN;
CALL etl.get_daily('2026-08-10', 'mycursor');
FETCH ALL FROM mycursor;
COMMIT;
```

Note the `BEGIN … COMMIT` — the cursor only lives inside the transaction. This is clumsy from an application; in practice, have Node call a procedure to *do work* and then run a plain `SELECT` to *read results*.

### 2 · It is one transaction by default

Every statement commits together or none do. That is usually exactly what you want: a load that fails halfway leaves the warehouse as it was.

Declare **`NONATOMIC`** only when you deliberately want each statement to commit independently — a long backfill that should keep its progress, for example:

```sql
CREATE OR REPLACE PROCEDURE etl.backfill(p_from DATE, p_to DATE)
NONATOMIC
AS $$
DECLARE d DATE := p_from;
BEGIN
    WHILE d <= p_to LOOP
        CALL etl.load_sales_day(d, 0);
        COMMIT;                       -- allowed in NONATOMIC
        d := DATEADD('day', 1, d);
    END LOOP;
END;
$$ LANGUAGE plpgsql;
```

`COMMIT` and `ROLLBACK` inside the body are only meaningful in `NONATOMIC` mode, and only when the procedure was not itself called from inside an open transaction.

### 3 · SECURITY DEFINER

By default a procedure runs with the **caller's** privileges (`SECURITY INVOKER`). `SECURITY DEFINER` runs it as the **owner** instead:

```sql
CREATE OR REPLACE PROCEDURE etl.load_sales_day(...)
SECURITY DEFINER
AS $$ ... $$ LANGUAGE plpgsql;

GRANT EXECUTE ON PROCEDURE etl.load_sales_day(DATE, INTEGER) TO ROLE etl_operator;
```

Now `etl_operator` can run the load without holding `INSERT` on `gold`. **Grant `EXECUTE` on the procedure instead of write rights on the tables** — this is the cleanest privilege pattern in the warehouse (L13).

⚠️ With `SECURITY DEFINER`, always schema-qualify every table name and set an explicit `search_path`. An unqualified name resolved against the caller's `search_path` is how privilege escalation happens.

### 4 · No version control for free

A procedure edited in a console is invisible to git. **Every procedure lives in a `.sql` file in the repo, deployed by CI, or it does not exist.**

```
db/
  procedures/
    etl.load_sales_day.sql
    etl.load_dim_store.sql
    etl.run_nightly.sql
  deploy.sh              # psql -f each file, in order
```

Always `CREATE OR REPLACE` so redeployment is idempotent.

## An orchestrator procedure

The pattern that ties a nightly load together:

```sql
CREATE OR REPLACE PROCEDURE etl.run_nightly(p_batch_date DATE)
AS $$
DECLARE
    v_run_id  BIGINT;
    v_rows    INTEGER;
BEGIN
    v_run_id := (SELECT COALESCE(MAX(run_id), 0) + 1 FROM etl.run_log);

    INSERT INTO etl.run_log (run_id, batch_date, status, started_at_utc)
    VALUES (v_run_id, p_batch_date, 'RUNNING', GETDATE());

    CALL etl.load_dim_store(p_batch_date);
    CALL etl.load_dim_product(p_batch_date);
    CALL etl.load_sales_day(p_batch_date, v_rows);

    -- data quality gate: refuse to publish a bad load
    IF v_rows = 0 THEN
        RAISE EXCEPTION 'no rows loaded for %', p_batch_date;
    END IF;

    REFRESH MATERIALIZED VIEW gold.mv_sales_daily;

    UPDATE etl.run_log
    SET    status = 'SUCCESS', rows_loaded = v_rows, ended_at_utc = GETDATE()
    WHERE  run_id = v_run_id;
END;
$$ LANGUAGE plpgsql;
```

Note the **quality gate**. A procedure that publishes whatever it is given is a procedure that will publish a zero one morning.

## Finding what exists

```sql
-- list procedures in a schema
SELECT n.nspname AS schema, p.proname AS name
FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'etl' AND p.prokind = 'p'
ORDER  BY 2;

-- read the source of one
SHOW PROCEDURE etl.load_sales_day(DATE, INTEGER);
```

## Gotchas

- **Quote the body with `$$`.** Otherwise every apostrophe inside must be doubled, and the first time you write `'store's'` you will lose twenty minutes.
- **Changing an argument type creates a second overload**, it does not replace the first. `DROP PROCEDURE` the old signature explicitly, or you will have two and callers will get whichever matches.
- **`RAISE INFO` output goes to the client.** Through the Data API you may not see it — write to an audit table as well.
- **Max source size is 2 MB**; nesting depth is 16 levels. If you are near either, the design is wrong.
- **`SET` inside a procedure is scoped to the procedure** and reverts on exit.
- **A procedure cannot be called from inside a `SELECT`.** No `SELECT etl.load_sales_day(...)`.
- **`GET DIAGNOSTICS … = ROW_COUNT`** must come immediately after the DML statement it describes.

## Try it

1. Write `etl.load_sales_day` against your own tables and call it twice for the same date. The row count must be identical both times — that is idempotency (L24).
2. Add the `IF v_staged = 0 THEN RETURN` guard and call it for a date with no data. It should exit clean, not error.
3. Make it `SECURITY DEFINER`, grant `EXECUTE` to a role that has no rights on `gold`, and prove that role can run the load but not `INSERT` directly.
4. Deliberately break the `INSERT` (rename a column) and confirm the `DELETE` rolled back too.

That fourth step is the one that makes atomicity real.

## Checklist

- [ ] Multi-statement loads live in procedures, not in Node
- [ ] `CALL`, never `SELECT`
- [ ] `CREATE OR REPLACE` always, and the source is in git
- [ ] `INOUT` for the row count, so the caller can log it
- [ ] `SECURITY DEFINER` plus `GRANT EXECUTE`, with schema-qualified names
- [ ] Every procedure is idempotent for the same batch date
- [ ] A quality gate before anything is published
- [ ] `NONATOMIC` used only deliberately, for backfills

## You've got it when you can…

…take a Node script that runs eight statements in sequence with `await` between each, move it into one procedure, and explain to the team why the failure behaviour is now correct rather than merely tidier.
