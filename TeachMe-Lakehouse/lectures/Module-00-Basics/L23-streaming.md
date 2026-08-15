# L23 · Streaming, Honestly

> **Module 0 · Lesson 23** · ~40 min

**Slide:** [`_render/L23-streaming.html`](_render/L23-streaming.html)

## What it is

Two separate questions that people mix up constantly:

1. **How do the events travel?** — Kinesis, MSK/Kafka
2. **Where do they come to rest?** — Firehose, Redshift streaming ingestion

You choose both. "We'll use Kinesis" answers only half the design.

## Transport — how events travel

### Amazon Kinesis Data Streams
Durable, ordered **shards**. Several consumers can read the same stream independently, each at its own position. Ordering is guaranteed within a shard, not across shards — which is why the partition key matters.

### Amazon MSK / Apache Kafka
Managed Kafka, including Confluent Cloud as a source. The right call when the organisation already speaks Kafka — the tooling, the mental model and the people are already there.

## Landing — where they come to rest

### Amazon Data Firehose
Managed delivery with **no code at all**. Destinations include:

- **Amazon S3**
- **Apache Iceberg tables** — self-managed *or* **S3 Tables** — with insert, update and delete **routing** from a single stream
- **Amazon Redshift** — stages to S3, then issues `COPY`
- OpenSearch, HTTP endpoints and others

The trade-off worth teaching: **ingest throughput versus how many Iceberg partitions are open at once**. A stream fanning out across many partitions delivers less throughput than one writing to a few. That is a design constraint on your partitioning, not a tuning knob.

### Redshift streaming ingestion
A **materialized view mapped directly onto the stream** — Kinesis, MSK, Apache Kafka or Confluent Cloud — refreshed from the stream **with no S3 staging at all**, with `AUTO REFRESH`.

This is the same object from Lesson 12, doing a new job. Lower latency than Firehose, and one fewer thing in the path.

### When you need windows and state
**Managed Service for Apache Flink** or **Glue streaming ETL** — for aggregations over time windows, joins between streams, and anything that has to remember what it saw.

## Event plumbing that is not really streaming

**DynamoDB Streams**, **S3 Event Notifications** and **EventBridge** trigger pipelines when something happens. They are event-driven, but they are not high-volume streaming, and reaching for Kinesis when an S3 event would do is a common over-build.

## When to use it

**Use streaming when:**
- Seconds genuinely change a decision someone is making
- The source emits events, not rows in a table
- Volume is too high to batch sensibly

**Do not use it for:**
- Daily retail reporting. Batch is cheaper, simpler, and easier to reason about at 3am.

## The honest position

**Most retail analytics does not need streaming.** This lesson exists so you can recognise the minority of cases that genuinely do — and so you are not talked into it by a diagram.

Two questions that end the conversation quickly:

1. **Who is watching the screen at 3am?** Freshness that nobody consumes is cost with no benefit.
2. **What decision changes in the next sixty seconds?** If none, you want a shorter batch interval, not a stream.

## In practice

- Neither of our platforms streams today.
- Learn it to recognise the 10% that needs it.
- **Batch until it genuinely hurts.** Then measure what hurts, and stream only that.

## Checklist

- [ ] I can separate transport from landing and name options for each
- [ ] I know Firehose writes to Iceberg including S3 Tables
- [ ] I know the throughput-versus-open-partitions trade
- [ ] I know streaming ingestion lands on an MV with no S3 staging
- [ ] I know when to reach for Flink instead
- [ ] I ask the two questions before agreeing to build a stream

## You've got it when you can…

…hear "we need real-time" in a requirements session, ask what decision changes in the next minute, and land on the honest answer — which is usually an hourly batch.
