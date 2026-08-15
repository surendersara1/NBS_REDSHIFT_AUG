# L22 · When COPY Fails

> **Module 01 · Lesson 22** · ~35 min

**Slide:** [`_render/L22-when-copy-fails.html`](_render/L22-when-copy-fails.html)

## What it is

```
ERROR:  Load into table 'sales_line' failed.
        Check 'stl_load_errors' system table for details.
```

That is the whole message. It names a table, not a cause. **So check the table** — it records the file, the line, the column, the declared type and the raw value that failed.

Learn this query now rather than at 6am:

```sql
SELECT starttime,
       filename,
       line_number,
       colname,
       type,
       col_length,
       raw_field_value,
       err_code,
       TRIM(err_reason) AS err_reason
FROM   stl_load_errors
ORDER  BY starttime DESC
LIMIT  20;
```

## The four causes

### 1 · Value too long — bytes, not characters

The most common failure on this data. A `VARCHAR(20)` sized by counting letters overflows on Arabic or emoji, where one character can be four bytes (L09).

```sql
-- find the real width before you size the column
SELECT MAX(octet_length(store_name)) AS max_bytes,
       MAX(length(store_name))       AS max_chars
FROM   staging.stores_raw;
```

### 2 · Type mismatch

An **empty CSV field is not a `NULL`** unless you said `BLANKSASNULL`. A date in an unexpected format needs `DATEFORMAT`/`TIMEFORMAT`. A thousands separator in a numeric field fails.

```sql
COPY ... CSV BLANKSASNULL EMPTYASNULL DATEFORMAT 'auto' TIMEFORMAT 'auto';
```

### 3 · Delimiter inside a field

A comma inside a quoted product name breaks a naive parse.

```sql
COPY ... CSV;                    -- ✅ understands quoting
COPY ... DELIMITER ',';          -- ❌ does not
```

### 4 · Permissions

The IAM role needs `s3:GetObject` **and** `kms:Decrypt` if the bucket is encrypted. Missing KMS is the confusing one — the error talks about access, and the bucket policy looks correct.

## The diagnosis workflow

```sql
-- 1. what failed, exactly?
SELECT filename, line_number, colname, type, raw_field_value, TRIM(err_reason)
FROM   stl_load_errors
ORDER  BY starttime DESC LIMIT 5;

-- 2. is it one bad row or a systemic problem?
SELECT colname, TRIM(err_reason) AS reason, COUNT(*) AS n
FROM   stl_load_errors
WHERE  starttime > DATEADD(hour, -1, GETDATE())
GROUP  BY 1, 2
ORDER  BY n DESC;

-- 3. what got committed before it stopped?
SELECT query, filename, lines_scanned, is_partial
FROM   stl_load_commits
WHERE  query = (SELECT MAX(query) FROM stl_load_errors);
```

Step 2 is the one that saves time: **one bad row is a data problem; a thousand identical errors is a column definition problem.**

## Surveying a new feed

When you have never seen a source before, tolerate errors *once*, deliberately, to find out what is in it:

```sql
COPY staging.new_feed
FROM 's3://bucket/new-feed/'
IAM_ROLE '...'
CSV IGNOREHEADER 1
MAXERROR 10000;              -- SURVEY ONLY

-- then read what it complained about
SELECT colname, type, TRIM(err_reason) AS reason,
       COUNT(*) AS n, MIN(raw_field_value) AS example
FROM   stl_load_errors
WHERE  starttime > DATEADD(minute, -10, GETDATE())
GROUP  BY 1, 2, 3
ORDER  BY n DESC;
```

Then fix the table definition and **remove `MAXERROR`**. Leaving it in production means silently discarding rows and reporting on incomplete data.

## Good news about failure

**A failed `COPY` rolls back entirely.** The table is unchanged. You are diagnosing a non-event, not repairing damage — which is a much better position than a half-applied load.

That is also the argument for `COPY`-into-staging: a failure there touches nothing anyone queries.

## Gotchas

- **`stl_load_errors` has a retention window.** Query it while the failure is fresh.
- **`MAXERROR 1000` silently discards up to 1000 rows** and reports success.
- **`TRUNCATECOLUMNS` silently shortens values** — the load succeeds and the data is wrong.
- **The row it names may not be the only bad one** — check whether it is systemic.

## Checklist

- [ ] I know the `stl_load_errors` query without looking it up
- [ ] I check whether a failure is one row or systemic
- [ ] `BLANKSASNULL` and `EMPTYASNULL` are set on CSV loads
- [ ] I use `CSV`, never `DELIMITER`, on quoted data
- [ ] The load role has `kms:Decrypt` as well as `s3:GetObject`
- [ ] No `MAXERROR` or `TRUNCATECOLUMNS` survives into production
- [ ] Column widths measured from `octet_length` on real data

## You've got it when you can…

…be handed "the load failed" and produce the column name, the offending value and the reason in one query — then say whether it is a data problem or a schema problem.
