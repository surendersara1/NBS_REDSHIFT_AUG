# L08 · Amazon S3 Tables: Managed Iceberg

> **Module 1 · Lesson 08** · ~45 min
> Slide: [`_render/L08-s3-tables.html`](_render/L08-s3-tables.html)

## The point

Iceberg (L07) gives you the format. Running it yourself means you also own the chores: compacting the thousands of small files a streaming/CDC pipeline produces, removing files no snapshot references any more, and babysitting the bucket. **S3 Tables is Iceberg as a managed service** — AWS runs the maintenance and owns the physical storage. You keep the writes, the keys and the schema. This lesson is about drawing that line precisely, because the parts AWS *doesn't* cover are the parts that bite.

## Key ideas

- **Table bucket ≠ S3 bucket.** A table bucket is an Iceberg-native surface. `aws s3 ls` on its name returns `NoSuchBucket` — you cannot touch the files directly.
- **Three levels: table bucket › namespace › table.** We have two buckets (bronze, silver), each with the same namespaces (`sap`, `ncr`, `ecommerce`).
- **Terraform creates buckets and namespaces only.** Tables are *not* declared in infrastructure.
- **Tables register themselves on first write** from a Glue job. Adding a table is a new YAML spec, not a `terraform apply`.
- **AWS takes over:** data-file compaction, unreferenced-file removal, the physical bucket, encryption at rest with our KMS key.
- **You still own:** the writes, *snapshot* expiry (metadata, not data), partitioning, schema, merge keys — and getting the Spark catalog conf right, which is where the real pain lives.
- **What you give up:** direct file access, and portability. Iceberg runs anywhere; this managed layer is AWS-only.

## Words you'll hear

| Term | Means |
|---|---|
| Table bucket | An Iceberg-native S3 bucket, addressed by ARN, not by object key |
| Namespace | A schema/grouping inside a table bucket (`sap`, `ncr`, `ecommerce`) |
| Compaction | Merging many small data files into fewer big ones so scans stay fast |
| Unreferenced file removal | Deleting files no live snapshot points at any more |
| Maintenance configuration | The Terraform block that tunes those retention windows |
| Managed physical bucket | The real storage AWS owns on your behalf; you never see it |
| Register on first write | The table is created by the job that first writes to it |

## In this repo

| Path | What it shows |
|---|---|
| `infra/modules/s3-data-lake/main.tf:11` | `aws_s3tables_table_bucket.bronze` |
| `infra/modules/s3-data-lake/main.tf:30` | `aws_s3tables_table_bucket.silver` |
| `infra/modules/s3-data-lake/main.tf:14-22` | `maintenance_configuration` — unreferenced-file removal, 7 days (bronze) / 30 days (silver) |
| `infra/modules/s3-data-lake/main.tf:24-27` | `encryption_configuration` — `aws:kms` with the per-layer CMK |
| `infra/modules/s3-data-lake/main.tf:52` / `:59` | `aws_s3tables_namespace` for bronze / silver, `for_each = toset(var.namespaces)` |
| `src/glue/glue_engine/writers/s3_tables.py:143` | `_first_write_create` — the "tables register themselves" path |
| `src/glue/glue_engine/writers/s3_tables.py:60-67` | The `NoSuchBucket` discovery, and why the Spark catalog had to move to the Iceberg REST endpoint |
| `src/glue/glue_engine/writers/s3_tables.py:407` | `expire_snapshots` — the maintenance AWS does **not** do for you (see the ADR-0024 note) |

## Do this

Read the module header comment in `infra/modules/s3-data-lake/main.tf` (lines 1–9), then list every AWS object that exists for `bronze.sap.zsdcc`. Which of them appear in Terraform state, and which are created at runtime? Now find the retention difference between bronze and silver and argue why silver keeps files four times longer.

## You've got it when you can...

Name one maintenance task S3 Tables performs for us and one it does not — and say which file in this repo would have to run for the second one.
