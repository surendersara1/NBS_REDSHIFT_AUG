# L39 · Calling Redshift From Node.js ⭐

> **Module 01 · Lesson 39** · ~60 min · **the lesson this module was built for**

**Slide:** [`_render/L39-nodejs-integration.html`](_render/L39-nodejs-integration.html)

## What it is

Two clients, two completely different mental models. **Choosing the wrong one is the most expensive mistake in this module.**

| | Redshift Data API | node-postgres (`pg`) |
|---|---|---|
| Transport | HTTPS, AWS SDK | PostgreSQL wire protocol, TCP 5439 |
| Auth | IAM | Username/password or IAM temp credentials |
| Network | Public AWS endpoint — no VPC needed | Must reach the cluster: VPC, SG, or public endpoint |
| Connections | None to manage | A pool you own and must size |
| Model | Submit → poll → fetch | `await` returns rows |
| Result limit | Paginated, size-capped | Streams, unbounded |
| Session state | None, unless you ask for it | Full session |
| Best for | **Lambda, Step Functions, ETL jobs, anything serverless** | **A long-lived API service doing interactive reads** |

**Default to the Data API.** Reach for `pg` when you have a persistent service and genuinely need session state, streaming, or sub-100 ms latency.

## The four habits to unlearn

### 1 · No row-at-a-time inserts

```js
// ❌❌❌ this will destroy a Redshift cluster
for (const row of rows) {
  await client.query('INSERT INTO gold.fct_sales_line VALUES ($1,$2,$3)', row);
}
```

Every `INSERT` writes new 1 MB column blocks (L23). Ten thousand single-row inserts produce ten thousand near-empty blocks, the table balloons, every subsequent scan reads the bloat, and `VACUUM` has to clean it up. This is not "slow" — it is *destructive*, and the damage outlives the job.

```js
// ✅ batch to S3, then COPY
import { PutObjectCommand } from '@aws-sdk/client-s3';

const body = rows.map(r => JSON.stringify(r)).join('\n');
await s3.send(new PutObjectCommand({
  Bucket: 'tamimi-staging', Key: `sales/${batchDate}/part-0001.json`, Body: body,
}));

await execute(`
  COPY staging.sales_line
  FROM 's3://tamimi-staging/sales/${batchDate}/'
  IAM_ROLE '${ROLE}'
  FORMAT AS JSON 'auto'
  TIMEFORMAT 'auto'
`);
```

**Write the file, then `COPY`.** Every time. There is no batch size at which the loop becomes acceptable.

If you truly have a handful of rows and no S3 path, a **multi-row `INSERT`** is the least-bad option — one statement, many `VALUES` tuples:

```js
// acceptable for tens of rows, never for thousands
const values = rows.map((_, i) => `($${i*3+1}, $${i*3+2}, $${i*3+3})`).join(',');
await client.query(`INSERT INTO etl.run_log VALUES ${values}`, rows.flat());
```

### 2 · Submit, poll, fetch

The Data API is **not** await-a-result. `ExecuteStatement` returns an `Id` immediately.

```js
// db/dataApi.mjs
import {
  RedshiftDataClient, ExecuteStatementCommand,
  DescribeStatementCommand, GetStatementResultCommand,
} from '@aws-sdk/client-redshift-data';

const rs = new RedshiftDataClient({ region: 'me-central-1' });

const BASE = {
  WorkgroupName: 'tamimi-wg',       // or ClusterIdentifier + DbUser for provisioned
  Database: 'tamimi',
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Submit SQL and wait for it to finish. Returns the statement id. */
export async function execute(sql, parameters = []) {
  const { Id } = await rs.send(new ExecuteStatementCommand({
    ...BASE,
    Sql: sql,
    Parameters: parameters.length ? parameters : undefined,
    StatementName: sql.slice(0, 60),   // shows up in the console — worth setting
  }));

  // poll with backoff: cheap queries finish fast, loads do not
  let delay = 250;
  for (;;) {
    const d = await rs.send(new DescribeStatementCommand({ Id }));
    if (d.Status === 'FINISHED') return { Id, rows: d.ResultRows, ms: d.Duration / 1e6 };
    if (d.Status === 'FAILED')   throw new Error(`[${Id}] ${d.Error}`);
    if (d.Status === 'ABORTED')  throw new Error(`[${Id}] aborted`);
    await sleep(delay);
    delay = Math.min(delay * 1.5, 5000);
  }
}
```

**Poll with backoff.** A fixed 100 ms poll on a 40-minute load is 24,000 pointless API calls and will get you throttled.

### 3 · No session state by default

