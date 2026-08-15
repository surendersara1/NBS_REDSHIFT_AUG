# L25 · Making It Run In Order

> **Module 0 · Lesson 25** · ~35 min

**Slide:** [`_render/L25-orchestration.html`](_render/L25-orchestration.html)

## What it is

Orchestration is where a pipeline becomes something you can **operate**.

Whichever tool you pick has to answer four questions on demand:

> **What ran · when it ran · how long it took · whether it succeeded.**

If the answer to any of those lives only in a log file that someone has to grep, you do not have orchestration. You have a scheduler.

## Four tools, different centres of gravity

### AWS Step Functions
A state machine defined as JSON, with **native retries, parallelism and error paths**. Best when everything you are sequencing is an AWS service — Glue jobs, Lambda, the Redshift Data API.

Serverless, so there is nothing to patch. The trade is that complex logic in JSON is harder to read than the equivalent Python.

### Amazon MWAA (Managed Airflow)
**Python DAGs**, rich scheduling, backfills, and an enormous ecosystem of operators. The right choice when the pipeline is complex, mixed, or already Airflow-shaped.

The trade is that you are operating an Airflow environment — it has a cost floor, a version to upgrade and a scheduler that can itself fall over.

### Glue workflows and triggers
Built into Glue. Simple, and entirely sufficient **while every step really is a Glue job**. The day you need to call something that is not Glue, you will outgrow it — so notice when that day is coming.

### Amazon EventBridge
Schedules and event rules: the **clock and the tripwire**. It usually sits *in front of* one of the other three rather than instead of them — a cron expression that starts a Step Functions execution, or an S3 event that triggers a load.

## Picking

| What you are running | Tool |
|---|---|
| All AWS services | **Step Functions** |
| Mixed and complex, or existing Airflow skills | **MWAA** |
| Only Glue jobs, for now | **Glue workflows** |
| The trigger itself | **EventBridge**, in front of the above |

**Never:** a cron job on a server nobody maintains. It works perfectly until the person who set it up leaves, and then it is unowned infrastructure with production dependencies.

## What good looks like

Beyond running things in order, an orchestration layer should give you:

- **Retries with backoff**, distinguishing transient failures from real ones
- **Backfill** — re-run a date range without hand-editing anything
- **Dependency awareness** — the gold build does not start because it is 6am; it starts because silver finished
- **Queryable run state** — "did XStore load last night?" answered with a query, not by opening logs

That last one is the difference between a pipeline you can operate and one you can only watch.

## In practice

- **EventBridge** starts the day's run on a schedule.
- **Step Functions** sequences the phases and handles retries.
- **Run state is queryable**, not just present in logs — so an operations dashboard can show what ran without scraping anything.

Module 2 builds this properly, including the control plane that holds run state, watermarks and lineage.

## Checklist

- [ ] I can name the four tools and what each is best at
- [ ] I know EventBridge usually fronts the others rather than replacing them
- [ ] I can state the four questions orchestration must answer
- [ ] I know why dependency-driven beats time-driven
- [ ] I would object to a cron job on an unmanaged server
- [ ] I know run state should be queryable, not just logged

## You've got it when you can…

…be asked "did last night's load work?" and answer from a query in ten seconds — rather than from CloudWatch Logs in ten minutes.
