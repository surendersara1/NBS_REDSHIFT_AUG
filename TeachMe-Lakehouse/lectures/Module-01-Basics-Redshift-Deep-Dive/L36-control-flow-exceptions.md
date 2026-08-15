# L36 · Control Flow, Cursors and Exceptions

> **Module 01 · Lesson 36** · ~35 min

**Slide:** [`_render/L36-control-flow-exceptions.html`](_render/L36-control-flow-exceptions.html)

## What it is

Everything PL/pgSQL gives you for branching and error handling — and the one loop you must train yourself not to write.

**The rule: branch for the pipeline, never for the rows.** Use `IF` and loops to decide *what step runs next*. The moment a loop iterates over data rows, you have turned a columnar engine back into a row engine.

## Declarations and assignment

```sql
DECLARE
    v_count   INTEGER := 0;              -- := for assignment, not =
    v_date    DATE    := CURRENT_DATE;
    v_name    VARCHAR(120);
    v_rec     RECORD;                    -- holds one row of anything
BEGIN
    -- assign from a query with INTO
    SELECT COUNT(*) INTO v_count FROM staging.sales_line;

    -- or plain assignment from an expression
    v_date := DATEADD('day', -1, v_date);
END;
```

`INTO` takes the **first row** and does not error if there are none — `v_count` simply stays as it was. Guard anything that must find a row:

```sql
SELECT store_name INTO v_name FROM gold.dim_store WHERE store_id = p_id AND is_current;
IF v_name IS NULL THEN
    RAISE EXCEPTION 'no current store for id %', p_id;
END IF;
```

## Branching

```sql
IF v_staged = 0 THEN
    RAISE INFO 'nothing to do';
    RETURN;
ELSIF v_staged > 10000000 THEN
    RAISE EXCEPTION 'batch of % rows looks wrong, refusing', v_staged;
ELSE
    CALL etl.load_sales_day(p_batch_date, v_rows);
END IF;
```

That `ELSIF` is a **sanity gate**. A batch ten times normal size is nearly always a source-system bug, and catching it before it lands is much cheaper than unwinding it afterwards.

## Loops — the legitimate uses

```sql
-- 1. a fixed list of things to process
FOR i IN 1..12 LOOP
    CALL etl.load_month(p_year, i);
END LOOP;

-- 2. a driver table of source systems (a handful of rows, not millions)
FOR v_rec IN SELECT schema_name, table_name FROM etl.source_registry WHERE enabled LOOP
    RAISE INFO 'refreshing %.%', v_rec.schema_name, v_rec.table_name;
    EXECUTE 'ANALYZE ' || quote_ident(v_rec.schema_name) || '.' || quote_ident(v_rec.table_name);
END LOOP;

-- 3. a bounded retry
v_attempt := 0;
LOOP
    v_attempt := v_attempt + 1;
    BEGIN
        CALL etl.load_sales_day(p_batch_date, v_rows);
        EXIT;                                    -- success, leave the loop
    EXCEPTION WHEN OTHERS THEN
        IF v_attempt >= 3 THEN RAISE; END IF;    -- give up honestly
        RAISE INFO 'attempt % failed: %', v_attempt, SQLERRM;
    END;
END LOOP;

-- 4. a WHILE over dates in a NONATOMIC backfill
WHILE v_date <= p_to LOOP
    CALL etl.load_sales_day(v_date, v_rows);
    COMMIT;
    v_date := DATEADD('day', 1, v_date);
END LOOP;
```

All four loop over **units of work**, never over data rows. That is the distinction.

## Dynamic SQL

```sql
EXECUTE 'DELETE FROM ' || quote_ident(v_schema) || '.' || quote_ident(v_table)
        || ' WHERE sale_date = $1'
  USING p_batch_date;
```

⚠️ **`quote_ident` for identifiers, `USING` for values.** String-concatenating a value into dynamic SQL is a SQL injection, even inside the warehouse — a source-registry table someone can edit is an input.

## RAISE — your only printf

```sql
RAISE INFO   'loaded % rows for %', v_rows, p_batch_date;   -- to the client
RAISE NOTICE 'stats look stale on %', v_table;
RAISE WARNING 'quality check soft-failed';
RAISE EXCEPTION 'no rows loaded for %', p_batch_date;       -- aborts
```

`%` is the placeholder — positional, no numbering. **There is no debugger here**, so log deliberately: entry, key counts, exit, and every branch you took.

