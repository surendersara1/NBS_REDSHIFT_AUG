# L12 · Write Spark That Scales

> **Module 2 · Lesson 12** · ~45 min
> **Slide:** [`_render/L12-spark-that-scales.html`](_render/L12-spark-that-scales.html)

---

## The decision

**Why is this job slow — and what do you change first?**

Almost every slow or unstable Spark job on a lakehouse comes down to one of five things: an uncached frame read more than once, an unpartitioned source read, a shuffle you didn't budget for, work pulled back to the driver, or skew. The skill is not knowing more knobs; it is **identifying which of the five you have** before touching any of them.

The one thing you must not do is tune by guesswork. Doubling executors, raising `numPartitions` or increasing memory in response to a symptom you have not measured is how a two-hour job becomes a two-hour job that also costs more.

## Do this

### The five rules of thumb

1. **Cache any frame you consume more than once.** Spark is lazy: a DataFrame is a *plan*, and every action executes that plan from the top. A frame you count, then aggregate, then write, is read from the source **three times** unless you cache it.
   ```python
   df = read_source(...)
   df.cache()                     # one line, before the first action
   n   = df.count()
   hwm = df.agg(F.max("updated_at")).first()[0]
   write(df)                      # still one source read, not three
   ```
   `MEMORY_AND_DISK` spills rather than failing, so caching is safe on the giants.

2. **Count the actions.** `count`, `collect`, `first`, `show`, `write` execute the plan. `select`, `filter`, `join`, `withColumn` only build it. Count the actions in a function and you have counted the source reads. This is the single highest-value habit in the lesson.

3. **Partition the read, and size the partitions.** A JDBC read with no partition column or predicates is **one connection**, however much parallelism the config claims. Target roughly **5–10 M rows per partition**, then check the number that actually matters:
   > **partitions per table × concurrently-running tables ≤ the source's connection ceiling**

   Too few partitions means timeouts and memory pressure. Too many means you exhaust the source database's connection headroom and *every* read fails at once — which looks like a database outage, not a tuning problem. Add a guard that refuses to start when a table declares a large expected row count and has no partitioned read configured; a job that won't start beats a job that times out.

4. **Never collect to the driver.** `collect()` on a fact table moves the whole result into one process's heap. Aggregate in the cluster, write to storage, and read the small result back if you need it locally. The same applies to `toPandas()` on anything unbounded.

5. **Look for skew before you touch config.** A stage finishes when its *slowest task* finishes. One store-day with ten times the volume holds the entire stage, and no `numPartitions` setting fixes that. Salt the key, filter the outlier out and handle it separately, or change the grain.

### Reading the symptom

| What you observe | What it usually is |
|---|---|
| Job time ≈ *n* × a single read | a missing `.cache()` — *n* actions on one plan |
| One executor busy, the rest idle | skew, or a single-connection source read |
| OOM inside a Python worker | an `applyInPandas` group that is too big |
| Every source read fails at once | too many total connections, not too few |
| Fast in dev, dies in prod | volume-dependent: partitioning or skew |

### The order of operations

**Measure → identify which of the five → change one thing → measure again.** Read the Spark UI stage timeline before you read the config file.

**Worked example of the pattern:** `tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py` shows the cache-before-multiple-actions shape and the partitioned-read predicate builder; `.../abap/ops.py` shows a frame cached because two downstream filters consume it.

## Why

Spark's laziness is the source of most of its surprises. A DataFrame is a description of work, not the work's result, so "I already read that" is not true unless you said so explicitly. Once you internalise *plan, not data*, rules 1 and 2 stop being tips and become obvious.

The connection-ceiling arithmetic matters because the constraint lives outside your cluster. You can scale executors freely; you cannot scale the source database's connection limit. Parallelism that ignores that boundary converts a slow job into a source-wide outage.

**What breaks if you don't:** the job does not fail fast — it burns hours of cluster time and then times out with nothing written, so you pay full cost for zero output, every cycle, until someone looks.

## On Apparel Group

**XStore is the giant. Size it first.** POS transactions across the estate dwarf everything else on the platform, and it is the table where partitioning, caching and skew all bite at once. Get its read strategy right before optimising anything else — the other seven sources together will not cost what this one does.

- **XStore:** the largest read by a wide margin. Partition on an indexed, well-distributed column, size for 5–10 M rows per partition, and expect skew by store and by trading day. Sale weekends and season launches are real outliers, not noise.
- **RMS masters** (style, colour, size, season, supplier): small. Almost no parallelism needed. Partitioning these buys nothing and spends connections you need elsewhere.
- **RMS transactions and SIM:** middle-weight, high churn. Partition modestly; re-check as volumes grow.
- **Magento:** middling and spiky — e-commerce peaks are sharper than store peaks.
- **Epsilon · MoEngage:** API/file sources. The constraint is the vendor's rate limit and page size, not Spark. Parallelism here is throttling, not tuning.
- **Vemco · Irisys Footfall:** tiny. Never worth partitioning.

**Budget connections per source, not per job.** All the Oracle sources may sit behind shared infrastructure and a shared ceiling. Work out the total concurrent connection count across every table running in the same window and keep it comfortably under the limit — then cap job concurrency to enforce it, rather than trusting each spec to be individually reasonable.

## Checklist

- [ ] Every frame consumed more than once is cached, on its own line, before the first action
- [ ] I have counted the actions in this function and know the source-read count
- [ ] Large table reads are partitioned; partition size targets ~5–10 M rows
- [ ] partitions × concurrent tables is written down and is under the source ceiling
- [ ] No `collect()` / `toPandas()` on anything unbounded
- [ ] I checked the stage timeline for skew before changing any setting
- [ ] A guard fails the job at config time if a big table has an unpartitioned read
- [ ] I measured before tuning, and after

## You've got it when you can…

…look at an unfamiliar Spark function and answer three questions without running it: **how many times does this read the source, where is the shuffle, and what is the biggest single group** — then point at the `.cache()`, the partitioning and the group key that each decide one of those answers.
