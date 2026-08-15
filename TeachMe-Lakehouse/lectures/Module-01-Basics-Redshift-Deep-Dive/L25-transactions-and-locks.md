# L25 · Transactions, Locks and Isolation

> **Module 01 · Lesson 25** · ~40 min

**Slide:** [`_render/L25-transactions-and-locks.html`](_render/L25-transactions-and-locks.html)

## The error you will meet

```
ERROR: 1023
DETAIL: Serializable isolation violation on table - 123456,
        transactions forming the cycle are: 987, 988
```

**It is not a bug and it is not random.** Two transactions touched the same table in an order that cannot be made to look sequential, so Redshift aborted one rather than produce a result neither of you intended.

The fix is almost never in the SQL. It is in the schedule.

## Four things to know

### 1 · Every statement is already a transaction

Autocommit is on. Without `BEGIN`, each statement commits on its own — so a three-statement load that fails on statement two leaves statement one applied.

```sql
BEGIN;
  DELETE FROM gold.fct_sales_line WHERE sale_date = '2026-08-12';
  INSERT INTO gold.fct_sales_line SELECT * FROM staging.sales_dedup;
COMMIT;
```

### 2 · Serializable, not read committed

Redshift's default isolation is **stricter than Postgres'**. Two jobs writing the same table concurrently will collide — reliably, not occasionally.

### 3 · DDL takes an exclusive lock

A long-running `SELECT` blocks an `ALTER` or `DROP` behind it, and everything queued after that blocks too. **One analyst's report can stall a deployment**, and the deployment looks hung rather than blocked.

### 4 · The fix is one writer per table

Serialise the writes yourself. One job owns one table. Then retry on 1023 with a short backoff — because a legitimate collision can still happen at a boundary.

## Diagnosing a block

```sql
-- who holds a lock right now?
SELECT l.table_id, t.relname AS table_name,
       l.lock_owner_pid, l.lock_mode, l.granted
FROM   stv_locks l
JOIN   pg_class t ON t.oid = l.table_id;

-- what is that session doing?
SELECT pid, user_name, starttime, DATEDIFF(second, starttime, GETDATE()) AS secs,
       TRIM(query) AS query
FROM   stv_recents
WHERE  status = 'Running'
ORDER  BY starttime;

-- open transactions holding things up
SELECT * FROM svv_transactions ORDER BY txn_start;

-- last resort
SELECT pg_terminate_backend(<pid>);
```

`svv_transactions` is the one to check when a deploy appears to hang — look for a transaction that started twenty minutes ago and never committed.

## Retrying 1023 from Node

```js
async function withRetry(fn, attempts = 5) {
  for (let i = 0; i < attempts; i++) {
    try {
      return await fn();
    } catch (e) {
      const serializable =
        /serializable isolation/i.test(e.message ?? "") ||
        /\b1023\b/.test(e.message ?? "");
      if (!serializable || i === attempts - 1) throw e;
      await new Promise(r => setTimeout(r, 200 * 2 ** i));  // backoff
    }
  }
}
```

Retry is a safety net for boundary cases. **It is not a substitute for having one writer** — if you are retrying constantly, two jobs are fighting and you should fix the schedule.

## Gotchas

- **`TRUNCATE` commits immediately** and cannot be rolled back, even inside `BEGIN`. This is the one that surprises Postgres developers.
- **An idle-in-transaction session holds its locks.** A developer who ran `BEGIN` in a client and went to lunch will block your deployment.
- **`VACUUM` cannot run inside a transaction block.**
- **Commit or roll back explicitly** in any code that opens a transaction — a leaked transaction is a leaked lock.
- **Long `SELECT`s block DDL**, so run migrations in a quiet window or expect to wait.

## Checklist

- [ ] Multi-statement loads are wrapped in `BEGIN … COMMIT`
- [ ] Exactly one job writes each table
- [ ] 1023 is retried with backoff, and treated as a signal not a nuisance
- [ ] I know `TRUNCATE` cannot be rolled back
- [ ] I can find a blocking session in one query
- [ ] Nothing in my code can leave a transaction open

## You've got it when you can…

…be told "the deployment is stuck" and find the twenty-minute-old open transaction holding the lock — then say whose session it is before terminating anything.
