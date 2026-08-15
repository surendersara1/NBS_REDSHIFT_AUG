# D24 · Streaming — Two Landing Paths

> **Module 3 · Architecture 24 · deep dive** · ~20 min

**Diagram:** [`_render/D24-streaming-ingestion.html`](_render/D24-streaming-ingestion.html)

## What this pattern is for

Genuinely event-driven data, where seconds change a decision somebody is making. **Most retail analytics does not qualify** — this diagram exists so you can recognise the minority that does, and so you are not talked into it by a picture.

Two separate choices that people constantly merge: **how events travel**, and **where they come to rest**.

## The nine steps

**1 · Producers emit events.** Tills, applications, sensors. They fire and forget; nothing downstream is allowed to block them.

**2 · Choose a transport.** **Kinesis Data Streams** gives durable ordered shards with several independent consumers. **Amazon MSK** (or Confluent Cloud) is the right call when the organisation already speaks Kafka — the tooling and the people are already there. Ordering is guaranteed *within* a shard or partition, not across them, which is why the partition key matters more than it looks.

**3 · Path A — Firehose.** Managed delivery with no code at all. It buffers, batches and writes for you.

**4 · Firehose lands in Iceberg.** Including **S3 Tables**, with insert / update / delete **routed from a single stream** into different tables. The data is now in the lake, governed by the catalog, readable by every engine.

**5 · The trade-off nobody mentions.** ⭐ Firehose trades **ingest throughput against the number of Iceberg partitions open at once**. A stream fanning across many partitions delivers less throughput than one writing to a few. This is a constraint on your *partitioning design*, not a tuning knob you turn later.

**6 · Path B — straight into Redshift.** Same transport, different landing.

**7 · A materialized view mapped onto the stream.** ⭐ Redshift streaming ingestion maps an MV directly onto Kinesis or Kafka, refreshed from the stream **with no S3 staging at all**. Lower latency and one fewer moving part — and it is the same object from Module 0 L12, doing a new job.

**8 · The dashboard is seconds behind.** Which is genuinely impressive, and is the point at which you should ask the next question.

**9 · Ask it before you build.** ⭐ **Who is watching the screen at 3am?** And: **what decision changes in the next sixty seconds?** If the honest answers are "nobody" and "none", you wanted a shorter batch interval, not a stream — and you have just avoided an always-on cost that runs whether anyone looks or not.

## Path A or Path B

| | **A · Firehose → lake** | **B · Straight to Redshift** |
|---|---|---|
| Latency | seconds to a minute | seconds |
| Lands in | Iceberg, governed, reusable | one materialized view |
| Read by | every engine | Redshift only |
| Keeps evidence | yes — raw events retained | no |
| Best for | events you will reprocess | one live dashboard |

**Path A keeps the evidence and feeds everything. Path B is faster and feeds one thing.** Most projects want A and think they want B.

## When you need more than delivery

If the requirement involves **windows, joins between streams, or remembering what you saw**, neither path is enough — that is **Managed Service for Apache Flink** or **Glue streaming ETL**. Delivery services buffer; they do not compute.

## On Apparel Group

Neither platform streams today, and nothing in the SOW requires it. Learn it to recognise the case that does, and to price it honestly when someone asks.

**Batch until it genuinely hurts.** Then measure what hurts, and stream only that.

## Checklist

- [ ] I can separate transport from landing
- [ ] I know Firehose writes to Iceberg including S3 Tables
- [ ] I know the throughput-versus-open-partitions trade
- [ ] I know streaming ingestion lands on an MV with no S3 hop
- [ ] I ask who is watching, and what decision changes, before agreeing to build
- [ ] I reach for Flink only when windows or state are actually required

## You've got it when you can…

…hear "we need real-time" in a requirements session, ask what decision changes in the next minute, and land on the honest answer — usually an hourly batch at a fraction of the cost.
