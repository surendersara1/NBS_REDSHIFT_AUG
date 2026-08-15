# L12 · Partitions, Shuffles, Skew, Cache

**Slide:** [`_render/L12-spark-performance.html`](_render/L12-spark-performance.html)

## The point

Spark is lazy. A DataFrame is a *plan*, not data — and **every action re-runs the plan from the top** unless you tell it not to. Four consequences, all of them visible in this repo as real incidents.

- **`.cache()` before a multi-action sequence.** `read_incremental` does three things with one frame: `df.count()`, `df.agg(MAX(watermark))`, and the caller's write to Bronze. Without `df.cache()` that is **three full JDBC pulls** from SAP — three times the load, three times the cost, and non-determinism if the source moves between passes.
- **Partition the read, or one connection carries the whole table.** A JDBC read without `predicates` (or `partitionColumn`) is a **single connection**, regardless of what the spec says about parallelism.
- **A shuffle is the price of grouped or ordered logic.** `groupBy(...).applyInPandas(...)` moves every row across the network and materialises each group in a Python worker. Worth it for a receipt; ruinous for a key with a huge group.
- **Skew beats configuration.** A stage finishes when its *slowest* partition finishes. One store-day with 10× the receipts holds the whole stage, and no `numPartitions` setting fixes that.

## Key ideas

- **Actions, not transformations, cost money.** `filter`/`select`/`join` build the plan; `count`, `collect`, `first`, `write` execute it. Count the actions in a function and you have counted the source reads.
- **`.cache()` returns the same DataFrame** (it mutates the storage level), which is why `df.cache()` on its own line works. `MEMORY_AND_DISK` spills, so it is safe on the giants. In `read_incremental` the frame stays cached through the caller's write — `bronze_pull` owns the write and cannot unpersist from inside the connector, so Spark evicts at job end.
- **Two independent caches, same reason.** `sap_hana.py` caches the JDBC frame before count/agg/write; `ops.py` caches `folded` because it is consumed **twice** — once filtered to `_kind='H'`, once to `_kind='I'`. Without it the entire receipt fold executes twice.
- **How the delta gets partitioned.** `_incremental_predicates` turns `[watermark, today]` into N contiguous date sub-ranges (`_window_predicates`), one Spark JDBC `predicate` = one connection. The base query still carries `wm > watermark`, so the predicates only *split* rows it already selects — nothing missed, nothing double-counted. The **last sub-range stays open-ended** (R49) so future-dated billing-plan instalments are not truncated.
- **The real incident (R45).** `read_incremental` used to pass no predicates, so every daily delta ran single-connection and `jdbc_hash_partitions` was inert on that path. `sap.zhocidc` blew the 120-minute Glue timeout on four consecutive attempts, the cycle never reached its `download_barrier`, and the ASL retry burned ~10 h of a lane per cycle. The log named it: *"single-partition read with no expected_row_count declared."*
- **More partitions is not better.** MBEW at 16 saturated HANA's connect headroom → *"Cannot connect (socket timeout)"*; tuned to **4** (≈9 M rows per partition). VBRP runs 8, and the spec does the arithmetic: at Map `MaxConcurrency=4` that is 4 × 8 = 32 HANA connections, well under the ~160 ceiling. **Partitions × concurrent tables is the number that matters.**
- **The guard that catches the silent case.** `single_partition_max_rows` (default 5,000,000) fails configuration when a table declares an `expected_row_count` above the threshold and has *no* partitioned read — turning a job that would merely time out into one that refuses to start.
- **`applyInPandas` trade-offs.** Per group: a shuffle, an Arrow serialisation out, a Python process, and an Arrow serialisation back. It buys you arbitrary ordered logic in plain Python. Pay it on the smallest key that still contains all the state, and never on a key whose largest group does not fit in a worker.
- **Reading the symptom.** Job time roughly = *n* × single-read time → a missing cache. One executor busy, the rest idle → skew or a single connection. Stage retries with OOM inside a Python worker → an `applyInPandas` group that is too big.

## Words you'll hear

| Word | What it means here |
|---|---|
| Action | An operation that actually executes the plan (`count`, `write`, `collect`, `first`) |
| Predicate pushdown | Spark hands the `WHERE` to the database; each JDBC `predicate` = one connection |
| Shuffle | Rows moved across the network so related rows share a partition |
| Skew | One partition far bigger than the rest; the stage waits for it |
| Persist / cache | Keep a computed frame so later actions don't recompute it (`MEMORY_AND_DISK`) |
| `jdbc_hash_partitions` | The spec's parallelism degree for a source read |
| Lane | One concurrent slot of the Step Functions Map that runs table downloads |

## In this repo

- [`src/glue/glue_engine/sources/sap_hana.py:1151-1160`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py) — the HIGH-14 comment and `df.cache()`: *"Without this the JDBC pull re-executes once per action — `df.count()`, the `df.agg(F.max())` watermark pass, AND the caller's downstream write."* Same fix at `:1266-1268` (`read_full`) and `:1314-1316` (`read_range`).
- [`sap_hana.py:800-833`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py) — `_incremental_predicates` and the full R45 write-up; `:718-772` — `_window_predicates`, the sub-range builder and the open-upper-bound rule.
- [`sap_hana.py:367-410`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py) — the `single_partition_max_rows` guard; the default lives at `:192`.
- [`src/glue/specs/download/sap_zhocidc.yaml`](../../../tamimi-lakehouse/src/glue/specs/download/sap_zhocidc.yaml) — `jdbc_hash_field: SEQNO`, `jdbc_hash_partitions: "8"`, and the verified PK that justifies both.
- [`src/glue/specs/download/sap_mbew.yaml:33-36`](../../../tamimi-lakehouse/src/glue/specs/download/sap_mbew.yaml) — 16 → 4 with the reason in the comment; [`sap_vbrp.yaml:22-24`](../../../tamimi-lakehouse/src/glue/specs/download/sap_vbrp.yaml) — 8 readers and the 4 × 8 = 32-connection arithmetic.
- [`src/glue/glue_engine/abap/ops.py:86-91`](../../../tamimi-lakehouse/src/glue/glue_engine/abap/ops.py) — the `groupBy(...).applyInPandas(...)` line, `folded.cache()`, and the two filters that consume it twice.

## Do this

1. In `read_incremental`, count the actions between the read and the return. Delete `df.cache()` in your head and state exactly how many times SAP is queried.
2. Take `sap.zhocidc` with `jdbc_hash_partitions: 8` and a 30-day delta. Write out the eight predicates `_window_predicates` produces. Which one is open-ended, and why must it be?
3. Work out the concurrent-connection budget for a cycle: partitions per table × Map `MaxConcurrency`. Which spec would you change first to stay under it?
4. In `basket_op`, remove `folded.cache()` on paper and trace what `_explode_json` triggers for each of the two outputs.

## You've got it when you can…

…look at an unfamiliar Spark function and answer three questions without running it: **how many times does this execute the source read, where is the shuffle, and what is the biggest single group** — then point to the `.cache()`, the predicates and the group key that decide each one.
