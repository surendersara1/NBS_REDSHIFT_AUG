# L05 · Why Parquet, Not CSV
> **Module 1 · Lesson 05** · ~45 min

## The point
Same rows, different byte order: CSV writes a whole row then the next row, Parquet writes a whole column then the next — and that single choice is what makes 638 M rows queryable.

## Key ideas
- **Row layout (CSV):** `SPTAG, MATNR, MATKL, KUNAG` for record 1, then all four again for record 2. Columns are interleaved, so you cannot read one without reading all of them.
- **Column layout (Parquet):** every `SPTAG` value together, then every `MATNR`, then every `MATKL`. Each block is a **column chunk**.
- **Compression:** values of the same type and similar range sit next to each other, so dictionary + run-length encoding squash them far harder than mixed row text.
- **Column pruning:** need 1 column of 29? Read 1 column of 29. CSV always reads the whole file.
- **Predicate pushdown:** each chunk stores min/max (and row counts) in its footer, so a `WHERE SPTAG >= …` skips whole chunks without opening them.
- **Splittable:** snappy compresses per chunk, so Spark can hand different chunks to different workers. A gzipped CSV is one lump — one worker, no parallelism.
- CSV also has **no types**: every field is text, so every read pays a parse cost and every schema is a guess.
- At our volumes this is not a preference. `S611` 638,035,208 rows × 29 columns, `S603` 648,802,247, `ZHOCIDC` 1,377,080,716 — in CSV the pipeline never finishes.

## Words you'll hear
| Term | Means |
|---|---|
| Columnar | values of one column stored contiguously |
| Column chunk | one column's values for one block of rows |
| Row group | a horizontal slice of the file, split into column chunks |
| Footer / metadata | per-chunk min/max, counts and offsets at the end of the file |
| Predicate pushdown | using that metadata to skip chunks before reading them |
| Splittable | a file many workers can read in parallel |

## In this repo
- `src/glue/glue_engine/writers/raw_landing.py:227` — `df.write.mode("overwrite").parquet(prefix)`; the writer refuses any format other than Parquet.
- `src/glue/specs/download/sap_s611.yaml` — `format: parquet` plus the typed `schema:` block; types are declared once, not re-guessed on every read.
- `src/glue/glue_engine/writers/s3_tables.py` — downstream Iceberg tables, also Parquet underneath.

## Do this
Land any small table to raw, then list the S3 prefix. Note the `.snappy.parquet` part files and the `_SUCCESS` marker, and compare the total size against the same row count as CSV.

## You've got it when you can...
Explain, without saying "it's faster", exactly which bytes a `GROUP BY MATKL` reads from a Parquet file and which bytes it reads from the same data as CSV.
