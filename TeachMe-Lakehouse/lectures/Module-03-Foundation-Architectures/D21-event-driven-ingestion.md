# D21 · Event-Driven File Ingestion

> **Module 3 · Architecture 21 · deep dive** · ~20 min walkthrough

**Diagram:** [`_render/D21-event-driven-ingestion.html`](_render/D21-event-driven-ingestion.html)

## What this pattern is for

A source system drops a file and the platform reacts. **No polling, nothing running when there is nothing to do, and no server anyone has to patch.**

Use it when arrival is unpredictable — SFTP drops, partner feeds, footfall exports — and you want the cost to be zero on a day nothing arrives. The alternative (a scheduled job that looks for files) burns compute on every empty check and still adds latency on a busy day.

## The eleven steps

**1 · A file lands in the raw bucket.**
The source system writes to `raw/<source>/<table>/dt=.../`. That is the only thing it has to do, and the only interface we ask it to honour. The object is never edited afterwards.

**2 · S3 raises an object-created event to EventBridge.**
S3 notifies EventBridge rather than calling a Lambda directly. This matters: EventBridge lets several independent rules react to the same object without the producer knowing about any of them, so adding a consumer later is a rule, not a change.

**3 · EventBridge puts a message on SQS.**
The queue is the shock absorber. A hundred files arriving at once become a hundred queued messages instead of a hundred concurrent executions, and a failure gets retried with backoff rather than lost. Give it a dead-letter queue on day one.

**4 · SQS triggers the landing Step Functions workflow.**
State machine, not a chain of Lambdas calling each other. Retries, error paths and timeouts are declared rather than coded, and a failed execution is visible in the console with the exact step that failed.

**5 · Validate, then register.**
The first Lambda checks the file against the declared contract — expected columns, types, partition, non-empty. A file that fails is moved aside and alarmed, **not** processed into the lake. The second Lambda records that a run has started.

**6 · The run is written to the control plane.**
DynamoDB holds `runs`, `watermarks`, `pipeline-state` and `lineage`. This is what makes "did last night work?" a query rather than a log search, and what the ops console reads.

**7 · Typed rows land in the stage bucket.**
Raw stays raw, forever. The staged copy is typed and partitioned, which is what the Glue jobs read. Two buckets, two jobs: one preserves evidence, the other is convenient to process.

**8 · On the schedule, a dispatcher decides what runs.**
EventBridge Scheduler triggers a dispatch Lambda that reads the control plane and works out **which specs are due** — not a hardcoded list. This is what makes adding a source a config change rather than a deployment.

**9 · Glue builds bronze, then silver.**
Bronze does a `MERGE` on the natural key, so re-running is safe. Silver conforms and joins. Both are Iceberg tables, so both support row-level updates and time travel.

**10 · Tables are registered in the catalog, inside the Lake Formation scope.**
Registration is **declarative** — we do not run crawlers on a schedule and let inferred schema drift silently. From this point, Lake Formation governs who can read what, at column level, for every engine.

**11 · Analysts query through Athena.**
Serverless SQL, priced per byte scanned, with a workgroup limit set so a bad query is an error rather than an invoice. Power BI reads the modelled layer; Athena is for the questions nobody anticipated.

## Why it is shaped this way

| Decision | Reason |
|---|---|
| S3 → **EventBridge**, not S3 → Lambda | many consumers can react without the producer changing |
| An **SQS queue** in the middle | absorbs bursts, retries with backoff, dead-letters poison messages |
| **Step Functions**, not chained Lambdas | retries and error paths are declared and visible |
| **Two buckets** (raw, stage) | raw is evidence; stage is convenience. Never conflate them |
| **Control plane in DynamoDB** | run state is queryable, not buried in CloudWatch Logs |
| A **dispatcher** reading config | adding a source is a spec file, not a deploy |

## What breaks if you skip a piece

- **No queue** — a burst of files becomes a burst of concurrent executions, and throttling failures are silent.
- **No validation step** — a malformed file becomes a malformed table, discovered downstream in a report.
- **No control plane** — every "did it run?" question becomes a log search, and the ops console has nothing to read.
- **Crawlers instead of declarative registration** — a schema change upstream silently changes your table definition.

## On Apparel Group

This is exactly the shape for **Vemco** and **Irisys** footfall feeds: small per-store files, unpredictable arrival, and long gaps where nothing comes. Polling those on a schedule would cost more than the data is worth.

It also handles the failure mode those feeds actually have — **arriving twice**. Step 9's `MERGE` on the natural key makes a duplicate delivery a no-op rather than a doubled figure.

The three Oracle sources take a different path (D17, D22, D23); the SaaS APIs a third (D16). This diagram is one of several ingestion shapes, not the only one.

## Checklist

- [ ] S3 notifies EventBridge, not a Lambda directly
- [ ] There is a queue, and it has a dead-letter queue
- [ ] Validation happens before anything reaches a table
- [ ] Run state is written to the control plane, not just logged
- [ ] Raw and stage are separate buckets with different lifecycles
- [ ] Dispatch reads config; adding a source needs no deployment
- [ ] Glue MERGEs on a key, so a duplicate file is harmless
- [ ] Catalog registration is declarative, not a scheduled crawler
- [ ] The Athena workgroup has a per-query scan limit

## You've got it when you can…

…draw this on a whiteboard from memory, and for each of the eleven steps say what happens **when that step fails** — because that is the question a client actually asks.
