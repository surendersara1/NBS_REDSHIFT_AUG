# L01 · Why Your App Database Can't Do This
> **Module 1 · Lesson 01** · ~45 min

## The point
Your app's database is built to fetch one row fast; analytics asks for every row at once, and that is a different machine.

## Key ideas
- **OLTP** (your app DB) = many tiny reads/writes by key, answered in milliseconds via an index seek.
- **OLAP** (analytics) = few enormous reads, no writes, answered in seconds by scanning everything.
- A **row store** keeps each row's fields together, so reading one column still drags all 29 off the disk.
- A **column store** keeps each column together, so `SELECT MATKL, COUNT(*) … GROUP BY MATKL` reads 1 of 29 columns — about **97% less data**.
- Scale is the whole argument: `ZHOCIDC` 1,377,080,716 rows, `S603` 648,802,247, `S611` 638,035,208.
- You never report off production: SAP's CPU runs the tills, and one analyst's `GROUP BY` can stall a checkout lane.
- So we copy data out instead — date-windowed, capped at 8 parallel JDBC lanes so we never overwhelm the source.

## Words you'll hear
| Term | Means |
|---|---|
| OLTP | transaction workload — one row, by key, right now |
| OLAP | analytical workload — all rows, summarised |
| Row store | fields of one row stored next to each other |
| Column store | values of one column stored next to each other |
| Full scan | reading every row because there is no useful index |
| Watermark | the column we use to pull only new rows (`SPTAG` on S611) |

## In this repo
- `src/glue/specs/download/sap_s611.yaml` — 638 M rows: `watermark_column: SPTAG`, `jdbc_hash_partitions: "8"`, and the comment explaining why the lane count is capped.
- `src/glue/specs/download/sap_zhocidc.yaml` — the 1.38 B-row POS table, pulled date-windowed, never full.
- `src/glue/specs/download/sap_s603.yaml` — the third giant.
- `docs/handoff/SAP-BASE-TABLES.md` — the real row counts and the rule "Giants: pull date-windowed, never full".

## Do this
Open `src/glue/specs/download/sap_s611.yaml`. Count the columns in `schema:`, then work out how many bytes a row-store scan reads versus a column store that needs only `MATKL`.

## You've got it when you can...
Explain why `SELECT id FROM orders WHERE id = 42` and `SELECT store, SUM(sales) FROM orders GROUP BY store` want opposite storage layouts — and why we never run the second one against SAP.
