# L16 · SAP → RAW: Land It, Don't Touch It

**Slide:** [`_render/L16-sap-to-raw.html`](_render/L16-sap-to-raw.html)

## The point

The first hop is the one where you do **nothing**. P1 (`source_download`) opens one JDBC connection to SAP HANA, reads the rows it is allowed to read, and writes them to S3 as Parquet — byte-for-byte, no types, no renames, no business rules. The only thing that changes is *where the bytes live* and *which cycle folder they live in*. Everything downstream can then be rebuilt from those files without ever asking SAP again.

## Key ideas

- **Raw exists so you can replay.** A bug in Bronze, Silver or Gold costs a re-run over files you already have — not another extract window, not another conversation with the SAP team.
- **Raw exists so you can prove.** When a number is disputed, raw is the evidence of exactly what the source returned that day. It is versioned, Glacier-tiered and held for seven years, and it is never edited or deleted.
- **Three read modes, one connector.** Full load (`read_full`), watermark delta (`read_incremental`), and a bounded date window (`read_range`) for backfills and chunked initial loads. The mode is chosen per run, from config — not by editing code.
- **JDBC reads are partitioned on purpose.** `jdbc_hash_partitions: 8` splits one logical read into eight parallel connections. A table declaring `expected_row_count` above `single_partition_max_rows` and *no* partitioned read is **refused at configure time** — a one-executor read of 638 M rows OOMs or times out.
- **`_SUCCESS` is the commit.** Data files are written first, the marker last. If the job dies mid-write there is no marker, and the P2 reader refuses the prefix. A half-written cycle can never look "done".
- **The MANDT filter is not optional.** SAP tables are partitioned by client; without `WHERE MANDT = '100'` you silently ingest the test client's rows into your facts. The connector raises unless a spec supplies `client` or declares `client_independent: true`.
- **The one thing raw does add:** four audit columns (`_source_system`, `_source_table`, `_ingested_at`, `_run_id`) plus `_watermark_valid`, stamped on the way past so every row can be traced back to the run that fetched it.

## Words you'll hear

| Word | What it means here |
|---|---|
| P1 | The download half of the pipeline — the only code that talks to SAP |
| Cycle | One dated run of the pipeline; raw is partitioned as `cycle=<id>` |
| `_SUCCESS` | The marker object that says "this cycle is complete and readable" |
| Watermark | The high-water value (e.g. a date) marking where the last read stopped |
| MANDT | SAP's client field — which company/environment a row belongs to |
| Partitioned read | Splitting one JDBC read into N parallel range/hash queries |
| Landing prefix | The relative S3 path a table lands under, qualified at runtime |

## In this repo

- [`src/glue/glue_engine/jobs/source_download.py`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/source_download.py) — the whole P1 job: resolve spec → pick read mode → call the connector → `write_raw` → advance the watermark.
- [`src/glue/glue_engine/sources/sap_hana.py:305-361`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py) — the MANDT productive-client filter (G02) and the partitioned-read configuration (G01), with the safety threshold right below at `:363-411`.
- [`src/glue/glue_engine/writers/raw_landing.py`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/raw_landing.py) — `resolve_landing_base`, `write_raw`, the marker-last ordering, and `_assert_single_write` (two overlapping Spark writes under one prefix = hard failure, with the live 749 M-vs-679 M row incident in the docstring).
- [`src/glue/specs/download/sap_zncr01.yaml`](../../../tamimi-lakehouse/src/glue/specs/download/sap_zncr01.yaml) — a complete download spec: `client: "100"`, `watermark_column: DATUM`, `safety_buffer_days: 7`, `jdbc_hash_partitions: "8"`, `landing_prefix`.

## Do this

1. Open `sap_zncr01.yaml` and `sap_s611.yaml` side by side. Find every field that differs, and say out loud what each one changes about the read.
2. In `source_download.py`, trace the three branches that pick `read_range` / `read_full` / `read_incremental`. Which job arguments decide it?
3. In `raw_landing.py`, delete (mentally) the `_assert_single_write` call and describe the failure it would let through.
4. List a landed cycle prefix in S3 and find the `_SUCCESS` object. Open it — it is a JSON manifest, not an empty file.

## You've got it when you can…

…explain why a bug found in Gold on a Tuesday does **not** require a new extract from SAP, and point at the exact two lines of `write_raw` that guarantee a crashed job never leaves a cycle that looks complete.
