# L03 · Partitioning the Giants

> **Module 2 · Lesson 03** · ~45 min

**Slide:** [`_render/L03-jdbc-at-scale.html`](_render/L03-jdbc-at-scale.html)

## The point

A single JDBC connection reading a 36-million-row table is one executor, one socket, one very long wait — and eventually a Glue timeout. The obvious fix is "more connections". The obvious fix has its own wall: **MBEW at 16 partitions could not connect at all.**

The number you want is bounded from below by row volume and from above by how many simultaneous connects the source will accept over the network path you have. This lesson is about finding it, and about the guard that stops you shipping an unpartitioned giant by accident.

## Key ideas

- **On the SAP path, parallelism means date sub-ranges.** `jdbc_hash_partitions: "8"` splits the window into 8 contiguous `BETWEEN` predicates on the watermark column and passes them to `spark.read.jdbc(predicates=[...])` — one JDBC connection per predicate, each pushed down.
- **`jdbc_hash_field` is inert on `sap_hana`.** It is validated and stored, then never read again by that connector; it *is* live on `rds_jdbc`, which passes `hashfield`/`hashpartitions` to Glue's own options. On SAP it documents which PK member you *would* hash. Know this before you "tune" it.
- **`partition_column` + bounds is a real code path with no SAP callers.** No download spec sets it, and `sap_konp.yaml` records why: `KNUMH` is a non-numeric NVARCHAR key, not a valid Spark range-partition column.
- **The knob was inert once, too.** Until TML-70, `jdbc_hash_partitions` was validated and stored but never wired into the read — a full 5-year initial load ran at "Map × 1 connections total" (observed 2026-07-18). R45 later fixed the same gap on the *delta* path.
- **Unpartitioned giants time out, measurably.** `sap.zhocidc`'s single-connection delta blew through the 120-minute Glue job timeout on **four consecutive attempts**; the daily cycle never reached its `download_barrier` and the retry burned ~10 h of a lane per cycle.
- **The guard: declare your size.** If `expected_row_count > single_partition_max_rows` (default **5,000,000**) and no `partition_column` is configured, `configure()` raises before a single row is read. Declare nothing and you get a warning instead — and that warning text is exactly what the R45 job log said.
- **Connections are a shared budget.** `lanes × jdbc_hash_partitions` is the real number of simultaneous connects. VBRP's spec does the arithmetic in a comment: at Map `MaxConcurrency=4`, 8 partitions = 32 connects, safely under the ~160 ceiling.
- **Timeouts are part of the same fix.** The JDBC URL carries `connectTimeout=60000&communicationTimeout=120000` precisely because a 15-second connect budget over the TGW hop saturates when many partitions open at once.

## Words you'll hear

| Term | Means |
|---|---|
| Predicate-partitioned read | `spark.read.jdbc(predicates=[...])` — one connection per WHERE clause |
| `jdbc_hash_partitions` | The count of parallel sub-ranges (a string, per Glue's option contract) |
| `jdbc_hash_field` | The PK member you'd hash on — live for `rds_jdbc`, documentation for `sap_hana` |
| `single_partition_max_rows` | The size above which an unpartitioned read is refused |
| `expected_row_count` | The live-verified row count that lets the guard do its job |
| Connection saturation | Too many simultaneous connects → "Cannot connect to host (socket timeout)" |
| TGW hop | Transit Gateway path from the VPC to on-prem SAP — where the latency lives |
| Lane | One concurrent Step Functions Map branch running a download job |

## In this repo

- [`src/glue/glue_engine/sources/sap_hana.py:718-772`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py) — `_window_predicates`. The docstring records the "Map × 1 connections" observation that motivated it.
- [`src/glue/glue_engine/sources/sap_hana.py:1029-1048`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py) — the predicates branch of `_read`; `:1059-1065` is the `partitionColumn` branch nothing currently uses.
- [`src/glue/glue_engine/sources/sap_hana.py:952-965`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py) — the JDBC URL, and the comment naming **MBEW at `jdbc_hash_partitions=16`** as the read that produced *"Cannot connect to host (socket timeout)"*.
- [`src/glue/glue_engine/sources/sap_hana.py:363-411`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py) — the HIGH-14 guard: the `ValueError` and the fall-back warning.
- [`src/glue/specs/download/sap_mbew.yaml:25-52`](../../../tamimi-lakehouse/src/glue/specs/download/sap_mbew.yaml) — **read every comment in this block.** Why `MATNR` is the hash field, `jdbc_hash_partitions: "4"` *(was 16)*, ≈ 9M rows per partition, and why `expected_row_count: 35,999,963` is the client-100 count and not the 37.2M banner figure.
- [`src/glue/specs/download/sap_vbrp.yaml:22`](../../../tamimi-lakehouse/src/glue/specs/download/sap_vbrp.yaml) — the other direction: 8 partitions, with the `4 × 8 = 32` connect arithmetic spelled out.
- [`src/glue/specs/download/sap_konp.yaml:33-47`](../../../tamimi-lakehouse/src/glue/specs/download/sap_konp.yaml) — a deliberate single-partition read of a 379M-row table, and the raised ceiling that makes it explicit rather than accidental.
- [`src/glue/glue_engine/sources/sap_hana.py:800-824`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py) — R45: the four consecutive 120-minute timeouts on `sap.zhocidc`.

## Do this

Take `sap_mbew.yaml` and compute, for `jdbc_hash_partitions` of 1, 4, 8 and 16: rows per partition, and simultaneous HANA connects at Map `MaxConcurrency=4`. Then say which of those four numbers fails, and *how* each one fails — they do not fail the same way. Check your answer against the comments in `sap_hana.py:959-964` and `sap_vbrp.yaml:22`.

## You've got it when you can…

…read *"Cannot connect to host (socket timeout)"* in a Glue log and immediately ask the right next question — "how many partitions × how many lanes?" — instead of the wrong one, "is the network down?"
