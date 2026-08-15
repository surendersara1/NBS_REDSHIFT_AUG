# L03 · Size JDBC Parallelism Properly

> **Module 2 · Lesson 03** · ~45 min

**Slide:** [`_render/L03-sizing-jdbc-parallelism.html`](_render/L03-sizing-jdbc-parallelism.html)

## The decision

You have a 300-million-row table on the far side of a network hop.

> **How many parallel readers?**

One connection reading 300 M rows is one socket, one executor and one very long wait, which ends in a job timeout. So you add readers. But readers are simultaneous connections, and the source database has a hard ceiling on those — a ceiling you share with every other job, every other lane, and the source system's own users.

The number is **bounded below by row volume and above by the connection ceiling**. This lesson gives you the arithmetic to find it before you run anything.

## Do this

### 1 · Get the two inputs, from evidence

- **`rows`** — the real row count of the table, measured with the same filter your extract will use (client/tenant filter, date horizon, everything). Not the vendor's headline figure.
- **`ceiling`** — the source's maximum simultaneous connections. **Ask the DBA.** Do not infer it, and do not discover it by saturating production.

Record both in the spec so the next person does not have to re-derive them:

```yaml
expected_row_count: 300_000_000
# source connection ceiling: 160 (confirmed with DBA)
```

*Worked example:* [`specs/download/sap_mbew.yaml`](../../../tamimi-lakehouse/src/glue/specs/download/sap_mbew.yaml) — the partition count, the row count, and the reasoning are all in comments beside the values.

### 2 · Run the four numbers, in this order

Target **≈ 5–10 M rows per partition**. Use 8 M as the working midpoint.

```
1  partitions   =  rows ÷ 8 M           300 M ÷ 8 M     ->  38
2  connections  =  lanes × partitions   4 × 38          ->  152
3  budget       =  ceiling × 50 %       160 × 50 %      ->  80
4  CLAMP        =  budget ÷ lanes       80 ÷ 4          ->  16 partitions
```

- **`lanes`** is your orchestrator's concurrency — how many download jobs run at the same time (a Step Functions Map `MaxConcurrency`, a thread pool size, a task count). Every lane opens its own set of partitions, so **total simultaneous connections = lanes × partitions**. This is the number that matters, and it is the one people forget.
- **Budget at 50 % of the ceiling, not 100 %.** You are not the only client. Leave headroom for the source's own workload, for a retry that overlaps the original, and for the next table you onboard.
- **Step 4 always wins.** If the clamp is lower than step 1, take the clamp.

### 3 · Handle the case where the clamp bites

In the example above, 16 partitions means **19 M rows per partition** — over the 5–10 M target. Do **not** raise the partition count past the ceiling. Instead, in this order of preference:

1. **Cut lanes.** Run the giant with fewer concurrent tables and give it more partitions each. `2 lanes × 40 partitions = 80` connections, 7.5 M rows per partition — inside both targets.
2. **Split the table into date windows** (a chunked / windowed load — see [L05](L05-load-strategy.md)). Each window is a smaller read, and windows are scheduled rather than simultaneous.
3. **Only then**, negotiate a higher ceiling with the DBA — with the arithmetic in hand.

### 4 · Set timeouts for a network hop, not a local socket

Default JDBC timeouts assume a database on the same network. Yours is not.

```
connect timeout   60 s
read timeout     120 s
```

When many partitions open at once, the **connect handshake** is what saturates first — the query itself may be fine. A 15-second connect budget will fail under exactly the parallelism you just computed. Put these in the connection URL, with a comment saying why.

### 5 · Add a guard so nobody ships an unpartitioned giant by accident

In `configure()`, before a single row is read:

```
if expected_row_count > single_partition_max_rows and no partition strategy configured:
    raise
```

Default `single_partition_max_rows` to 5 M. A table that legitimately needs a higher ceiling raises it **in its own spec, with a comment** — which turns "we never thought about it" into "we thought about it and here is why".
*Worked examples:* [`sap_konp.yaml`](../../../tamimi-lakehouse/src/glue/specs/download/sap_konp.yaml) (a deliberate single-partition read with an explicitly raised ceiling) and [`sap_vbrp.yaml`](../../../tamimi-lakehouse/src/glue/specs/download/sap_vbrp.yaml) (the lanes × partitions arithmetic written out in a comment next to the value).

