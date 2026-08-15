# Learning Walkthrough — SAP → Lakehouse Glue Engine
### Phase A (Full Load) · Phase B (CDC) · Phase 3 (ABAP → Glue Transformations)

> **Audience:** the engineering team + the **ABAP developer** (Phase 3 is written for you — it maps your FORMs and FMs to the exact PySpark that replaces them).
> **Branch:** `develop` @ `991646c` · **Region:** eu-west-1 · every claim below is cited to a real `file:line`.
> **How to use:** read Part 1 → 2 for how data gets *in* (the drivers), then Part 3 for how SAP's ABAP logic is *rebuilt* in Glue. Each lesson has **What / Why / Where in code / Watch-out**.

---

> ## ⚠️ SUPERSEDED IN ONE AREA — read before teaching from this
> **The OData/ODP content in Part 2 (Lessons B4 & B5) is now HISTORICAL, not current design.**
> On **2026-07-22** the OData/ODP CDC path was **retired** — `src/glue/glue_engine/sources/sap_odata.py` **no longer exists**, and SAP ingestion is **JDBC-only for every mode** (full, range and incremental). Commits `51b3b9f`, `17a78c8`.
> Keep B4/B5 only as "why we evaluated ODP and why it was dropped". Everything else in this document (Phase A full load, the watermark/`merge_key` CDC mechanics, and all of Phase 3 ABAP→Glue) remains accurate.
> **Current, verified teaching material:** [`../lectures/Module-01-Foundations/`](../lectures/Module-01-Foundations/) and [`../lectures/Module-02-Tamimi/`](../lectures/Module-02-Tamimi/).

## 0. Orientation — the whole pipeline in one picture

```
        SAP HANA (on-prem, via VPN/TGW)                     AWS
   ┌───────────────────────────────┐        ┌───────────────────────────────────────────┐
   │  base tables (MARA, S611,      │        │  RAW (S3)   BRONZE (Iceberg)  SILVER  GOLD │
   │  ZHOCIDC, ZDSALES, …)          │        │                                            │
   └───────────────┬───────────────┘        │   P1            P2          Set 3    dbt    │
                   │                          │  download ──▶ bronze_pull ─▶ abap_ ─▶ … ──▶│
        JDBC (ngdbc.jar)  / OData(ODP)        │  (source_     (merge upsert) transform      │
                   │                          │   download)                 (rebuild ABAP)  │
                   ▼                          └───────────────────────────────────────────┘
   Phase A = full load        Phase B = CDC/incremental       Phase 3 = ABAP→Glue rebuild
```

**Three things to hold in your head before we start:**

1. **P1 / P2 split** (decision-log 2026-07-07). Two Glue jobs per table:
   - **P1 = `source_download`** — the *only* job that touches SAP. Pulls rows over a connector, lands raw Parquet + a `_SUCCESS` marker, and **owns the watermark**. [`jobs/source_download.py`](../../src/glue/glue_engine/jobs/source_download.py)
   - **P2 = `bronze_pull`** — reads the landed cycle back from S3 (zero SAP calls) and writes the Iceberg **Bronze** table with an idempotent MERGE. [`jobs/bronze_pull.py`](../../src/glue/glue_engine/jobs/bronze_pull.py)
2. **One SAP connection, two drivers** ([`driver_select.py`](../../src/glue/glue_engine/driver_select.py)): **JDBC** (`sap_hana`) for full/backfill, **OData/ODP** (`sap_odata`) for CDC. `driver_by_mode` in [`config/ingestion_tables.yaml`](../../config/ingestion_tables.yaml) picks per read-mode.
3. **Everything is spec-driven.** Behaviour lives in YAML specs (`src/glue/specs/{download,bronze,transform}/`), not code. One engine wheel + N YAMLs (ADR-0028). The code is the *engine*; the specs are the *contract*.

**The "9 things we did in Glue" = the 9 transform specs** (Phase 3) — the 9 SAP ABAP objects rebuilt in PySpark, in [`src/glue/specs/transform/`](../../src/glue/specs/transform/): `zsdcc`, `zscc`, `zscc_new`, `scan_611`, `basket`, `id8_product`, `id8_site`, `id8_customer`, `id8_promo`.

---
---

# PART 1 — Phase A: FULL LOAD (the JDBC driver)

