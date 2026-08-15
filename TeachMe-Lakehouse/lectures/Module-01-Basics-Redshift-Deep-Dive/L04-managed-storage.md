# L04 · Redshift Managed Storage

> **Module 01 · Lesson 04** · ~30 min

**Slide:** [`_render/L04-managed-storage.html`](_render/L04-managed-storage.html)

## What it is

Storage sits on **S3 underneath, with a local SSD cache in front of it**. Compute and storage scale independently and are billed separately.

In your app database, running out of disk means a bigger machine and a migration. Here, storage grows on its own and you size compute for the query load alone. An entire category of operational work disappears.

## Four consequences

### Automatic tiering
Frequently accessed blocks stay on local SSD; cold blocks live in S3 and are fetched on demand. **You do not manage this** and there is no knob for it.

### Petabyte scale, no capacity planning
You will not run out of space and have to migrate. Plan compute; do not plan disk.

### Cheap, fast snapshots
Backups are incremental against RMS. They are quick to take, quick to restore, and cheap to retain — which makes a restore drill practical rather than theoretical.

### Data sharing becomes possible
Because storage is decoupled from compute, another warehouse can read your **live** data without a copy being made. That is what a datashare is, and it only works because of RMS.

## Try it

```sql
-- what is actually taking space?
SELECT "schema", "table",
       size            AS mb,
       tbl_rows,
       pct_used,
       unsorted,
       diststyle
FROM   svv_table_info
ORDER  BY size DESC
LIMIT  20;

-- total, by schema
SELECT "schema",
       SUM(size) / 1024.0 AS gb,
       COUNT(*)           AS tables
FROM   svv_table_info
GROUP  BY 1
ORDER  BY gb DESC;
```

`size` is in **megabytes**, per table. `pct_used` tells you how much of the allocated space actually holds data — a low value on a large table usually means deleted rows awaiting `VACUUM` (L42).

## The one place storage still costs you

Deleted and updated rows are **not** removed immediately. Redshift marks them and reclaims the space later. Until then you are paying for them, and queries still skip past them.

```sql
-- how much dead space am I carrying?
SELECT "table", size AS mb, tbl_rows, unsorted, pct_used
FROM   svv_table_info
WHERE  size > 1000            -- tables over ~1GB
ORDER  BY pct_used ASC        -- worst first
LIMIT  20;
```

A big table with low `pct_used` and high `unsorted` is a table that needs maintenance.

## Gotchas

- **Only RA3 and Serverless use RMS.** Older DC2 clusters have fixed local storage, and there the disk-full problem is real.
- **Storage is billed separately from compute.** A paused Serverless workgroup still stores data, and you still pay for that.
- **Cold blocks are slower on first read.** A query over data untouched for months pays an S3 fetch. This is normal and usually invisible.
- **`size` is MB, not GB.** People misread this constantly and conclude a table is a thousand times bigger than it is.

## Checklist

- [ ] I can explain why compute and storage scale separately
- [ ] I know `svv_table_info.size` is in megabytes
- [ ] I know deleted rows still occupy space until `VACUUM`
- [ ] I can find the biggest tables and the ones with most dead space
- [ ] I know only RA3 and Serverless use RMS

## You've got it when you can…

…be asked "how big is our warehouse and what is driving it" and answer with two queries — total by schema, and the top twenty tables by size.