Each Data API call may land on a **new session**. Temp tables vanish, `SET` reverts, and a transaction cannot span two calls.

Three ways to handle it:

**`BatchExecuteStatement`** — several statements, one session, one transaction:

```js
import { BatchExecuteStatementCommand } from '@aws-sdk/client-redshift-data';

const { Id } = await rs.send(new BatchExecuteStatementCommand({
  ...BASE,
  Sqls: [
    `CREATE TEMP TABLE t AS SELECT * FROM staging.sales_line WHERE sale_date = '${d}'`,
    `DELETE FROM gold.fct_sales_line WHERE sale_date = '${d}'`,
    `INSERT INTO gold.fct_sales_line SELECT * FROM t`,
  ],
}));
```

All three run in order, in one session, in one transaction. If the third fails, the second rolls back.

**Reuse a session** by passing `SessionId` from a previous call's response — `SessionKeepAliveSeconds` controls how long it survives.

**Or, better: put the multi-statement logic in a stored procedure** (L35) and have Node issue a single `CALL`. The session problem disappears, the SQL is in git, and the transaction boundary is explicit.

### 4 · Parameters, never string concatenation

```js
// ❌ injectable, and a new query shape every call — nothing is ever compiled twice (L34)
await execute(`SELECT * FROM gold.fct_sales_line WHERE sale_date = '${req.query.d}'`);

// ✅
await execute(
  'SELECT store_sk, SUM(net_amount) FROM gold.fct_sales_line WHERE sale_date = :d GROUP BY 1',
  [{ name: 'd', value: req.query.d }],
);
```

⚠️ **Data API parameters are named (`:d`), not positional (`$1`)** — unlike `pg`. And **every parameter value is a string**; Redshift casts it against the column type. A bad date string becomes a runtime error, not a type error, so validate at the edge.

## Reading results

```js
export async function query(sql, parameters = []) {
  const { Id } = await execute(sql, parameters);

  const out = [];
  let NextToken;
  do {
    const r = await rs.send(new GetStatementResultCommand({ Id, NextToken }));
    const cols = r.ColumnMetadata.map((c) => c.name);
    for (const rec of r.Records) {
      out.push(Object.fromEntries(rec.map((f, i) => [cols[i], unwrap(f)])));
    }
    NextToken = r.NextToken;          // ⚠️ results paginate — you must follow this
  } while (NextToken);

  return out;
}

/** Data API returns a typed union per field: {stringValue}, {longValue}, {isNull} ... */
function unwrap(f) {
  if (f.isNull) return null;
  return f.stringValue ?? f.longValue ?? f.doubleValue ?? f.booleanValue ?? f.blobValue ?? null;
}
```

Two traps in that snippet, both of which bite in production:

- **Results paginate.** Forgetting `NextToken` gives you a silently truncated answer — no error, just missing rows. This is the single nastiest Data API bug because it looks like a data problem.
- **Fields are a typed union**, not plain values. `unwrap` is not optional. Note the `??` chain treats a real `0`/`false` correctly only because `??` checks for null/undefined — do not "simplify" it to `||`.

**The Data API is not a bulk export.** For large result sets, `UNLOAD` to S3 and read the files (L27).

## The `pg` alternative

```js
// db/pool.mjs
import pg from 'pg';

export const pool = new pg.Pool({
  host: 'tamimi-wg.123456789012.me-central-1.redshift-serverless.amazonaws.com',
  port: 5439,
  database: 'tamimi',
  user: process.env.RS_USER,
  password: process.env.RS_PASSWORD,       // or IAM temp credentials, below
  ssl: { rejectUnauthorized: true },
  max: 10,                                 // ⚠️ small. see below.
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 10_000,
  statement_timeout: 120_000,              // do not let a runaway query hold a slot
});

export const q = (text, values) => pool.query(text, values);   // $1, $2 here
```

**Keep the pool small.** Redshift's concurrency is governed by WLM slots (L41), not by connections — typically 5–15 concurrent queries for the whole cluster. A pool of 100 does not give you 100× throughput; it gives you 100 queued queries and a much harder problem to debug. `max: 10` per service instance is a sane start.

Prefer **IAM temp credentials** over a stored password:

```js
import { RedshiftServerlessClient, GetCredentialsCommand } from '@aws-sdk/client-redshift-serverless';

const rss = new RedshiftServerlessClient({ region: 'me-central-1' });
const { dbUser, dbPassword, expiration } = await rss.send(
  new GetCredentialsCommand({ workgroupName: 'tamimi-wg', dbName: 'tamimi', durationSeconds: 3600 }),
);
```

Cache them and refresh before `expiration`. No long-lived secret in the environment.

