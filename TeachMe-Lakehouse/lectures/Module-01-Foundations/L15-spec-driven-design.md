# L15 · Spec-Driven Design — One Engine, N YAML Files ⭐

**Slide:** [`_render/L15-spec-driven-design.html`](_render/L15-spec-driven-design.html)

## The point

We ingest 58 source tables and we did **not** write 58 jobs. We wrote **one engine** and **145 spec files**. A spec is a YAML document that declares *what* a table is — its source, its key, its watermark, its columns — and the engine works out *how*. Adding table #59 is a pull request against a directory of data, not a new script, not a new Terraform resource, not a deployment.

## Key ideas

- **The spec is a contract, not a config file.** It is the single source of truth for a table's schema and load behaviour, it lives in git, and it is reviewed as data — 30 declarative lines instead of 200 lines of near-duplicate Python.
- **Config vs code.** Anything that varies per table (schema, keys, parallelism, watermark) is config. Anything that is the same for every table (JDBC read, typing, dedup, Iceberg MERGE, audit columns, watermark advance) is code, written once.
- **One job per table is the failure mode we avoided.** 145 near-identical scripts drift: one gets a bug fix, the other doesn't. With one engine, a fix lands everywhere at once — and a regression is equally global, which is why the engine is the thing that carries the tests.
- **The spec is validated, not just parsed.** Pydantic models with `extra="forbid"` mean a typo'd key is an *error*, not a silently ignored line. Cross-field validators refuse specs that would corrupt data: a `merge_key` naming a column that isn't in the schema, a `pii_class: pii` column used as a merge key (masking runs before the write, so the key would stop matching SAP), a `landing_prefix` on the wrong kind of spec.
- **The fields that matter.** `schema` (the column contract, types + `pii_class`), `watermark_column` (pull only the delta), `merge_key` (the natural key for the Iceberg upsert), `jdbc_hash_partitions` (parallel readers for the JDBC pull).
- **One line can be worth thousands of rows.** `bronze.sap.zncr01` held 446,611 rows against a 438,645-row source after overlapping appends. Adding `merge_key: [MANDT, DATUM, WERKS]` to the Bronze spec turned the append into an upsert and stopped the duplication — a data-correctness fix delivered as config.
- **This is what makes the architecture portable.** Next engagement, 8 Oracle sources: new connector class, same engine, new YAML. The spec shape is the reusable asset.

## Words you'll hear

| Word | What it means here |
|---|---|
| Spec | One YAML file describing one table |
| Spec-driven / meta-design | Designing the *description format*, then one engine that reads it |
| Watermark | The column that says "what changed since last time" |
| Merge key | The natural key the Iceberg `MERGE` upserts on |
| Hash partitions | How many parallel JDBC readers pull the table |
| `extra="forbid"` | Pydantic setting that turns an unknown key into an error |
| P1 / P2 spec | Download spec (source → raw S3) vs load spec (raw → Bronze) |

## In this repo

- [`src/glue/specs/download/sap_mara.yaml`](../../../tamimi-lakehouse/src/glue/specs/download/sap_mara.yaml) — a complete P1 spec: `table`, `source_type: sap_hana`, `jdbc_schema`/`jdbc_table`, `watermark_column: LAEDA`, `jdbc_hash_field: MATNR`, `jdbc_hash_partitions: "8"`, `landing_prefix`, and the 16-column `schema` block with `pii_class` per column.
- [`src/glue/specs/bronze/sap_zncr01.yaml:18`](../../../tamimi-lakehouse/src/glue/specs/bronze/sap_zncr01.yaml) — `merge_key: [MANDT, DATUM, WERKS]`, with the comment recording the 446,611-vs-438,645 duplication it fixed.
- [`src/glue/glue_engine/spec.py`](../../../tamimi-lakehouse/src/glue/glue_engine/spec.py) — `BronzeSpec`, `SilverSpec`, `TransformSpec`. Validators at `:188-201` (merge_key ⊆ schema), `:203-223` (no PII merge key), `:225-259` (P1-vs-P2 spec shape).
- `src/glue/glue_engine/` — the four jobs that consume all of it: `source_download`, `bronze_pull`, `bronze_to_silver`, `abap_transform`.
- Spec counts today: **58** download · **67** bronze · **6** silver · **14** transform.

## Do this

1. Read `sap_mara.yaml` top to bottom, then `sap_zncr01.yaml`. List every field that differs and decide, for each, whether it is config or code.
2. Open `spec.py` and find `_validate_pii_not_merge_key`. Read the docstring — it explains a data-corruption bug that can no longer be written.
3. Write (don't deploy) a download spec for a new SAP table: pick the watermark column, the hash field, and the merge key. Have a neighbour try to break it.
4. Try adding an unknown key like `parallelism: 8` and predict what Pydantic does.

## You've got it when you can…

…be handed one Oracle table from the next client and produce its download + bronze spec YAML from scratch, correctly choosing the watermark column, the merge key and the partition count — and explain why that is the whole job, with no new code to write and nothing to deploy.