## Exception handling

```sql
BEGIN
    ... work ...
EXCEPTION WHEN OTHERS THEN
    INSERT INTO etl.run_log (run_id, status, error_text, ended_at_utc)
    VALUES (v_run_id, 'FAILED', SQLERRM, GETDATE());
    RAISE;                       -- hand the error back up
END;
```

**`OTHERS` is the only condition Redshift supports.** You cannot catch a specific SQL state the way you can in PostgreSQL — so you cannot retry-on-deadlock but fail-on-syntax-error. Inspect `SQLERRM` (the message text) if you need to distinguish.

**Always re-`RAISE`.** A swallowed exception turns a failed load into a silent one, and a silent failure is discovered by a business user three days later.

### ⚠️ The trap: your log row rolls back too

In an **atomic** procedure — the default — the `EXCEPTION` block runs inside the same transaction that is about to roll back. Your carefully written `run_log` row disappears along with everything else.

Three ways out, in order of preference:

**1 · Log from the caller.** Node catches the error and writes the audit row on its own connection. Cleanest, and the caller knows things the procedure does not (job id, trigger, retry count).

```js
try {
  await call('CALL etl.run_nightly($1)', [batchDate]);
  await log('SUCCESS', null);
} catch (err) {
  await log('FAILED', err.message);      // separate transaction — this survives
  throw err;
}
```

**2 · `NONATOMIC` with an explicit `COMMIT`** after the log insert, when you genuinely want per-statement commits anyway.

**3 · Let it fail loudly** and read the error from `stl_load_errors` / `sys_query_history` / CloudWatch. Fine for a small team, weak for an audited pipeline.

## Cursors — almost never

```sql
-- ❌ this is the anti-pattern
DECLARE c CURSOR FOR SELECT * FROM gold.fct_sales_line;
LOOP
    FETCH c INTO v_rec;
    EXIT WHEN NOT FOUND;
    UPDATE gold.fct_sales_line SET flag = TRUE WHERE id = v_rec.id;
END LOOP;
```

A cursor over a million rows will run for **hours** where one `MERGE` takes seconds. Every `UPDATE` is a delete-plus-insert (L23), and you have just done a million of them one at a time.

```sql
-- ✅ what it should have been
UPDATE gold.fct_sales_line SET flag = TRUE WHERE <the same condition>;
```

**The legitimate use is returning a result set from a procedure** (L35), and nothing else. If you find yourself writing `FETCH` inside a loop, stop and ask what set-based statement you are avoiding.

Cursor limits are also real: cursor result sets are constrained by cluster size, and a large one will fail rather than degrade.

## Gotchas

- **`:=` assigns, `=` compares.** A common first-day error.
- **`SELECT … INTO` with no rows leaves the variable unchanged**, it does not raise. Check explicitly.
- **`OTHERS` is the only catchable condition.**
- **The exception block rolls back with the transaction** in atomic mode — log from outside.
- **Never swallow an exception without re-raising.**
- **`RAISE INFO` may not reach you through the Data API.** Persist what matters.
- **`EXECUTE` with concatenated values is injectable.** `USING` and `quote_ident`.
- **`EXIT` leaves the innermost loop only**; label loops if you need to break further.

## Try it

1. Add the >10× sanity gate to your load and prove it refuses an oversized batch.
2. Wrap a load in a three-attempt retry and make it fail twice by locking the target table from another session (L25).
3. Write the exception handler with the `run_log` insert, run a failing load, and confirm **no log row exists**. Then move the logging to the caller and confirm it does. This is the lesson that sticks.
4. Time a cursor loop that updates 100,000 rows, then time the equivalent single `UPDATE`. Write both numbers on the board.

## Checklist

- [ ] Loops iterate over units of work, never data rows
- [ ] A sanity gate on batch size before every load
- [ ] `RAISE INFO` at entry, at each branch, and at exit
- [ ] `EXCEPTION WHEN OTHERS` records `SQLERRM` and re-`RAISE`s
- [ ] Failure logging happens outside the failing transaction
- [ ] Dynamic SQL uses `quote_ident` and `USING`
- [ ] No cursor anywhere except to return a result set
- [ ] Retries are bounded and give up honestly

## You've got it when you can…

…look at a procedure with a cursor loop, name the set-based statement it should have been, and quote the ratio between the two runtimes from having measured it yourself.