### Streaming a large result

```js
import QueryStream from 'pg-query-stream';

const client = await pool.connect();
try {
  const stream = client.query(new QueryStream('SELECT * FROM gold.fct_sales_line WHERE sale_date = $1', [d]));
  for await (const row of stream) {
    // constant memory
  }
} finally {
  client.release();          // ⚠️ always, in a finally
}
```

This is the one thing `pg` does that the Data API cannot.

## The shape of a real ETL job

```js
// jobs/nightly.mjs
import { execute, query } from '../db/dataApi.mjs';

export async function handler(event) {
  const batchDate = event.batchDate;                    // ⚠️ passed IN, never CURRENT_DATE (L32)
  const started = new Date().toISOString();

  try {
    // 1. land the files (upstream job, or here)
    // 2. one CALL — all the SQL logic lives in the warehouse, in git
    await execute('CALL etl.run_nightly(:d)', [{ name: 'd', value: batchDate }]);

    // 3. verify, do not assume
    const [{ n }] = await query(
      'SELECT COUNT(*) AS n FROM gold.fct_sales_line WHERE sale_date = :d',
      [{ name: 'd', value: batchDate }],
    );
    if (Number(n) === 0) throw new Error(`no rows landed for ${batchDate}`);

    await audit({ batchDate, status: 'SUCCESS', rows: Number(n), started });
    return { ok: true, rows: Number(n) };
  } catch (err) {
    await audit({ batchDate, status: 'FAILED', error: err.message, started });   // separate txn (L36)
    throw err;                                          // let Step Functions see the failure
  }
}
```

Four things worth copying out of that:

1. **The batch date is a parameter**, so a rerun of Tuesday loads Tuesday (L32).
2. **One `CALL`.** The SQL lives in the warehouse and in git, not in a template literal.
3. **Verify, then audit.** A job that reports success without checking is not a job, it is a hope.
4. **Audit the failure on a separate call** so it survives the rollback (L36), and re-throw so the orchestrator knows.

## Gotchas

- **Row-at-a-time inserts damage the cluster**, not just the job.
- **`NextToken` — results paginate.** Silent truncation.
- **Fields are typed unions.** Unwrap them.
- **Data API params are `:named`; `pg` params are `$1`.** Mixing them up is a confusing error.
- **All Data API parameter values are strings.**
- **No session state across Data API calls** unless you pass `SessionId` or use `BatchExecuteStatement`.
- **The Data API has quotas** — statement size, result size, requests per second. Read them before designing a fan-out.
- **`pg` pools must be small.** WLM slots are the real limit.
- **Always `client.release()` in a `finally`.** A leaked client eventually deadlocks the pool.
- **Serverless auto-pause** means the first query after idle takes seconds. Set generous connect timeouts.
- **Statement timeout on the `pg` pool.** Without it, one bad query holds a slot forever.
- **Redshift is not your OLTP database.** No per-request writes, no key-value lookups in a hot path, no ORM sync.

## Try it

1. Write `execute` and `query` with backoff and pagination. Run a query returning 5,000 rows and confirm you get all of them — then delete the `NextToken` loop and see how many you get.
2. Load 10,000 rows two ways: a loop of `INSERT`s, and S3 + `COPY`. Time both, then check `svv_table_info` for `unsorted` and `size` on each target. Show the class the block count.
3. Convert a three-statement job to one `CALL` and prove the failure now rolls back cleanly.
4. Switch from a password to `GetCredentials` temp credentials.
5. Point a `pg` pool with `max: 100` at the cluster, fire 200 concurrent queries, and watch the queue in `sys_query_history`. Then set `max: 10` and compare total throughput. It will not be worse.

Exercises 2 and 5 are the ones that change behaviour.

## Checklist

- [ ] Data API for jobs and Lambda; `pg` only for a long-lived service
- [ ] No row-at-a-time inserts anywhere in the codebase
- [ ] Polling uses exponential backoff
- [ ] `NextToken` followed on every result read
- [ ] Typed-union fields unwrapped
- [ ] Named parameters, never interpolation
- [ ] Multi-statement logic lives in a stored procedure
- [ ] Batch date passed in, never derived inside the query
- [ ] Every job verifies its own output before reporting success
- [ ] Failure audit written on a separate call, then re-thrown
- [ ] `pg` pool `max` ≤ 10, `statement_timeout` set, `release()` in a `finally`
- [ ] IAM temp credentials, no stored password

## You've got it when you can…

…review a teammate's pull request, spot the `for (const row of rows) await insert(row)`, and explain — with the block-count evidence from exercise 2 — why it has to be S3 and `COPY`.
