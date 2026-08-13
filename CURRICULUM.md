# Redshift in five days — 8 engineers, 8 hours a day

**Audience:** application developers with zero Redshift experience who are
about to join a data warehouse project.

**Design principle:** they already know SQL. What they do not know is that a
warehouse punishes OLTP instincts — row-by-row updates, reliance on
constraints, indexes, `SELECT *`. Every day attacks one of those instincts
with a measurement, not an assertion.

**Format per day:** 90 min taught → 3 hr paired lab → 60 min lunch →
2 hr solo lab → 30 min readout where two people present their query plans.
Pair rotation daily; nobody pairs with the same person twice.

---

## Day 1 — The mental model, and everything that is not Postgres

**Taught (90 min)**
- Architecture: leader node, compute nodes, slices. Why the count of slices
  is the unit that matters.
- Columnar storage and 1 MB block zone maps. Why `SELECT *` is a different
  kind of mistake here than in Postgres.
- Managed storage on RA3: compute and storage scale separately.
- The five things Postgres has that Redshift does not: enforced constraints,
  indexes, real `SERIAL`, cheap single-row DML, subtransactions.

**Lab** — `sql/01_setup_and_objects.sql`
Create schemas, roles, users, and one of every object type. Then:
1. Declare a PRIMARY KEY on a column you have deliberately duplicated. Query
   it. Explain why the answer is wrong. *This is the day-1 gut punch — the
   constraint is a hint, not a guarantee.*
2. Create a temp table shadowing a permanent one. Watch unqualified queries
   silently hit the wrong table.
3. `svv_table_info` for every table you made. Learn the columns.

**Exit check:** each learner explains, without notes, why Redshift has no
indexes and what replaced them.

---

## Day 2 — Getting data in and out

**Taught (90 min)**
- COPY vs Spectrum vs UNLOAD, chosen by access frequency, not data size.
- Why COPY parallelises by file, and why one large gzip file is the classic
  ingestion mistake.
- `IGNOREHEADER`, `MAXERROR`, `COMPUPDATE`, `STATUPDATE` — what each changes.
- External schemas: metadata in Glue, bytes in S3.

**Lab** — `sql/02_spectrum_copy_unload.sql`
1. COPY both CSVs into `staging`. Break it on purpose: wrong `DATEFORMAT`,
   missing `IGNOREHEADER`. Diagnose each **only** from `stl_load_errors`.
2. Register external tables. Run the same aggregate through Spectrum and
   through native tables. Record both times.
3. UNLOAD with `PARALLEL ON` then `PARALLEL OFF`. Count the files. Explain
   the difference to your pair.
4. UNLOAD `PARTITION BY (status)`, then query one partition and read
   `s3_scanned_bytes` in `sys_external_query_detail`. Prove pruning happened.

**Exit check:** a learner can state the byte count their query scanned and
why it was not the whole table.

---

## Day 3 — The lakehouse: Glue, Iceberg, S3 Tables

**Taught (90 min)**
- Medallion layers and what each guarantees. Bronze is typed but not joined;
  silver is joined and rebuildable; gold is modelled for consumption.
- Iceberg: snapshots, schema evolution, `MERGE`, why the join happens once.
- The S3 Tables → Glue → Redshift federated catalog mapping:
  table bucket → catalog, namespace → database, table → table.

**Lab** — `glue/` + `sql/03_s3tables_federated_catalog.sql`
1. Run `job_raw_to_bronze`. Find the quarantined rows. Explain each one
   against the generator's injected defects.
2. Run it **again**. Prove row counts did not change — that is what MERGE
   bought you.
3. Run `job_bronze_join_to_silver`. Read the printed plan; find the
   broadcast. Remove `F.broadcast()`, re-run, compare.
4. Query the Iceberg silver table from Redshift with no load at all.

**Exit check:** the orphan count from the silver job matches the generator's
injected orphan count.

---

## Day 4 — Physical design: the day that decides the project

