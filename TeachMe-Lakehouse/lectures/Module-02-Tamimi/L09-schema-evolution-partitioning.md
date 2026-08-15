# L09 · Changing a Table Without Breaking It

**Slide:** [`_render/L09-schema-evolution-partitioning.html`](_render/L09-schema-evolution-partitioning.html)

## The point

Iceberg makes **additive** change cheap: adding a column is a metadata edit, old data files stay valid, nothing is rewritten. Everything else — dropping, renaming, re-typing, reordering, re-partitioning — is a migration, and this platform is deliberately built to **stop** rather than to absorb it.

The reason is a failure mode you cannot see: when a write fails, the old table stays readable, so downstream keeps serving pre-change data and nothing surfaces the problem. Loud failure is the cheaper outcome.

## Key ideas

- **Safe: add a column at the end.** Iceberg assigns it a new field id; existing files simply don't have it and read back NULL. Backfill before anyone depends on it — a NULL that means "not populated yet" gets read as a business value.
- **Breaking: drop, rename, narrow, re-type, reorder.** Each changes what existing rows *mean*, and each has bitten this repo.
- **`on_schema_change: fail` is a choice, not a default.** Every Gold model inherits it from `dbt_project.yml`, with the comment "NEVER silently absorb schema drift". The alternatives (`ignore`, `append_new_columns`, `sync_all_columns`) all let a mismatch pass quietly into a table Power BI is reading. We would rather the build go red.
- **Schema evolution is allowed only on writes that rewrite every row.** `full_refresh` and `create_or_replace` pass Iceberg's `merge-schema` option, so an added column lands instead of failing. `append`, `overwrite_partitions` and `merge_into` deliberately do **not** get it — they touch a subset of rows and would leave the rest NULL in the new column. A unit test pins that.
- **Dropping is refused by name.** `merge-schema` is a union, so a column the frame stopped emitting would survive on the target and get NULLs written over real values. `_guard_non_additive_drift` raises first, naming the table and the columns — replacing a 40-column Spark arity error that never said what to do about it.
- **The real incident (R54).** `ops.py` gained `is_billing_plan`, so `abap_transform` began emitting **42** columns into **41**-column tables and died with `INSERT_COLUMN_ARITY_MISMATCH.TOO_MANY_DATA_COLUMNS` — on QA, and latent on Dev. Meanwhile the stale table stayed readable and downstream kept serving pre-change numbers. R56 was the same thing again on `sap.distress_603`.
- **Partitioning is a create-time decision.** `partition_by` is consulted **only** on first write, when the SQL-DDL `CREATE TABLE … PARTITIONED BY (…)` runs. Later writes inherit the existing layout. Editing the YAML on a live table changes nothing — and no existing data ever moves.
- **The type-widening trap (M-28).** `unified_customer_count` unions three legs. The actuals legs' raw `cc` is BIGINT; the budget leg is `SUM(cc_budget)`, which is fractional. A first build with only the actuals legs materialises `cc` as BIGINT — then the next run, once the budget leg carries rows, widens it to NUMERIC, `on_schema_change='fail'` trips, and Gold needs a manual `--full-refresh`. **The fix is to pre-CAST every leg to the same `NUMERIC(38,4)`, so the resolved column type can never drift regardless of which legs have rows.**
- **Same trap, one layer down.** `stg_sap_zscc` casts `zcustomer`/`zitem` to `NUMERIC(38,4)` for the same reason: leaving them VARCHAR raised *"UNION types numeric and character varying cannot be matched"*. Pin types at the edge of the model, not in the middle.

## Words you'll hear

