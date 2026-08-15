# L40 · Scheduling and Automation

> **Module 01 · Lesson 40** · ~35 min · **closes Part F**

**Slide:** [`_render/L40-scheduling-automation.html`](_render/L40-scheduling-automation.html)

## What it is

Four ways to make a load run at 2 a.m. They differ mainly in **what happens when step four fails at 2:40**.

Anything can start a job on a timer. What separates these options is retry, branching, visibility, and what you can see at 8 a.m. when the report is empty.

## The four options

### 1 · Query editor v2 schedule — weakest

A scheduled statement, configured in the console, backed by EventBridge Scheduler.

**Good for:** a nightly `VACUUM`, an `ANALYZE`, a single `CALL`.
**Not good for:** anything with dependencies, retries, or branching.

⚠️ Its real weakness is **discoverability**. A schedule created in a console by someone who has since left the project is invisible to your repo, your runbook, and the next engineer. If you use it, document it in the repo.

### 2 · EventBridge → Lambda

A cron rule invoking your Node handler (L39).

```json
{ "ScheduleExpression": "cron(0 23 * * ? *)",
  "Target": { "Arn": "arn:aws:lambda:me-central-1:...:function:tamimi-nightly" } }
```

**Good for:** a single job with real logging, error handling and CloudWatch alarms.
**Watch:** Lambda's 15-minute maximum. A load that outgrows it must move to the async pattern — submit the statement, return, and let a second trigger handle completion — or to Step Functions.

**You write the orchestration yourself**, which is fine for one job and painful for eight.

### 3 · Step Functions — the default recommendation

Declarative retry and catch per step, a **picture of last night's run**, and it calls the Data API directly — no Lambda in between.

```json
{
  "StartAt": "LoadDimensions",
  "States": {
    "LoadDimensions": {
      "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:redshiftdata:executeStatement",
      "Parameters": {
        "WorkgroupName": "tamimi-wg",
        "Database": "tamimi",
        "Sql.$": "States.Format('CALL etl.load_dimensions(''{}'')', $.batchDate)"
      },
      "Retry": [{ "ErrorEquals": ["States.ALL"], "IntervalSeconds": 60, "MaxAttempts": 3, "BackoffRate": 2 }],
      "Catch": [{ "ErrorEquals": ["States.ALL"], "Next": "NotifyFailure" }],
      "Next": "WaitForDimensions"
    },
    "WaitForDimensions": { "Type": "Wait", "Seconds": 15, "Next": "CheckDimensions" },
    "CheckDimensions": {
      "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:redshiftdata:describeStatement",
      "Parameters": { "Id.$": "$.Id" },
      "Next": "DimensionsDone?"
    },
    "DimensionsDone?": {
      "Type": "Choice",
      "Choices": [
        { "Variable": "$.Status", "StringEquals": "FINISHED", "Next": "LoadFacts" },
        { "Variable": "$.Status", "StringEquals": "FAILED",   "Next": "NotifyFailure" }
      ],
      "Default": "WaitForDimensions"
    }
  }
}
```

That submit → wait → describe → choice loop is the **standard Redshift Step Functions idiom**. You will write it once and copy it forever. It exists because `executeStatement` is asynchronous (L39) — Step Functions is polling on your behalf instead of a Lambda burning billable milliseconds doing nothing.

**Why this is the default:** when it fails, you open the console and see a diagram with one red box. That is worth more at 8 a.m. than any amount of log searching.

### 4 · MWAA / Airflow

Worth it once you have **cross-system dependencies** — "wait for the SAP extract, then the S3 landing, then Redshift, then trigger the Power BI refresh" — and a team that already knows Airflow.

Otherwise it is a cluster you now own, patch and pay for. For a three-person team starting out, Step Functions is the better trade.

## Idempotency is the prerequisite

> **A job that cannot be safely rerun is not scheduled, it is gambled.**

Every retry in every option above assumes a rerun is harmless. Make it true:

```sql
-- the pattern from L24 and L35 — delete the slice, reload it
DELETE FROM gold.fct_sales_line WHERE sale_date = p_batch_date;
INSERT INTO gold.fct_sales_line SELECT ... WHERE sale_date = p_batch_date;
```

Run it three times, get the same table. Then a retry is free and you can automate confidently.

## What to alert on

Most teams alert on failure and stop there. **The three that matter:**