### Lesson A1 — What "full load" is, and when it fires
- **What:** a complete snapshot of a SAP base table — **every row, no watermark predicate** — landed to raw S3. In code it's the connector's `read_full` path: `SELECT <cols> FROM <table> [WHERE MANDT='100']` with **no** `wm > …` clause.
- **When it fires (two cases):**
  1. **No-watermark master tables** (MAKT, MARM, MEAN, config tables): no usable change-stamp, so the *only* correct read is a full refresh every cycle. Declared as `driver_by_mode: { full }` only.
  2. **The one-time INITIAL load of every table — giants included.** Policy (recent, and it *reversed* older wording): [`CLAUDE.md:67-71`](../../CLAUDE.md) — *"initial load MUST be a FULL load … never window the initial load by date … giants included; chunked/partitioned to cover FULL history, not truncated to a window."*
- **Why the reversal:** the **Bronze-parity invariant** — a Bronze table's row count MUST equal its SAP table's. A windowed "initial" leaves Bronze < SAP. Observed 2026-07-15: `zdsales`/`zncr01`/`s611` loaded windowed → Bronze < SAP → policy fixed.
- **Watch-out:** [`docs/handoff/SAP-BASE-TABLES.md`](SAP-BASE-TABLES.md) still says "giants — pull date-windowed" in places — that predates the policy and now refers only to *backfill*, not initial load. **The authoritative rule is `CLAUDE.md:67`.**

### Lesson A2 — The driver & mode selection (how the job decides)
Three steps in [`source_download.py`](../../src/glue/glue_engine/jobs/source_download.py):
1. **Force full for full-only masters** (`:163-166`): if the mapping declares only `full` and no `incremental`, `full_snapshot` is set true even if nobody asked — "a full-only table can never take the delta path; an empty watermark dies at the splice guard."
2. **Pick the read mode + connector** (`:173-180`):
   ```python
   read_mode = "range" if date_from else ("full" if full_snapshot else "incremental")
   driver_source_type = resolve_driver_source_type(read_mode, mapping.driver_by_mode, spec.source_type)
   connector_cls = get_connector(driver_source_type)
   ```
3. **Dispatch the read** (`:186-218`): `read_range` (backfill, wm NOT advanced) / `read_full` (full, wm untouched) / `read_incremental` (CDC).

**Precedence:** `--date_from` ⇒ range · else `full_snapshot` ⇒ full · else incremental.
**Full-load-specific rules:** an empty **full** pull **FAILS** (`:223-244`, an empty full extract is almost always broken); an empty **incremental** succeeds. A full snapshot never advances the watermark (`:212`).

### Lesson A3 — The HANA JDBC connector ([`sources/sap_hana.py`](../../src/glue/glue_engine/sources/sap_hana.py))
This is the live SAP path today — HANA read **directly over JDBC** with SAP's custom `ngdbc.jar` (`com.sap.db.jdbc.Driver`), because HANA isn't a native Glue connection type.
- **`read_full` = `read_incremental(watermark=None)`** (`:677-680`) → `_build_query` (`:433-460`) emits a SELECT with no watermark predicate, only the MANDT filter.
- **`.cache()` the pulled frame** (`:641`): it gets 3 actions (`count()`, `MAX()` watermark pass, the write). Without caching, the JDBC pull re-runs 3× = 3× SAP load (HIGH-14 fix).
- **JDBC parallelism** (`:243-274`, applied `:583-596`): `partitionColumn` + `lowerBound`/`upperBound` + `numPartitions` splits `[lb,ub]` into parallel range queries.
- **`single_partition_max_rows` guard** (`:276-324`, default 5M): if a spec declares `expected_row_count` > threshold **and** has no `partition_column`, `configure()` refuses. Unknown size → warn, not block.
- **MANDT client filter** (`:217-241`): SAP application tables are client-dependent; `configure()` refuses a spec with neither `client` nor `client_independent: true`. Prevents test-client (200) rows leaking into facts.
- **Injection defence:** watermark must match `_WATERMARK_PATTERN`; columns allow SAP namespace form `/CWM/…` but are double-quoted; watermark re-checked at splice time even though we wrote it.
- ⚠️ **Live-verify gotcha:** `sap_hana` reads `jdbc_hash_field`/`jdbc_hash_partitions` into fields but **the read path currently keys off `partition_column`, not the hash fields** — specs that set only `jdbc_hash_partitions` (MARA/S611/MBEW) read **single-partition** on HANA today; true parallel partitioning is a documented follow-up (`:197-199`). Contrast RDS (below), where hash fields *do* drive parallelism.

