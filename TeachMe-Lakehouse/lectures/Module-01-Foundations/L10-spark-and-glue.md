# L10 · Spark & AWS Glue: Why Not Just a Python Script

> **Module 1 · Lesson 10** · ~45 min
> Slide: [`_render/L10-spark-and-glue.html`](_render/L10-spark-and-glue.html)

## The point

You already know how to write `pandas.read_sql(...)`. That works right up to the moment the table is **638,035,208 rows** — then one CPU, one heap and one JDBC connection stop being an implementation detail and become the whole problem. Spark is not a faster laptop; it is a **foreman**. You describe the work, it splits the data into chunks, hands them to N machines, and doesn't start until you ask for a result. AWS Glue is that cluster rented for forty minutes and then thrown away.

## Key ideas

- **Partitions** — a DataFrame is N chunks. A chunk is the unit of work, and it's the only reason parallelism is possible at all.
- **Executors** — worker JVMs that chew chunks concurrently. We run 12 × `G.2X` for the SAP download lanes. More workers, more chunks in flight.
- **Lazy evaluation** — nothing executes until an *action* (`count()`, `write`, `collect()`). Transformations only build a plan.
- **The lazy trap:** each action re-runs the plan. Without `.cache()`, `count()` + the watermark `agg(max)` + the write meant **3× the SAP load, 3× the cost**, and non-determinism if the source moved between passes.
- **Shuffles** — `groupBy`, `join`, `dropDuplicates`, window functions move rows *between machines*. That is the expensive operation; everything else is cheap by comparison.
- **Parallelism has a budget.** `jdbc_hash_partitions` is capped at 8 for the giants, not for Spark's sake, but because HANA + the transit gateway only tolerate so many concurrent connections.
- **When Spark is the WRONG tool:** under ~10M rows, cluster startup and shuffle cost more than the work. Our dbt runner is deliberately a Glue **Python-Shell** job, not Spark.

## Words you'll hear

| Term | Means |
|---|---|
| Driver | The process running your `main()`; builds the plan, coordinates workers |
| Executor / worker | A JVM doing actual work on a slice of the data |
| Partition | One chunk of a DataFrame = one unit of parallel work |
| Transformation | Lazy — `select`, `filter`, `join`. Builds the plan, runs nothing |
| Action | Eager — `count`, `write`, `collect`. Triggers execution |
| Shuffle | Moving rows across the network so keys land together |
| `G.2X` | A Glue worker size (8 vCPU / 32 GB). `number_of_workers` sets how many |
| DPU-minute | What you are billed for: workers × how long they lived |

## In this repo

| Path | What it shows |
|---|---|
| `src/glue/glue_engine/` | The spec-driven engine: `sources/`, `transforms/`, `writers/`, `jobs/` — one engine, N YAML specs |
| `src/glue/glue_engine/jobs/bronze_pull.py` | A real Glue job end to end: resolve spec → read → PII redact → write → record the run |
| `src/glue/glue_engine/jobs/bronze_pull.py:255-256` | `# Count BEFORE write (DataFrame is lazy).` — laziness stated in the code |
| `src/glue/glue_engine/sources/sap_hana.py:1151-1160` | The `.cache()` comment: without it the JDBC pull re-executes once per action |
| `src/glue/glue_engine/sources/sap_hana.py:188-192` | The 5,000,000-row guard — a single-partition read of the giants OOMs on one executor |
| `src/glue/specs/download/sap_s611.yaml:28` | `jdbc_hash_partitions: "8"` — parallelism as configuration, with the reason in a comment |
| `infra/env/dev/glue_sources.tf:146-147` | `worker_type = "G.2X"`, `number_of_workers = 12` — the cluster, in Terraform |

**The scale, concretely:** `ZHOCIDC` 1,377,080,716 · `VBRP` 684,592,844 · `S603` 648,802,247 · `S611` 638,035,208 rows.

## Do this

Open `sources/sap_hana.py` and find `df.cache()` (line 1160). Read the comment above it, then trace which three actions would each have re-triggered the JDBC read. Now open `infra/env/dev/glue_sources.tf` and work out how many worker ENIs 3 lanes × 2 concurrent runs × 12 workers puts into one subnet — and why the comment says that number matters.

## You've got it when you can...

Given a 4-million-row Oracle table that needs a daily join and aggregate, argue *for or against* Spark — and name the one number that decides it.
