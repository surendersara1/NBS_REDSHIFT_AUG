# L02 · Clusters, Nodes and Slices

> **Module 01 · Lesson 02** · ~40 min

**Slide:** [`_render/L02-clusters-nodes-slices.html`](_render/L02-clusters-nodes-slices.html)

## What it is

A Redshift cluster is **one leader node and several compute nodes**, and each compute node is divided into **slices**. A slice is the unit of parallelism — the thing that actually reads bytes off disk.

Every table you create is spread across every slice. *How evenly* it spreads is a decision you make (L15), and it decides your query time more than any other single factor.

## Who does what

### Leader node
Parses your SQL, plans it, compiles the plan into C++ segments, ships those to the compute nodes, and merges the final result. **It holds no user data.**

Two consequences worth knowing:
- Queries returning millions of rows make the leader the bottleneck — it has to merge and stream all of them.
- Some functions can only run on the leader (many `CURRENT_*` and catalogue queries), which is why a query mixing them with a table scan occasionally behaves oddly.

### Compute nodes
Each holds a share of every table and runs the same compiled code against its own share, in parallel.

### Slices
Each node is divided into slices, each with its own share of memory and disk. **A slice is what scans.** A cluster with 4 nodes × 4 slices has 16 workers; a query is only as fast as its slowest one.

## Skew is the enemy

If most rows land on one slice, one slice does most of the work and the rest wait. This is a **design bug, not a capacity problem** — adding nodes will not fix it.

```sql
-- the skew check. run this before you tune anything.
SELECT "schema", "table", tbl_rows, size AS mb,
       diststyle, skew_rows, unsorted, stats_off
FROM   svv_table_info
ORDER  BY skew_rows DESC NULLS LAST
LIMIT  20;
```

**Reading it:**

| Column | What it means | Act when |
|---|---|---|
| `skew_rows` | ratio of the heaviest slice to the lightest | **> 4** |
| `unsorted` | % of rows not in sort-key order | **> 10** |
| `stats_off` | % staleness of the planner's statistics | **> 10** |
| `diststyle` | the distribution actually in effect | it is not what you intended |

`skew_rows > 4` means one slice holds four times the rows of the lightest. The usual cause is a `DISTKEY` on a low-cardinality column — `country`, `status`, `is_active`. Ten distinct values across sixteen slices leaves six slices empty and the rest overloaded.

## How many slices do I have?

```sql
SELECT COUNT(*) AS slice_count
FROM   stv_slices
WHERE  type = 'D';        -- data slices, excluding the leader
```

On Serverless this varies with the RPU capacity in play, which is one reason performance testing there needs more than one run.

## Try it

```sql
-- 1. how wide is my cluster?
SELECT COUNT(*) AS slices FROM stv_slices WHERE type = 'D';

-- 2. which tables are skewed?
SELECT "table", tbl_rows, skew_rows, diststyle
FROM   svv_table_info
WHERE  tbl_rows > 1000000
ORDER  BY skew_rows DESC NULLS LAST;

-- 3. is a specific column a sensible DISTKEY?
--    (rule of thumb: distinct values should exceed slice count by a lot)
SELECT COUNT(DISTINCT store_sk) AS distinct_values,
       COUNT(*)                 AS total_rows
FROM   gold.fct_sales_line;
```

If `distinct_values` is smaller than your slice count, that column is a bad `DISTKEY`.

## Gotchas

- **More nodes will not fix skew.** You will pay more and wait the same.
- **`skew_rows` is `NULL` for `DISTSTYLE ALL`** — that is expected; every slice holds a full copy.
- **A small table with skew does not matter.** Check tables above a million rows first.
- **Serverless hides the node count** but the slice concept is identical.

## Checklist

- [ ] I can explain leader vs compute vs slice
- [ ] I know a query is as fast as its slowest slice
- [ ] I run the `svv_table_info` skew check before tuning
- [ ] I know `skew_rows > 4` is the threshold to act on
- [ ] I would not pick a low-cardinality column as a `DISTKEY`

## You've got it when you can…

…be shown a query that is slow on a big cluster and check skew before touching the SQL — because if one slice holds most of the rows, no amount of rewriting will help.