### 6 · Choose the partitioning mechanism to match the column

- **Predicate partitioning** — hand the reader a list of `WHERE` clauses (one contiguous sub-range each) and it opens one connection per predicate, each pushed down to the source. Works on any orderable column, including text dates. This is the default choice.
- **Range partitioning** (`partitionColumn` + `lowerBound` / `upperBound` / `numPartitions`) — requires a genuinely numeric column with a known, roughly uniform range. Beautiful when it applies; it often does not.
- **Never partition on a column that is not indexed at the source.** Each partition then becomes its own full table scan and you have multiplied the work, not divided it.

## Why

- **Too few readers:** one socket, one long-running query, and a job timeout — usually after burning most of a batch window, and usually retried automatically so it burns the window again.
- **Too many readers:** the source's connect pool saturates. The failure is not graceful degradation — *every* read fails at once, including the small tables that were nothing to do with the giant. And the error text ("cannot connect to host", socket timeout) points at the network, so the first hour of debugging goes in the wrong direction.
- **The ceiling is the hard constraint, row volume is the soft one.** You can always deliver a giant in more windows over more time. You cannot open more connections than the source will accept.

**What breaks if you don't:** you learn the ceiling from a two-hour timeout in a live batch window, instead of from a five-minute conversation with the DBA.

## On Apparel Group

**XStore POS is the giant — size it first, and size everything else in the space it leaves.**

| Table class | Example | Rows (order) | Partitions | Notes |
|---|---|---|---|---|
| POS transactions | **XStore** | 100 M – 1 B | clamp, then **window** | Almost certainly exceeds the ceiling at any sensible lane count. Plan a windowed load from day one. |
| Retail facts | **RMS** sales, **SIM** positions | 10 – 100 M | **4 – 8** | The normal case. Straight predicate partitioning on the watermark column. |
| Master data | **RMS** item, supplier, location | 1 – 10 M | **1 – 2** | Well under the single-partition ceiling; do not partition for the sake of it. |
| Lookups / code tables | **RMS** reference tables | < 100 K | **1** | Partitioning costs more in connections than it saves in time. |
| SaaS APIs | **Epsilon**, **MoEngage** | n/a | n/a | Not JDBC. Their limit is a **rate limit**, not a connection ceiling — same discipline, different number. |
| File drops | **Vemco**, **Irisys** | tiny | n/a | Single reader. Nothing to size. |
| Magento | orders, customers, products | 1 – 50 M | **1 – 4** | Size once you know whether it is DB or API. |

Two Apparel-Group-specific cautions:

- **RMS, SIM and XStore may share an Oracle instance or a listener.** If they do, the ceiling is shared across all three, and your budget must be split across them — not applied three times.
- **Three Oracle sources running in the same nightly window multiply lanes.** Compute `lanes` as the total concurrent download jobs across *all* sources, not per source.

## Checklist

- [ ] Real row count measured with the production filter, and recorded in the spec
- [ ] Connection ceiling confirmed with the DBA, and recorded in a comment
- [ ] `lanes` identified as the orchestrator's actual concurrency across all sources
- [ ] Four-step arithmetic run and written down; the clamp applied
- [ ] Rows per partition inside 5–10 M — or the table is windowed instead
- [ ] Budget is ≤ 50 % of the ceiling
- [ ] Connect timeout 60 s, read timeout 120 s, set in the connection URL with a comment
- [ ] Guard raises on an unpartitioned table above `single_partition_max_rows`
- [ ] Any raised ceiling is per-spec and carries a written reason
- [ ] Partition column is indexed at the source

## You've got it when you can…

…read *"cannot connect to host (socket timeout)"* in a job log and immediately ask the right question — **"how many partitions, times how many lanes, against what ceiling?"** — instead of the wrong one, *"is the network down?"*