| Word | What it means here |
|---|---|
| Additive change | Add a column at the end. Metadata-only; no data rewritten |
| Schema drift | The frame's columns no longer match the target's |
| `on_schema_change` | dbt's policy knob. We use `fail` on every Gold model |
| `merge-schema` | Iceberg write option that lets an added column land. Full-rewrite paths only |
| `INSERT_COLUMN_ARITY_MISMATCH` | Spark's "you gave me 42 columns for a 41-column table" |
| Type widening | BIGINT → NUMERIC, resolved at build time from whichever legs carried rows |
| Partition spec | The `PARTITIONED BY` layout, fixed when the table is created |
| Partition evolution | Changing that spec for *future* writes. Old data never moves |

## In this repo

- [`src/dbt/dbt_project.yml:88-93`](../../../tamimi-lakehouse/src/dbt/dbt_project.yml) — the Gold defaults: `+incremental_strategy: merge`, and line **91** `+on_schema_change: fail   # NEVER silently absorb schema drift`.
- [`src/dbt/models/marts/gold/unified_customer_count.sql:27-34`](../../../tamimi-lakehouse/src/dbt/models/marts/gold/unified_customer_count.sql) — the model's own config, `on_schema_change='fail'` at `:31`. The **M-28 comment at `:36-42`** is the clearest explanation of the widening trap in the codebase; the pre-casts are at `:47`, `:58` and `:79`.
- [`src/glue/glue_engine/writers/s3_tables.py:326-361`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/s3_tables.py) — `full_refresh`. Docstring `:337-345` records R54; the `merge-schema` option is at `:354`. Same pattern in `create_or_replace` at `:363-405`.
- [`src/glue/glue_engine/writers/s3_tables.py:297-324`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/s3_tables.py) — `_guard_non_additive_drift`: read the raised message, it is a model of a good error.
- [`src/glue/glue_engine/writers/s3_tables.py:116-117`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/s3_tables.py) — *"`partition_by` is consulted ONLY on first-write (when the table is created); subsequent appends inherit the existing Iceberg layout."* The DDL that consumes it is at `:165-172`.
- [`src/glue/specs/bronze/sap_zsdcc.yaml:56-57`](../../../tamimi-lakehouse/src/glue/specs/bronze/sap_zsdcc.yaml) — a real partition spec, `months(date)`. Iceberg transforms like this are why the writer uses SQL DDL rather than Spark V2's `.partitionedBy()`.
- [`docs/risks.md`](../../../tamimi-lakehouse/docs/risks.md) — **R54** (the 41-vs-42 column drift, the engine fix, and the deliberate decision to exclude the partial-write paths) and **R56** (the same class recurring on `distress_603`). Read R54's mitigation column: it is the best short account of this whole lesson.
- [`src/dbt/models/staging/stg_sap_zscc.sql:32-41`](../../../tamimi-lakehouse/src/dbt/models/staging/stg_sap_zscc.sql) — the staging-level casts and the UNION type error they prevent.

## Do this

1. Add a column to a Silver derived table's DataFrame in Dev and run the transform. Watch `full_refresh` absorb it. Now do the same on a path that uses `append` and predict the error before you read it.
2. Delete a column from that frame instead, and read the message `_guard_non_additive_drift` raises. Compare it to the raw Spark arity error it replaced.
3. Change `partition_by` in a spec for a table that already exists. Re-run. Confirm nothing changed, then explain why from `s3_tables.py:116-117`.
4. In `unified_customer_count`, mentally delete the three `CAST(... AS NUMERIC(38,4))`. Describe the exact sequence of two runs that breaks the model — first run fine, second run red.
5. Write the checklist you would follow to add a column to a Gold model end to end: Silver frame → Silver table → staging model → Gold model → `--full-refresh` or not.

## You've got it when you can…

…classify any proposed schema change as **additive (safe) / non-additive (a migration)** in one sentence; explain why we chose `on_schema_change: fail` over silent absorption using the R54 failure mode (*"the stale table stays readable and keeps serving pre-change numbers"*); state that partitioning is fixed at create and editing the YAML later does nothing; and describe the M-28 fix as **"pin every UNION leg to the same type so the resolved column type can't drift between runs."**