### Lesson A4 — RDS JDBC vs HANA JDBC ([`sources/rds_jdbc.py`](../../src/glue/glue_engine/sources/rds_jdbc.py))
Same `read_full → read_incremental(None)` shape, different mechanics:

| Aspect | `sap_hana` | `rds_jdbc` (Hawkeye/NCR) |
|---|---|---|
| Read API | `spark.read.format("jdbc")` + custom `ngdbc.jar` | `glueContext.create_dynamic_frame.from_options` |
| Creds | Secrets Manager at runtime on executor | `useConnectionProperties=true` (from the Glue Connection) |
| Parallelism | `partitionColumn`+bounds (hash fields stored, unused) | `hashfield`/`hashexpression`+`hashpartitions` |
| Parallelism required? | **Optional** (single-partition default) | **Mandatory** — `configure()` raises without it (`:164-172`) |
| MANDT filter | yes | none (RDS isn't SAP-client-partitioned) |

### Phase A watch-outs (the demo talking points)
1. **`jdbc_hash_partitions` tuned 16→4** — MBEW at 16 threw *"Cannot connect to host (socket timeout)"*; 16 simultaneous connects over the TGW hop exhausted HANA's connect headroom. Cut to 4 (`sap_mbew.yaml:26-29`); same for VBRP (16→4), ZECOM_HDR (8→4). Rule of thumb: ~9M rows/partition. Paired with generous `connectTimeout=60000&communicationTimeout=120000` (`sap_hana.py:506-519`).
2. **Full-only masters use a watermark *placeholder***: they still need a `watermark_column` to satisfy `configure()`, so they point at a PK member (`MANDT`) that is **never spliced** (`sap_makt.yaml:23`).
3. **`merge_key` is NOT in the download spec** — it lives in the P2 **Bronze** spec (governs the upsert, not the pull).

---
---

# PART 2 — Phase B: CDC / INCREMENTAL LOAD (JDBC delta vs OData/ODP)

### Lesson B1 — What CDC means here: the watermark delta
"Incremental / CDC" = **watermark-delta capture**: pull only rows newer than the last persisted watermark.
- **Watermark storage:** a DDB `watermarks` table (not Glue bookmarks), keyed `(source_id, bronze_table)`. Read at `source_download.py:150-151`.
- **The delta predicate** is built inside the connector — `sap_hana._build_query` (`:433-460`): `WHERE <wm_col> > '<watermark>'` (+ MANDT). `watermark=None` ⇒ full pull.
- **Compute + persist the new watermark** — `read_incremental` (`:608-673`) takes `MAX(wm_col)`; the *job* persists it only if it advanced (`bronze_pull.py:298-309`). An empty (quiet) window returns the prior watermark unchanged.
- **Golden rule (the Protocol):** a connector **does NOT advance the watermark itself** — it returns the value and the engine writes it atomically with the run-success record ([`sources/protocol.py:59-61`](../../src/glue/glue_engine/sources/protocol.py)). Also: if `rows_with_errors > 0`, the engine does not advance (`protocol.py:92-99`).

### Lesson B2 — `merge_key` upsert = the anti-duplicate guarantee (idempotency)
The single most important reliability idea. A replay, an overlapping window, or a Glue auto-retry must land each row **once**.
- **Spec declares the natural key** (P2 Bronze spec): `merge_key: [MANDT, DATUM, WERKS]` ([`bronze/sap_zncr01.yaml:18`](../../src/glue/specs/bronze/sap_zncr01.yaml)).
- **Job routes on it** (`bronze_pull.py:289-295`): `merge_key` present → `writer.merge_into(df, key=…)`, else `append`.
- **Writer does an Iceberg MERGE** (`writers/s3_tables.py:193-263`): `WHEN MATCHED UPDATE SET * WHEN NOT MATCHED INSERT *` → re-running the same input keeps the same row count.
- **Real bug this fixed (TML-68):** with plain `append`, `bronze.sap.zncr01` held 446,611 rows vs a 438,645-row source after overlapping loads. MERGE on the PK closed it.
- **Two-hop idempotency:** P1 landing overwrites per `cycle=<id>` (`raw_landing.py`), data files first + `_SUCCESS` last; P2 upserts on the PK. Plus a **delete-aware** MERGE arm (`change_op='D'` → DELETE) for when ODP hard-deletes come online.

### Lesson B3 — JDBC-CDC driver ([`sources/sap_hana.py`](../../src/glue/glue_engine/sources/sap_hana.py))
The **live** interim CDC path.
- **Watermark-column-in-projection guard** (`:354-363`): fail-fast at `configure()` — the watermark column must be in the SELECT list, else `MAX()` can't compute the next watermark.
- **SAP dates are `NVARCHAR 'YYYYMMDD'`** → `watermark_date_format: YYYYMMDD` strips dashes; comparison is lexicographic.
- **Hardening — "harden sap_hana watermark advance"** (commit `ee3b0b8`, `:656-665`): never persist a watermark you'd later refuse to splice. A dirty date column can produce a text `MAX` like `'S'` (sorts after digits) that would wedge every future cycle; the code keeps the prior watermark and lets the idempotent MERGE re-pull the delta — no loss.
- ⚠️ **JDBC delta is inserts/updates-only — it MISSES hard deletes.** Accepted as an interim (`config/ingestion_tables.yaml:46-51`). Deletes only return with ODP.

### Lesson B4 — OData/ODP driver ([`sources/sap_odata.py`](../../src/glue/glue_engine/sources/sap_odata.py))
The ADR-0029 target path — Glue's native `SAPOData` connector over SAP **ODP** (Operational Data Provisioning). **Code-complete but dormant** (see B5).
- **Transport:** SAP application/Gateway ODP-OData over ICM HTTPS (44300), not the HANA DB directly.
- **Delta = opaque ODP delta token** (not `MAX(col)`): the watermark *is* a token like `D20241107043437_000463000`, managed by AWS's `sap_odata_state_management`. Pattern (`:394-508`): get token → `ENABLE_CDC=true` + `DELTA_TOKEN` into `from_options` → persist the new token.
- **Hard deletes:** ODP surfaces a change-mode column → `_change_op` (I/U/D) (`:359-374`) → feeds the delete-aware Bronze MERGE. **This is the main reason to prefer ODP.**
- **Token expiry:** if the delta queue reorged/expired → typed `ExpiredDeltaTokenError`; `source_download` flips `init_state=needs_reinit` and the dispatcher auto re-baselines via a fresh JDBC initial load — no loss (HANA holds base state).
- **No backfill:** `read_range` is `NotImplementedError` for OData — backfills use JDBC.

### Lesson B5 — JDBC vs OData/ODP: the decision table

| Dimension | JDBC — `sap_hana` | OData/ODP — `sap_odata` |
|---|---|---|
| Transport | Direct HANA over JDBC (`ngdbc.jar`) via TGW | SAP Gateway ODP-OData over ICM HTTPS 44300 |
| Delta mechanism | Watermark predicate `wm > MAX`; stored in DDB | ODP **delta token** (`ENABLE_CDC`, `DELTA_TOKEN`) |
| Read modes | full · range(backfill) · incremental | full · incremental (**no range**) |
| **Hard deletes** | ❌ no (insert/update only) | ✅ yes (`_change_op='D'` → delete MERGE) |
| Failure/reset | keeps dirty watermark, idempotent re-pull | expired token → `needs_reinit` → auto re-baseline |
| SAP-side dependency | HANA SQL + subnet route (**works today**) | Basis must publish ODP services + grant auths |
| **Status** | **LIVE** (interim CDC on all enabled tables) | **Registered but dormant** — gated off |

**The blocking item (raise at the demo):** [`TICKET-sap-basis-odp-service-publication.md`](TICKET-sap-basis-odp-service-publication.md) — ICM port open + Glue SAPOData connection validates `READY`, **but the SAP catalog exposes only Fiori/UI services; there are no ODP extraction services** to subscribe to. Needs Basis to publish ODP-OData (RSO2 generic-delta / LBW0 for LIS S603/S611) + grant `NBUSER1` the `S_RO_OSOA`/`S_RFC(RODPS_REPL)`/`S_SERVICE` auths + ODQMON retention ≥ 7 days. Plan: flip tables to OData CDC one at a time, **`zncr01` first as pilot**.

### Phase B watch-outs
1. **Non-date watermarks → full refresh** (commit `cbfa266`): a live daily fire failed 24/32 tables with *"refusing to splice watermark ''"* — their `watermark_column` is a constant/non-date PK member. Fix: declare `driver_by_mode: { full }` for the 27 non-date tables; the 14 genuine date facts keep `incremental`.
2. **ULID `run_id`** (`dispatcher/handler.py:188-194`): a 26-char monotonic ULID per table per cycle, stamped into every Bronze row as `_run_id`, threaded P1→P2 so barriers conclude a cycle deterministically.
3. **`ZHOCIDC` Bronze spec is missing its `merge_key`** and is `enabled: false` — the one PK-contract gap (SAP-BASE-TABLES §7).

---
---

# PART 3 — Phase 3: ABAP → GLUE TRANSFORMATIONS  ⭐ (the deep part)

> **ABAP developer — this part is for you.** We rebuilt your extractor/QuickView logic in PySpark. Below, each SAP object is shown next to the exact Glue op that replaces it, so you can check the logic line-for-line.

### Lesson T1 — The core idea: we do NOT pull derived objects from SAP
Some SAP "sources" are **not physical tables** — they are SQVI QuickViews, LIS reports, and RFC extractors whose logic lives in the **ABAP layer** and is **absent from the HANA SQL catalog** (proven via `SYS.VIEWS`/`DD25L`/`DDDDLSRC`). HANA SQL can read neither their data nor their logic. See [`SAP-DERIVED-TABLES.md`](SAP-DERIVED-TABLES.md).

**So the contract is:** *SAP builds these with ABAP over its own base tables; we re-implement that ABAP in PySpark against the **Bronze copies** of the same base tables, and land the result in **Silver**.* We never ingest a derived object; reading one to *verify* a rebuild is fine, ingesting one is not.

```
Bronze base tables (ZDSALES, ZNCR01, ZHOCIDC, MARA, MEAN, …)
        │   abap_transform Glue job  +  transform/*.yaml spec
        ▼
Silver derived tables (sap.zsdcc, sap.zscc, sap.basket, sap.id8_product, …)
```

The **9 transform specs** = the 9 rebuilt objects: `zsdcc`, `zscc`, `zscc_new`, `scan_611`, `basket`, `id8_product`, `id8_site`, `id8_customer`, `id8_promo`.

### Lesson T2 — The transform engine (how a spec becomes a table)
[`jobs/abap_transform.py`](../../src/glue/glue_engine/jobs/abap_transform.py) is a **thin Spark driver**; the correctness lives in pure, unit-tested cores.
- Reads each `inputs` FQN from the **Bronze** federated catalog (`_read_bronze`, `:52-55`).
- Looks up the op by name (`get_transform(spec.op)`, `:120`) and runs it: `op(spark, inputs, spec.params)` (`:121`).
- Writes the result to **Silver** via `full_refresh` — derived tables are **rebuilt in full**, so the job is idempotent (`_write_derived`, `:58-79`).
- Records a `runs` row with `stage="abap_transform"` for the transform barrier (`:103-149`).

An op is registered with `@register_transform("<name>")` and returns **one DataFrame** (→ `spec.table`) **or a dict** of FQN→DataFrame (the basket op emits `sap.basket` + `sap.basket_item` from one fold). Registry lives in [`abap/ops.py`](../../src/glue/glue_engine/abap/ops.py).

**The YAML spec = the ABAP's selection screen + join, as config.** Example [`transform/zsdcc.yaml`](../../src/glue/specs/transform/zsdcc.yaml):
```yaml
table: sap.zsdcc
op: flat_join
inputs: [sap.zdsales, sap.tvkmt]
params:
  left: sap.zdsales
  right: sap.tvkmt
  right_where: "SPRAS = 'E'"     # REQUIRED — see T3 fan-out
  right_select: [KTGRM, VTEXT]
  "on": ["KTGRM"]
```

### Lesson T3 — The simple ops, and the fan-out trap every ABAP dev must see
**`flat_join` — `ZSDCC` = `ZDSALES ⋈ TVKMT` on `KTGRM`** (`ops.py:81-107`). This is your SQVI QuickView `ZDEPTCUSTCOUNT` (decompiled `1BCDWB_LIQ000000001440U02.abap`): `LC = ZDSALES.ZAMT_SOLD` verbatim, dept text = `TVKMT.VTEXT`. No aggregation.

> 🔴 **The fan-out trap (your QuickView's `SPRAS` filter is load-bearing).** `TVKMT` is **language-keyed** (PK `MANDT, SPRAS, KTGRM`). `KTGRM` is unique only *within* a language slice. In Bronze (client 100), TVKMT has `SPRAS='E'` (43 depts) + `SPRAS='A'` (43) + `SPRAS='D'` (3). Joining on `KTGRM` **alone** matches the English AND Arabic row → **doubles every sales row → doubles LC and CC.** The QuickView carried `TVKMT~SPRAS in <sel>` on its selection screen; in Glue that becomes `right_where: "SPRAS = 'E'"`. This is the same class of bug that was fixed in dbt (the `TVKMT language fan-out doubling zsdcc`, commit `31ab979`). **Whenever you port a join to a text/language table, filter `SPRAS` first.**

**`project` — `ZSCC` = flat read of `ZNCR01`** (`ops.py:110-124`): your QuickView `ZCUSTCOUNT` (`SELECT DATUM WERKS ZCUSTOMER ZITEM FROM ZNCR01`) — single table, rename + select, no join, no aggregation.

### Lesson T4 — The ID8 extractor ops (your `ZRFC_ID8_DATA_EXTRACT`, FG `SAPLZID8`)
The extractor's dispatcher (`LZID8U01`) routes `EXTRACT_TYPE` to 6 FORMs. We rebuilt them as ops. Full field-map: [`docs/ABAP/ID8-EXTRACTOR-MAPPING.md`](../ABAP/ID8-EXTRACTOR-MAPPING.md).

| ABAP `EXTRACT_TYPE` / FORM | Glue op (`ops.py`) | Notes |
|---|---|---|
| `SITE` / `get_sites` (F02) | `id8_site` (`:127-164`) | `ZNCRSITE ⟕ T001W ⟕ WRF1` on `werks`; **`store_type` derived from the WERKS prefix**, not a lookup — `resolve_store_type` |
| `CUST` / `get_customers` (F04) | `id8_customer` (`:167-202`) | `ZTLC_CUST_MAST` (active) ⟕ `DD07T` domain `ZSEGMENT` text; `emailable = NEWSLETTER='X'?'Y':'N'` |
| `PROMO` / `get_promotions` (F05) | `id8_promo` (`:205-263`) | UNION of NCR digital (`ZNCR_DP_HDR STATUS='A'`) + IS-Retail (`WAKH ⟕ WAKT`, `VKGST in A,B`), dedup by `(bukrs, promotion_id)` via `row_number` |
| `PROD` / `get_products` (F01) | `id8_product` (`:430-527`) + `_material_attrs` (`:266-427`) | `MARA × MEAN × MARM` + 9-table attribute lookups; `strip_maktg` → `parse_pack_size`; 3-tier supplier fallback |

**Two porting subtleties in `id8_product` your team should know (both disclosed in the docstrings):**
1. **Sequential work-area artifact NOT reproduced** (`:448-455`): the ABAP's `w_umrez` can carry a **stale** value from a *previous* material's loop iteration when its own MARM lookup misses. That's a sequential side-effect; a set-based Spark join can't (and shouldn't) reproduce it — we return `null` instead. Cleaner, not a hidden bug — but **numbers will differ where the ABAP leaked a stale ratio.**
2. **MEAN gap-fill** (`:469-486`): the ABAP loops MEAN and synthesises a row for the base unit (`MEINS`) / order unit (`BSTME`) when no barcode row exists — reproduced with a `left_anti` join so **real MEAN rows always win** over synthetic ones.
3. **Supplier 3-tier fallback** (`:385-408`): `EINA⋈EINE` with progressively looser `loekz`/`relif` filters (LZID8F01 lines 276-338), implemented as tag-union + `row_number` priority (avoids null-unsafe chained outer joins).

### Lesson T5 — The pure ABAP helpers (your FMs, decompiled) — [`abap/helpers.py`](../../src/glue/glue_engine/abap/helpers.py)
These are pure functions (no Spark) so the correctness-critical FMs are unit-tested:

| SAP FM / logic | Glue helper | What it does |
|---|---|---|
| `ZBA_JEM_ENCRYPT.encode_customer` | `encode_customer` (`:12-26`) | Loyalty `CUSTNO` = **Base64(UTF-8 mobile)** — `SCMS_STRING_TO_XSTRING → SCMS_BASE64_ENCODE_STR`. Deterministic, no salt → reproduces SAP's id **without any write-back to SAP** ⚠️ reversible, so it's a *join key*, not PII masking (M-22) |
| `ZMM_GET_RETAIL_WITH_TAX` op 'M' | `vat_split` (`:38-48`) | `excl = incl/(1+rate)`; **`TAKLV=0` ⇒ exempt (excl=incl)** — data-driven rate, **not a flat ÷1.15** |
| `get_sites` WERKS-prefix rule (LZID8F02) | `resolve_store_type` (`:51-105`) | `dim_site.store_type` derived purely from the plant code shape (E*→EXPRESS, V*→CNC, G*→HORECA, S305/306→QCOMMERCE, …) |
| `strip_maktg` (LZID8F01 199-275) | `parse_pack_size` (`:108-181`) | Splits a trailing pack-size token off `MAKTG`, normalises the unit via `ZMM_UOM_DICT` — a **byte-for-byte offset-scan port**, off-by-one and all (parity over "correctness") |

> 💡 For the ABAP dev: `parse_pack_size` deliberately keeps the source's right-justified fixed-buffer scan (offset 39→1, offset 0 never inspected) so the output **matches what SAP actually emits**, not a "cleaned-up" version. If your `strip_maktg` had a quirk, ours has the same quirk on purpose.

### Lesson T6 — The hardest port: the `ZHOCIDC` basket state machine
This is your `process_sold_articles` (LZID8F03) — a **per-receipt state machine**, not a relational join. [`abap/baskets.py`](../../src/glue/glue_engine/abap/baskets.py) is a faithful pure-Python port; [`ops.py:27-68`](../../src/glue/glue_engine/abap/ops.py) is the Spark adapter.

- **Why a state machine:** `ZHOCIDC` is a flat POS end-of-day log where each row's meaning depends on its record type `ZTRNTYPE` (`H`=header, `S`=sale line, `T`=tender, `F`=footer/commit, plus deferred `C/W/K/G/D/y`), and the generic fields `ZVARID1..4`/`ZCODE1..3` are reinterpreted per type. You must scan rows **in `SEQNO` order within a receipt** — a set-based join cannot do this.
- **How Spark runs a per-receipt fold** (`ops.py:56-63`):
  ```python
  folded = zhocidc.groupBy("werks","budat","zptno","zreceipt").applyInPandas(_fold, schema=out_schema)
  # _fold: rows.sort_values("seqno") → build_baskets(rows) → tag 'H'/'I' rows
  ```
  `applyInPandas` hands each receipt's rows to the **pure** `build_baskets`, which is unit-tested on golden rows independent of Spark.
- **ABAP ↔ Python, record-type by record-type** (`baskets.py:93-182`):

  | `ZTRNTYPE` | ABAP behaviour | `build_baskets` |
  |---|---|---|
  | `H` | new basket; `basket_id='20'+ZDATE+ZPTNO+ZRECEIPT`; `posting_date=BUDAT-1`; `zcode1='3'`→skip training | `:96-115` |
  | `S` | sale line only when `zcode1='1'` & amount≠0; amount=`ZVARID4+9(9)/100`, qty from `ZVARID4(8|4)` by decimal marker, sign from `ZVARID3`; EAN from `ZVARID2` (synthetic if ≤2 chars) | `:117-160` |
  | `T` | `tender_type` from `ZVARID4(2)`; 2nd tender → "Multiple Tender" | `:162-170` |
  | `F` | commit: drop zero-price items, roll up basket amounts | `:172-182` + `_commit` `:76-91` |

  Per-item VAT is applied via `vat_split` using `TAKLV` (`:157-159`); `BASKETAMOUNT{EXCL,INCL}TAX` = SUM over kept items.
- ⚠️ **Scope of the port (disclosed):** the **offline happy path** (H/S/T/F) is done and TDD'd. **Deferred** (own follow-up ops + golden tests, all mapped in the ABAP doc): markdown/discount `C`, weight items (`check_item_if_by_weight`), external-vendor EAN remap (`ZMM_BULKFOOD`/`ZMM_EXTVEN`), points `G`, promo code `K`, B2B `y`, and the eCommerce (`process_ecom_sold_articles`) / bulk (`process_bulk_sold_articles`) paths.

### Lesson T7 — What's done vs blocked (be honest at the demo)
| Object | Status | Note |
|---|---|---|
| `zsdcc` (flat_join) | ✅ spec written, **unblocked 2026-07-15** (TVKMT now ingested) | the `SPRAS='E'` fan-out fix is in the spec |
| `zscc` (project) | inputs ready; spec present (`zscc.yaml`/`zscc_new.yaml`) | ZNCR01 flat read |
| `id8_site / customer / promo / product` | ✅ ops implemented | full-batch rebuild; CDHDR/CDPOS CDC gate & day-window **not** applied (documented) |
| `basket` (state machine) | ✅ offline happy-path ops + pure core | deferred arms per T6 |
| **`scan_611` / `distress_603`** | 🔴 **BLOCKED — ABAP logic NOT recovered** | the LIS report logic (`ZMCS611`/`S603`) was never read. **Do NOT write these specs from column names or Excel output — a guessed transform silently produces wrong numbers** (SAP-DERIVED-TABLES §5). Retrieve the ABAP from SAP first. |
| PII / `encode_customer` | reversible Base64 (join key), masked at Lake Formation | not a PII control (M-22) |

> **The one honest gap to say out loud:** the base tables for `scan_611`/`distress_603` are ingested, but their **report logic has never been retrieved from SAP** — so those two rebuilds are intentionally *not* written. That's the outstanding SAP-source item for the ABAP team.

---
---

## Appendix — file map & glossary

**Engine (code):**
- P1 download: [`jobs/source_download.py`](../../src/glue/glue_engine/jobs/source_download.py) · P2 bronze: [`jobs/bronze_pull.py`](../../src/glue/glue_engine/jobs/bronze_pull.py) · transform: [`jobs/abap_transform.py`](../../src/glue/glue_engine/jobs/abap_transform.py)
- Connectors: [`sources/sap_hana.py`](../../src/glue/glue_engine/sources/sap_hana.py) (JDBC) · [`sources/sap_odata.py`](../../src/glue/glue_engine/sources/sap_odata.py) (ODP) · [`sources/rds_jdbc.py`](../../src/glue/glue_engine/sources/rds_jdbc.py) · [`sources/protocol.py`](../../src/glue/glue_engine/sources/protocol.py)
- Driver select: [`driver_select.py`](../../src/glue/glue_engine/driver_select.py) · writer/MERGE: [`writers/s3_tables.py`](../../src/glue/glue_engine/writers/s3_tables.py)
- ABAP layer: [`abap/ops.py`](../../src/glue/glue_engine/abap/ops.py) · [`abap/baskets.py`](../../src/glue/glue_engine/abap/baskets.py) · [`abap/helpers.py`](../../src/glue/glue_engine/abap/helpers.py)

**Specs:** `src/glue/specs/download/*.yaml` (P1) · `src/glue/specs/bronze/*.yaml` (P2, carry `merge_key`) · `src/glue/specs/transform/*.yaml` (Phase 3) · `config/ingestion_tables.yaml` (`driver_by_mode`)

**Docs:** [`SAP-BASE-TABLES.md`](SAP-BASE-TABLES.md) · [`SAP-DERIVED-TABLES.md`](SAP-DERIVED-TABLES.md) · [`../ABAP/ID8-EXTRACTOR-MAPPING.md`](../ABAP/ID8-EXTRACTOR-MAPPING.md) · [`../ABAP/ZSDCC.md`](../ABAP/ZSDCC.md) · [`../ABAP/ZSCC.md`](../ABAP/ZSCC.md) · [`TICKET-sap-basis-odp-service-publication.md`](TICKET-sap-basis-odp-service-publication.md) · decompiled ABAP in [`../ABAP/src/`](../ABAP/src/)

**Glossary:** *P1/P2* = download / bronze-load jobs · *watermark* = last-loaded delta marker (DDB) · *merge_key* = natural PK for the idempotent Bronze MERGE · *ODP* = SAP Operational Data Provisioning (server-side CDC) · *driver_by_mode* = per-read-mode connector map · *ULID* = 26-char sortable run id · *derived object* = ABAP view/report/extractor rebuilt in Glue (never pulled).

---
*Prepared for the code-walkthrough session. Phase 3 is the deep one — bring the ABAP dev to Lessons T3–T7.*