**Taught (90 min)**
- DISTKEY: collocated joins vs redistribution. `DS_DIST_NONE` as the goal.
- SORTKEY: zone maps, compound vs interleaved, matching the WHERE clause.
- Compression: `az64`, `zstd`, `bytedict`, and when raw is right.
- Materialized views, automatic query rewriting, and the external-schema
  refresh limitation.

**Lab** — `sql/04_modeling_matviews_compute.sql`, then `10_four_mechanisms.sql`
and `11_sortkey_design.sql`

`sql/10` builds the same data four ways so each mechanism is *measured*, not
asserted. `sql/11` is sort-key design and ends with the function-in-`WHERE`
trap — the exercise that produces the biggest single number of the week.

1. Build `fct_customer_orders` twice — once `DISTSTYLE EVEN`, once
   `DISTKEY(customer_id)`. `EXPLAIN` the same join on both. Find
   `DS_BCAST_INNER` on one and `DS_DIST_NONE` on the other.
2. Build it a third time with every column `ENCODE raw`. Compare `size` in
   `svv_table_info`. Report the multiple.
3. Create the native MV with `AUTO REFRESH YES`. Then try to create the
   external-table MV with `AUTO REFRESH YES` and read the error. *This
   failure is the lesson — external schemas disqualify auto-refresh.*
4. Run the window-function compute. UNLOAD it partitioned by `ltv_tier`.
   Register it as external and query one tier.

**Exit check:** each learner reports their skew ratio and encoding size
multiple as numbers, not impressions.

---

## Day 5 — Procedures, operations, and the catalog

**Taught (90 min)**
- Redshift PL/pgSQL limits: **one concurrent cursor**, 16 nesting levels,
  no subtransactions, no `VACUUM` inside a procedure.
- Why DELETE+INSERT is the idiomatic merge and cursor loops are not.
- `SECURITY DEFINER` vs `INVOKER`, and injection via unquoted dynamic SQL.
- The five catalog families: SVV / SYS / STL / STV / SVL.

**Also taught:** views vs late-binding views vs MVs (`sql/07`), the two kinds
of external schema — Spectrum over the catalog vs FEDERATED to a live
RDS/Aurora database (`sql/08`), and roles / CLS / RLS / reader-writer
separation (`sql/09`).

**Lab** — `sql/05_procedures.sql` + `sql/06_svv_sys_deep_dive.sql`
1. Run all five procedures. Break one by nesting a `FOR` loop inside another
   and read the runtime failure. *One cursor, estate-wide.*
2. Make `sp_run_data_quality` fail a BLOCKING check. Confirm all five checks
   still recorded before the raise.
3. Write `sp_archive_partition` with naive string concatenation instead of
   `quote_literal`. Demonstrate the injection. Fix it.
4. Catalog sprint — answer from the system views only, no console:
   - Which table has the worst skew?
   - Which query consumed the most **total** time in 24 h?
   - Which columns are unencoded?
   - Who can SELECT from `analytics.fct_customer_orders`?
   - Which MV refresh was a full recompute rather than incremental?
   - Which query scanned the most S3 bytes?
5. Clone `amazon-redshift-utils`, install `v_generate_tbl_ddl`, and
   reconstruct the DDL of a table you did not create.

**Exit check:** the catalog sprint, closed-book, in under 45 minutes.

---

## Assessment

The team is ready for the project when, given an unfamiliar slow query, a
learner can — without help — produce the plan, name the distribution
problem, cite the `svv_table_info` row supporting it, and propose a DISTKEY
or SORTKEY change with a predicted effect. That is one exercise, and it is
the only one that matters.

## If you have fewer than five days

- **Three days:** Days 1, 2, 4. Drop the lakehouse and procedures. Physical
  design is non-negotiable — it is the day that pays for the project.
- **Two days:** Day 1 + Day 4, with the COPY lab folded into Day 1.

Never drop Day 4.