| Alert | Why it matters |
|---|---|
| **The job failed** | Obvious, and the least dangerous — you know about it |
| **The job did not run at all** | Silence. Nothing failed because nothing started. This is the one that reaches the business first |
| **The job succeeded with zero rows** | The worst kind: green tick, empty report |

The second is what a **heartbeat** catches:

```sql
-- run this on its own schedule, independent of the load
SELECT batch_date, status, rows_loaded, ended_at_utc
FROM   etl.run_log
WHERE  batch_date = DATEADD('day', -1, CURRENT_DATE);
-- zero rows = the job never started. alert.
```

Point an EventBridge rule at that check at 06:00 and you find out before the business does.

The third is what the quality gate in your procedure catches (L35):

```sql
IF v_rows = 0 THEN RAISE EXCEPTION 'no rows loaded for %', p_batch_date; END IF;
```

## The run log

Everything above depends on this table existing:

```sql
CREATE TABLE etl.run_log (
    run_id        BIGINT      NOT NULL,
    job_name      VARCHAR(80) NOT NULL,
    batch_date    DATE        NOT NULL,
    status        VARCHAR(20) NOT NULL,   -- RUNNING | SUCCESS | FAILED
    rows_loaded   BIGINT,
    error_text    VARCHAR(2000),
    started_at_utc TIMESTAMP  NOT NULL,
    ended_at_utc   TIMESTAMP,
    triggered_by  VARCHAR(80)             -- the execution arn, so you can find the run
)
DISTSTYLE ALL
SORTKEY (batch_date, job_name);
```

`triggered_by` is small and worth having: given a bad number in a report, you can go from the row to the batch to the exact Step Functions execution.

## Schedules are UTC

`cron(0 23 * * ? *)` fires at **23:00 UTC** = **02:00 Riyadh**. EventBridge Scheduler does support time zones and DST, and plain EventBridge rules do not — but the safer habit is to **think in UTC, write UTC, and put the local time in a comment**:

```
cron(0 23 * * ? *)   # 23:00 UTC = 02:00 Asia/Riyadh (UTC+3, no DST)
```

Same discipline as L32. And schedule the load to start *after* the source systems have finished their own day — a nightly load that begins at local midnight often catches the last hour of trade only in tomorrow's run.

## Gotchas

- **A retry only helps if the job is idempotent.**
- **Alert on the job that did not run.** Silence is the failure you will miss.
- **Alert on zero rows.** A green tick on an empty load is worse than a failure.
- **Schedules are UTC.**
- **Lambda caps at 15 minutes.** Design for it or use Step Functions.
- **Console-created schedules are invisible to your repo.** Document or avoid.
- **Step Functions has a payload size limit** — pass S3 keys, not data.
- **Concurrent executions of the same load** will fight over the same table. Set concurrency to 1, or use a lock row.
- **The Data API is async** — a Step Functions task that does not poll `describeStatement` will report success the moment the statement is *submitted*. This is a real and common bug: the job goes green while the SQL is still running or already failing.

That last one is worth reading twice.

## Try it

1. Build the Step Functions state machine for one load, including the wait/describe/choice loop. Break the SQL and watch the retry then the catch.
2. Add the `etl.run_log` table and populate it from the job (L39).
3. Write the heartbeat check and schedule it two hours after the load. Disable the load for one night and confirm the heartbeat alerts.
4. Run the same load three times for the same date. Row count must be identical.
5. Deliberately omit the `describeStatement` poll and watch the state machine go green on a query that fails. Then put it back.

## Checklist

- [ ] Every scheduled job is idempotent for its batch date
- [ ] Step Functions for anything with more than one step
- [ ] The submit → wait → describe → choice loop is in place
- [ ] Retry with backoff, and a catch that notifies
- [ ] `etl.run_log` written by every job
- [ ] Alerts on: failed, did-not-run, and zero-rows
- [ ] Schedules written in UTC with the local time in a comment
- [ ] Concurrency limited to one execution per load
- [ ] Schedules live in IaC, in the repo — not in a console

## You've got it when you can…

…be told at 08:00 that a dashboard is empty, and know within a minute whether the job failed, never ran, or ran perfectly against no data — because you built the alert for each one separately.

---

**Part F complete.** L35–L40 covered procedures, control flow, UDFs, Lambda UDFs, the Node.js integration and scheduling. Part G is operations: WLM, maintenance, the system tables, diagnosing a slow query, and cost.
