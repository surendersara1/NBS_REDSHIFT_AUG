# D29 · Following The Money

> **Module 3 · Architecture 29 · deep dive** · ~20 min

**Diagram:** [`_render/D29-cost-and-lifecycle.html`](_render/D29-cost-and-lifecycle.html)

## What this pattern is for

Nine places a lakehouse spends money. **Only three of them appear on the diagram people usually draw** — and the six that do not are where the surprises live.

## The nine places

**1 · S3 Standard, per GB-month.** The cheap part, and the one everybody worries about. Storage is rarely the problem.

**2 · Lifecycle transitions.** Moving cold partitions to IA, then Glacier Instant Retrieval, cuts the storage line. ⚠️ But **retrieval is billed separately** — archiving data a dashboard still reads is a cost *increase* that hides as a saving, because the saving lands on one line and the cost on another (Module 0 L27).

**3 · Glue DPU-hours.** The ingestion bill. Driven by how much you read, how parallel it is, and how often it runs. Halving a schedule halves this line, and most schedules were set once and never revisited.

**4 · Compaction.** ⭐ The line nobody budgets for. Iceberg v2 writes delete files rather than rewriting data; without scheduled compaction, reads get slower and storage grows for data that is logically gone. **You are paying either way** — either compaction DPU-hours, or slower queries forever.

**5 · Logs and metrics retention.** CloudWatch keeps what you tell it to keep, and the default is often "forever". On a chatty platform this becomes a real number quietly.

**6 · Athena, per TB scanned.** ⭐ The most controllable line on the whole list. Partitioning and Parquet are **cost controls**, not performance tuning — a query against unpartitioned CSV can cost a hundred times the same query against partitioned Parquet. Set a per-query scan limit on the workgroup so a bad query is an error, not an invoice.

**7 · Redshift RPU-hours.** Serverless bills for what you use, which is excellent right up until an always-on dashboard keeps it warm all night. Check what is querying it outside business hours.

**8 · Data transfer.** Cross-AZ traffic and egress. Usually small, occasionally startling — a cross-Region read in a loop is the classic. Worth checking once rather than assuming.

**9 · Cost Explorer and Budgets.** ⭐ **Tag every resource by environment and by pipeline from day one.** Untagged spend cannot be attributed, and unattributed spend cannot be reduced — you end up arguing about a total instead of fixing a line. Set a budget alarm so you find out before the invoice does.

## The levers you actually control

| Lever | Affects | Typical effect |
|---|---|---|
| Partitioning | Athena, Spectrum, Glue | the largest single lever |
| Parquet instead of CSV/JSON | everything that reads | 10–100× less scanned |
| File size (128 MB–1 GB) | Glue, Athena | fewer, bigger reads |
| Schedule frequency | Glue DPU-hours | linear |
| Workgroup scan limits | Athena | caps the worst case |
| Lifecycle rules | S3 storage | **check what still reads it first** |
| Log retention | CloudWatch | quiet but real |

## The three questions for a cost review

1. **What is the biggest line, and what drives it?** Not "what is expensive" — what *causes* it.
2. **What runs on a schedule nobody has reviewed?** Schedules are set once, in a hurry, and never revisited.
3. **What is untagged?** If you cannot attribute it, you cannot reduce it.

## On Apparel Group

**XStore is the giant**, and it will dominate lines 3, 4 and 6. Two decisions to make deliberately before go-live rather than after the first invoice:

- Its **partitioning scheme** — it sets the floor for every query cost afterwards, and it is the hardest thing to change later.
- Its **ingestion cadence** — this is also the cost argument in the zero-ETL comparison (D17). Continuous replication of a very large, high-churn table has an ongoing cost that a nightly batch does not.

## Checklist

- [ ] Every resource tagged by environment and pipeline
- [ ] A budget alarm exists
- [ ] Athena workgroups have a per-query scan limit
- [ ] Largest tables are partitioned on what people filter by
- [ ] Everything queried is Parquet, not CSV or JSON
- [ ] Compaction is scheduled and its cost is known
- [ ] Log retention is set deliberately
- [ ] Lifecycle rules checked against what still reads the data

## You've got it when you can…

…be shown a rising bill and name the three lines to look at first — then find the schedule somebody set in week two and nobody has looked at since.
