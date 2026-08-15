# L02 · The Engine Doesn't Know What SAP Is ⭐

> **Module 2 · Lesson 02** · ~45 min

**Slide:** [`_render/L02-source-protocol.html`](_render/L02-source-protocol.html)

## The point

The engine has no `if source == "sap"` anywhere. It knows five method names and a dictionary. Everything SAP-shaped — the HANA driver jar, the MANDT client filter, NVARCHAR dates, connection budgets — lives inside `SapHanaConnector` and is invisible from outside it.

That is not tidiness. It is the reason **the next client is a new class, not a new pipeline.** When Apparel Group arrives with Oracle, you write one file, decorate it with `@register("oracle_jdbc")`, add a `source_catalog` row, and the dispatcher, the barriers, the writers, the watermark logic and the run bookkeeping all work unchanged.

## Key ideas

- **The contract is five methods.** `configure` (creds + validation, once per run), `read_full`, `read_incremental`, `read_range`, `emit_metrics`. That is the entire surface an engine-facing source has.
- **`read_incremental` returns the watermark; it never writes it.** The connector hands back `(df, new_watermark)` and the engine persists it *atomically with the run-success record*. A connector that advanced its own watermark could move the marker for a run that then failed to land.
- **A connector may decline a mode.** `read_range` on a full-snapshot source (`excel_landing`) raises `NotImplementedError` — the contract says so explicitly. Declining is part of the interface, not a bug.
- **The registry is a dict populated by import side effects.** `@register("sap_hana")` on the class puts it in `_REGISTRY`; the four side-effect imports at the bottom of `sources/__init__.py` are what make the registry non-empty. Delete that import block and nothing is registered.
- **Both failure modes of the registry are loud.** Registering a name twice raises immediately ("refusing to overwrite"); asking for an unregistered name raises a `KeyError` that *lists everything registered*, which is the fastest debugging aid in the file.
- **`driver_by_mode` chooses per read-mode, not per source.** A table's mapping row can name a different connector for `full`, `range` and `incremental`. Today every SAP mode resolves to `sap_hana` (the OData/ODP CDC path was retired 2026-07-22) — but the seam is still there, and it costs nothing.
- **No entry means fall back to `spec.source_type`.** That is why every non-SAP table needs no `driver_by_mode` at all.
- **`@runtime_checkable`** means `isinstance(conn, SourceConnector)` works — the tests use it to assert a new connector really satisfies the contract before it ever runs in Glue.

## Words you'll hear

| Term | Means |
|---|---|
| `Protocol` | Python structural typing — satisfy the shape, no base class to inherit |
| Registry | `_REGISTRY: dict[source_type -> class]`, filled by decorators at import time |
| Side-effect import | Importing a module purely so its `@register` call runs |
| Read-mode | `full` / `range` / `incremental` — *which* of the connector's read methods runs |
| `driver_by_mode` | Per-table map from read-mode to `source_type` |
| `source_catalog` | The DDB table holding endpoint, `secrets_arn`, `network_config` per source |
| Watermark contract | The connector returns a new value; the engine persists it |

## In this repo

- [`src/glue/glue_engine/sources/protocol.py:18-99`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/protocol.py) — the contract. Read `:59-61` ("do NOT advance the watermark internally") and `:96-98` (`rows_with_errors > 0` → the engine does not advance the watermark) out loud.
- [`src/glue/glue_engine/sources/__init__.py:21-51`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/__init__.py) — `_REGISTRY`, `register`, `get_connector`, `registered_source_types`. The docstring at `:1-8` is the "how to add a source" recipe.
- [`src/glue/glue_engine/sources/__init__.py:57-62`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/__init__.py) — the four side-effect imports that populate the registry.
- The four registered classes: [`sap_hana.py:158`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py), [`rds_jdbc.py:78`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/rds_jdbc.py), [`excel_landing.py:42`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/excel_landing.py), [`landed_files.py:75`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/landed_files.py).
- [`src/glue/glue_engine/sources/excel_landing.py:173-180`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/excel_landing.py) — a connector legitimately refusing a mode.
- [`src/glue/glue_engine/driver_select.py:18-34`](../../../tamimi-lakehouse/src/glue/glue_engine/driver_select.py) — `resolve_driver_source_type`. A pure function with no boto3/pyspark import, so it is unit-testable anywhere.
- [`src/glue/glue_engine/jobs/source_download.py:222-233`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/source_download.py) — read-mode → driver → `get_connector(...)()` → `configure(...)`. Four lines; that is the whole plug-in mechanism at runtime.

## Do this

Sketch `OracleJdbcConnector` for an Apparel Group RMS table — just the class skeleton with the five method signatures and a `source_type` attribute — and list, for each method, the *only* thing that differs from `SapHanaConnector`. Then answer: which files elsewhere in `glue_engine/` would you have to edit to make it run? (Correct answer: one import line in `sources/__init__.py`. Nothing else.)

## You've got it when you can…

…explain to a sceptical colleague why onboarding Oracle needs no change to `source_download.py`, and point at the exact line where the class is chosen by name — and then say what *would* force an engine change (a source that cannot express any of full / range / incremental).
