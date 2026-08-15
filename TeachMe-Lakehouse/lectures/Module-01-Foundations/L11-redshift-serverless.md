# L11 · Redshift Serverless: Where Answers Live

> **Module 1 · Lesson 11** · ~45 min
> Slide: [`_render/L11-redshift-serverless.html`](_render/L11-redshift-serverless.html)

## The point

Everything up to Silver lives on the lake, and Redshift can read it there without copying anything. So why does **Gold get materialised inside Redshift**? Because Power BI asks the same question hundreds of times a day, and a query that scans someone else's files is never as fast as one that reads local, sorted, distribution-aware storage. Redshift is where the answers live; the lake is where the records live.

## Key ideas

- **MPP (massively parallel processing).** The table is sliced across nodes; every node scans only its slice; the leader merges the partial answers. Add nodes, scan faster.
- **Columnar storage.** A query reads only the columns it names, each column is compressed on its own, and per-block min/max ("zone maps") let whole blocks be skipped unread.
- **Serverless = RPUs.** No cluster to size, patch or stop. You set a base and a ceiling and it scales with load: **dev 8 → 16 RPU, prod 32 → 64 RPU**.
- **Dist key** decides *which node* a row lives on. `dist='date'` co-locates a day's rows so date-grained joins don't move data across the network.
- **Sort key** decides the *physical order on disk*. `sort=['date','site']` is what makes a date-filtered dashboard query skip most of the table.
- **Silver is read in place** via Spectrum against the Glue catalog — nothing is copied in. That is L12/L13's territory.
- **Gold is native.** dbt writes real Redshift tables with dist + sort. Once a row reaches Gold, Spectrum is out of the picture — which is exactly why Gold is fast.
- **The namespace holds the data; the workgroup is the compute.** The namespace carries `prevent_destroy = true`; the workgroup is recreatable.

## Words you'll hear

| Term | Means |
|---|---|
| MPP | Many nodes each scanning their own slice of one query |
| Columnar | Stored column-by-column, so reading 3 of 40 columns costs 3/40 of the I/O |
| Zone map | Per-block min/max stats that let the engine skip blocks entirely |
| RPU | Redshift Processing Unit — the serverless capacity unit you rent |
| Namespace | The logical database — holds the data, the schemas, the IAM roles |
| Workgroup | The compute + network surface: capacity, subnets, security groups, endpoint |
| Dist key | Column that decides which node/slice a row lands on |
| Sort key | Column order rows are physically stored in |
| Materialise | Write the query result out as a real table instead of re-computing it |

## In this repo

| Path | What it shows |
|---|---|
| `infra/modules/redshift-serverless/main.tf:51` | `aws_redshiftserverless_namespace` — the logical DB, IAM-only auth, KMS, `log_exports` |
| `infra/modules/redshift-serverless/main.tf:74-76` | `lifecycle { prevent_destroy = true }` — the namespace holds Gold; it must not be destroyable |
| `infra/modules/redshift-serverless/main.tf:79-84` | `aws_redshiftserverless_workgroup` — `base_capacity` / `max_capacity` in RPU |
| `infra/modules/redshift-serverless/main.tf:90` | `enhanced_vpc_routing = true` — all traffic stays in the VPC |
| `infra/env/dev/terraform.tfvars:19-20` | dev: base 8 RPU → max 16 |
| `infra/env/prod/terraform.tfvars:18-19` | prod: base 32 RPU → max 64 |
| `src/dbt/models/marts/gold/unified_sales.sql:76-83` | The config block: `materialized='incremental'`, `incremental_strategy='merge'`, `unique_key=['site','date','aagm','scenario']`, **`dist='date'`, `sort=['date','site']`** |
| `src/glue/glue_engine/jobs/_scripts/run_dbt.py:151-154` | `CREATE EXTERNAL SCHEMA silver_external … IAM_ROLE …` — the read path into Silver that feeds dbt |

## Do this

Open `src/dbt/models/marts/gold/unified_sales.sql` and read only the `config()` block (lines 76–83). The model's grain is site × date × dept × scenario. Explain why `dist='date'` and `sort=['date','site']` were chosen and not, say, `dist='site'` — then predict which Power BI page would get slower if you swapped them.

## You've got it when you can...

Explain to a developer why we don't just point Power BI at the Silver Iceberg tables and skip Redshift entirely — in terms of what happens on the *hundredth* identical query of the day.
