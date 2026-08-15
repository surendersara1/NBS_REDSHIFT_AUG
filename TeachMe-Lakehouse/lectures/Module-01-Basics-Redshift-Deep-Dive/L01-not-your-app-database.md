# L01 · Redshift Is Not Your App Database

> **Module 01 · Lesson 01** · ~40 min

**Slide:** [`_render/L01-not-your-app-database.html`](_render/L01-not-your-app-database.html)

## What it is

Redshift speaks the PostgreSQL wire protocol. `psql` connects. Most of your SQL runs unchanged. Your ORM will even connect to it.

**That similarity is the trap.** Underneath it is a completely different machine, and the instincts that make you good at Postgres will make you slow here — silently, with no error to tell you why.

## The four differences that matter

### 1 · Rows → columns

Postgres stores a row together on disk, because an application fetches whole rows: *give me user 4471*.

Redshift stores each **column** together, because analytics fetches few columns of very many rows: *give me the sum of net_amount for last quarter*.

A query touching 3 columns of a 200-column table reads roughly **1.5% of the bytes**. That single fact is most of the performance difference — and it is why `SELECT *` is a much worse habit here than it is in an app.

### 2 · One box → many slices

Your app database is one machine. Redshift splits every table across **slices** and runs the same compiled plan on all of them simultaneously (L02).

The consequence: performance depends on how *evenly* your data is spread, which is a design decision you make at `CREATE TABLE` time (L15).

### 3 · Indexes → physical layout

```sql
-- does not exist in Redshift
CREATE INDEX idx_sales_date ON sales (sale_date);
```

There is **no `CREATE INDEX`**. Instead you choose a **sort key** and a **distribution style**, once, when you create the table. L14 is the whole lesson; take from here only that reaching for an index is the reflex to lose first.

### 4 · Row writes → bulk loads

```sql
-- Node habit: fine in Postgres, fatal here
INSERT INTO sales VALUES (...);   -- × 1,000,000
```

Columnar storage rewrites blocks on every write. One `INSERT` of a million rows is cheap; a million single-row `INSERT`s takes hours and bloats the table with deleted-but-not-reclaimed space.

```sql
-- Redshift: one statement, minutes not hours
COPY sales
FROM 's3://bucket/dt=2026-08-12/'
IAM_ROLE 'arn:aws:iam::123456789012:role/redshift-loader'
FORMAT AS PARQUET;
```

## Try it

Connect with Query Editor v2 and run these three. They tell you where you are:

```sql
SELECT current_database(), current_user, version();

-- how big are things, and how well laid out?
SELECT "schema", "table", size AS mb, tbl_rows,
       diststyle, sortkey1, skew_rows, unsorted, stats_off
FROM   svv_table_info
ORDER  BY size DESC
LIMIT  20;

-- what have I run, and how long did it take?
SELECT query_id, elapsed_time / 1000000.0 AS secs, status,
       LEFT(query_text, 80) AS sql
FROM   sys_query_history
WHERE  user_id = current_user_id
ORDER  BY start_time DESC
LIMIT  20;
```

`svv_table_info` is the single most useful view in Redshift. You will come back to it in L02, L15, L16 and L42.

## The five habits to unlearn

| From Node + app DB | In Redshift |
|---|---|
| `INSERT` per row | `COPY` in bulk, then `MERGE` |
| Add an index | Choose a **sort key** and a **distribution style** |
| `PRIMARY KEY` prevents duplicates | It does **not** — you test for them (L18) |
| Hold a connection pool | Use the **Data API** — nothing to hold (L06) |
| Normalise everything | **Denormalise** the reporting layer deliberately |

## Gotchas

- **Your ORM will connect and then behave badly.** It will issue row-at-a-time writes and `SELECT *`. Do not point Sequelize or Prisma at a warehouse.
- **`SELECT *` is expensive here** in a way it is not in Postgres — you have just asked for every column of a columnar store.
- **The first run of a query is slow** because Redshift compiles it (L05). Never benchmark a first run.

## Checklist

- [ ] I can explain columnar storage to someone who only knows row storage
- [ ] I know there is no `CREATE INDEX` and what replaces it
- [ ] I would never write a row-at-a-time insert loop against Redshift
- [ ] I have run the three queries above against a real cluster
- [ ] I know what `svv_table_info` is for

## You've got it when you can…

…explain to another Node developer why the pattern they are about to write — an ORM loop that inserts records one at a time — will work perfectly in dev and fall over in production, and what to write instead.
