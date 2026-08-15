# L38 · Lambda UDFs

> **Module 01 · Lesson 38** · ~35 min · **the one that is actually Node.js**

**Slide:** [`_render/L38-lambda-udfs.html`](_render/L38-lambda-udfs.html)

## What it is

Your Node.js code, called from inside a `SELECT`.

Redshift groups rows into JSON payloads, invokes your Lambda, and matches the returned array back **by position**. Any runtime, any library, your code.

It is also the fastest way to make a warehouse query fail for reasons that are not the warehouse's fault — so the design discipline matters more than the syntax.

Since Python UDFs went out of support (L37), this is **the** extensibility mechanism in Redshift.

## Registering one

```sql
CREATE OR REPLACE EXTERNAL FUNCTION f_mask_phone(phone VARCHAR)
RETURNS VARCHAR
STABLE
LAMBDA 'tamimi-mask-phone'
IAM_ROLE 'arn:aws:iam::123456789012:role/RedshiftLambdaRole';
```

Then call it like anything else:

```sql
SELECT customer_id, f_mask_phone(phone_number) AS phone
FROM   gold.dim_customer
WHERE  is_current;
```

The IAM role needs `lambda:InvokeFunction` on that function, and the role must be attached to the cluster or workgroup — the same mechanism as `COPY` and `UNLOAD` (L21, L27).

## The contract — this is the part people get wrong

Redshift sends:

```json
{
  "request_id": "23FF1F97-F28A-44AA-AB67-266ED976BF40",
  "cluster": "arn:aws:redshift:...",
  "user": "etl_service",
  "database": "tamimi",
  "external_function": "f_mask_phone",
  "query_id": 5678234,
  "num_records": 3,
  "arguments": [
    ["0501234567"],
    ["0559876543"],
    [null]
  ]
}
```

You must return:

```json
{
  "success": true,
  "num_records": 3,
  "results": ["05012***67", "05598***43", null]
}
```

**Three rules, and all three are enforced:**

1. **`results.length` must equal `num_records`.** Filter or drop one row and the query errors.
2. **Order is the contract.** Result `i` belongs to argument row `i`. No keys, no ids — position only.
3. **`success: false` fails the whole query.** There is no partial-success mode.

### The handler, in Node

```js
// tamimi-mask-phone/index.mjs
export const handler = async (event) => {
  try {
    const results = event.arguments.map(([phone]) => {
      if (phone === null || phone === undefined) return null;   // NULL in, NULL out
      const s = String(phone);
      return s.length < 7 ? s : s.slice(0, 5) + '***' + s.slice(-2);
    });

    return {
      success: true,
      num_records: results.length,       // ← must match event.num_records
      results,
    };
  } catch (err) {
    // one bad row would otherwise fail the entire query
    return { success: false, error_msg: String(err).slice(0, 250) };
  }
};
```

**Every row must produce an output**, even a bad one. A `null` for an unparseable value is almost always better than failing a 40-minute query. Decide that policy deliberately and write it in the function's README.

**Handle `null` explicitly.** Redshift NULLs arrive as JSON `null` and JavaScript will happily turn them into the string `"null"` if you are careless.

## Multiple arguments

```sql
CREATE OR REPLACE EXTERNAL FUNCTION f_distance_km(
    lat1 FLOAT8, lon1 FLOAT8, lat2 FLOAT8, lon2 FLOAT8)
RETURNS FLOAT8
STABLE
LAMBDA 'tamimi-geo-distance'
IAM_ROLE 'arn:aws:iam::123456789012:role/RedshiftLambdaRole';
```

Each element of `arguments` is then a four-element array, in declared order:

```js
const results = event.arguments.map(([lat1, lon1, lat2, lon2]) => haversine(lat1, lon1, lat2, lon2));
```

## What you are signing up for

### The blast radius is now the query

A cold start, a concurrency limit, or a timeout **fails a `SELECT`**. Things that were an ops concern are now a data concern.

Mitigations, in order:

- **Reserve concurrency** on the function so a big scan cannot starve it — and so it cannot starve everything else in the account.
- **Keep the function trivially fast.** No network calls inside it if you can help it. A Lambda UDF that calls an external API has that API's availability inside your SQL.
- **Raise the timeout** but keep it far below the query timeout.
- **Retry inside the handler**, not by letting Redshift fail.

### Every slice invokes independently

This is the one that surprises people. A large scan spread across 64 slices produces **64 concurrent invocation streams**, and a Lambda UDF over a billion-row table can spike account-level concurrency hard enough to throttle unrelated services.

Two tuning knobs:

