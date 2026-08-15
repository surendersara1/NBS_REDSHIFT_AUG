# L01 · Anatomy of the Engine

> **Module 2 · Lesson 01** · ~45 min

**Slide:** [`_render/L01-engine-anatomy.html`](_render/L01-engine-anatomy.html)

## The point

`glue_engine/` is not a folder of scripts. It is four **seams** — spec, connector, writer, control plane — and a set of jobs whose only work is to wire them together in the right order. Once you can name the seam a failure came from, you know which file to open. Module 1 showed you the map; this is the machine room.

The claim to test all module long: **there is no per-table Python.** 58 P1 download specs and 67 Bronze specs, one wheel, zero per-table classes. Adding the next table is a YAML file and a DynamoDB row.

## Key ideas

- **SPEC — what the table *is*.** The YAML in `src/glue/specs/` is parsed into a Pydantic model, and a bad spec is rejected *before* Spark starts: a `merge_key` naming a column that isn't in the schema, or a `pii_class: pii` column used as a merge key, raises at parse time rather than corrupting an upsert three hours later.
- **CONNECTOR — where the rows come *from*.** One `Protocol`, four implementations. The engine never imports a concrete connector; it asks a registry for one by name (L02).
- **WRITER — where the rows go *to*.** Two of them: P1 lands raw Parquet under `cycle=<cycle_id>/` and writes `_SUCCESS` **last**, so a partial cycle never looks finished; P2 MERGEs into an Iceberg table in S3 Tables.
- **CONTROL PLANE — what actually *happened*.** Every read and write of DynamoDB goes through a Pydantic model, in both directions. Reads validate too — that is what catches DDB drift instead of letting a renamed attribute silently read as `None`.
- **The job is the wiring, not the logic.** `source_download.py` resolves the mapping, parses the spec, asks for a connector, calls one of three read methods, writes, then records. Everything interesting is behind one of the four seams.
- **Seams are where you extend, and where you debug.** "Empty landing folder" is a writer/connector question. "Refusing to splice watermark" is a connector question. "Table not admitted to today's cycle" is a control-plane question.
- **Why pluggable at all:** the same wheel has to serve SAP HANA, an RDS SQL Server, a spreadsheet in S3, and — next — whatever Apparel Group runs. Anything table-specific that leaks into the engine is a bug you pay for once per client.

## Words you'll hear

| Term | Means |
|---|---|
| Seam | A boundary the engine can swap an implementation across without changing callers |
| Spec | The per-table YAML: schema, source config, merge key, landing prefix |
| Connector | The class that knows how to read one *kind* of source |
| Writer | The component that persists a DataFrame (raw Parquet, or Iceberg MERGE) |
| Control plane | The DynamoDB tables that record routing, progress and outcome |
| P1 / P2 | Download-to-raw (P1) and load-raw-to-Bronze (P2) — the two halves of ingestion |
| `_SUCCESS` | The marker written *last*, that makes a landed cycle readable by P2 |

## In this repo

- [`src/glue/glue_engine/spec.py:97`](../../../tamimi-lakehouse/src/glue/glue_engine/spec.py) — `BronzeSpec`. Read the three `@model_validator`s at `:189`, `:204`, `:226`: each one is a real class of bug that can no longer reach production.
- [`src/glue/glue_engine/sources/protocol.py:18`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/protocol.py) — the whole connector contract, 100 lines including docstrings.
- [`src/glue/glue_engine/writers/raw_landing.py:152`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/raw_landing.py) — `write_raw`: data files first, marker last, and it propagates *without* a marker on failure.
- [`src/glue/glue_engine/writers/s3_tables.py:193`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/s3_tables.py) — `merge_into`, the Bronze upsert that makes replays idempotent.
- [`src/glue/glue_engine/control_plane.py:109`](../../../tamimi-lakehouse/src/glue/glue_engine/control_plane.py) — `put_run`, and note the `exclude_none=True` comment: a `None` on a GSI key attribute would make DynamoDB reject the write outright.
- [`src/glue/glue_engine/jobs/source_download.py:133-366`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/source_download.py) — the five calls on the slide, in order.
- [`src/glue/glue_engine/__init__.py:3-9`](../../../tamimi-lakehouse/src/glue/glue_engine/__init__.py) — the three-step "add a table" recipe, written by the people who built it.

## Do this

Open `jobs/source_download.py` and, without reading the rest of the module, annotate every line between `try:` (`:131`) and the final `put_run` (`:366`) with which of the four seams it touches — spec, connector, writer, or control plane. You should be able to account for every line. Then find the one block that belongs to *none* of them (hint: it is around `:205`, and it is a policy decision) — that is L05.

## You've got it when you can…

…be told "`sap.mbew` produced no `_SUCCESS` marker for cycle 2026-08-09" and say which seam you would open first, and why the *absence* of the marker is itself the diagnostic.