```sql
CREATE OR REPLACE EXTERNAL FUNCTION f_mask_phone(VARCHAR)
RETURNS VARCHAR STABLE
LAMBDA 'tamimi-mask-phone'
IAM_ROLE '...'
MAX_BATCH_ROWS 1000        -- rows per invocation
RETRY_TIMEOUT 20000;       -- ms Redshift keeps retrying a failed invocation
```

Larger `MAX_BATCH_ROWS` means fewer invocations and less overhead, but a bigger payload — and there is a hard payload limit, so a wide `VARCHAR` argument forces the batch size down.

### Filter first, always

```sql
-- ❌ masks every row, then throws most away
SELECT * FROM (SELECT f_mask_phone(phone) AS p, region FROM gold.dim_customer)
WHERE region = 'WEST';

-- ✅ filter first, then mask what survives
SELECT f_mask_phone(phone) AS p, region
FROM   gold.dim_customer
WHERE  region = 'WEST' AND is_current;
```

**Never call a Lambda on rows you throw away.** Check the `EXPLAIN` plan (L28) to confirm the filter really is applied first — and be aware that the planner does not always know a UDF is expensive.

## When it is the right tool

| Good | Why |
|---|---|
| Tokenisation / detokenisation | The vault is external by design |
| Masking PII for a non-privileged role | Logic must be central and auditable |
| Geocoding, address normalisation | Needs a library and reference data |
| Calling an ML endpoint | Genuinely external |
| A licensed algorithm | Cannot be reimplemented in SQL |

| Bad | Do this instead |
|---|---|
| String formatting | SQL string functions |
| Date arithmetic | `DATEADD`, `DATE_TRUNC`, `dim_date` |
| Lookups | Join to a dimension |
| Anything per-row on a fact table | Precompute a column at load time |

The last row is the important one. **If the value is stable, compute it once during the load and store it.** A Lambda UDF called at query time recomputes the same answer for every reader, forever.

> For masking specifically, check whether **dynamic data masking** policies solve your case natively (L13) — a policy is cheaper, declarative, and does not put a Lambda in the query path.

## Monitoring

```sql
-- external function calls show up in query history
SELECT query_id, LEFT(query_text, 80), elapsed_time/1000000.0 AS secs
FROM   sys_query_history
WHERE  query_text ILIKE '%f_mask_phone%'
ORDER  BY start_time DESC LIMIT 20;
```

Then watch the function's own CloudWatch metrics — `Invocations`, `Throttles`, `Duration`, `Errors`. **A rise in `Throttles` will show up as intermittent query failures** that look like a Redshift problem and are not.

## Gotchas

- **`results.length` must equal `num_records`.** Never filter inside the handler.
- **Order is the only contract.** Never reorder, never dedupe.
- **`success: false` fails the whole query.**
- **Nulls arrive as JSON `null`** — handle them.
- **Every slice invokes independently.** Reserve concurrency.
- **There is a payload size limit**, so wide arguments force small batches.
- **Cold starts add seconds** to the first invocation of an idle function.
- **The IAM role must be attached to the cluster**, not merely to exist.
- **Cost is now two services.** A daily report calling a Lambda 200 million times has a Lambda bill.
- **`STABLE` vs `VOLATILE` matters more here** — a `VOLATILE` external function cannot be optimised at all.

## Try it

1. Deploy `tamimi-mask-phone` and register it. Call it on ten rows.
2. Break the contract deliberately: return `results.length - 1` results. Read the error message so you recognise it later.
3. Pass a `NULL` and confirm you get `NULL` back, not `"null"`.
4. Run it over a large table with and without a selective `WHERE`, and compare invocation counts in CloudWatch.
5. Set `MAX_BATCH_ROWS 10`, rerun, and watch the invocation count explode. Then set it to 1000.

Step 5 makes the batching real in a way no explanation does.

## Checklist

- [ ] Handler returns exactly `num_records` results, in order
- [ ] Every row produces an output — bad rows return `null`, not an exception
- [ ] Nulls handled explicitly
- [ ] `try/catch` wraps the whole handler
- [ ] Reserved concurrency set on the function
- [ ] `MAX_BATCH_ROWS` tuned and `RETRY_TIMEOUT` set
- [ ] Filters applied before the UDF, and confirmed in `EXPLAIN`
- [ ] CloudWatch alarm on `Throttles` and `Errors`
- [ ] I checked whether native masking or a precomputed column would do instead

## You've got it when you can…

…be asked to mask phone numbers for the analyst role, and answer with three options — a masking policy, a precomputed column, and a Lambda UDF — and say which one you would pick and why.
