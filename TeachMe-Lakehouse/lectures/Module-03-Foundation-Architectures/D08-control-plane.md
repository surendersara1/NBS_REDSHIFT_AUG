# D08 · The Control Plane

> **Module 3 · Architecture 08** · ~15 min

**Diagram:** [`_render/D08-control-plane.html`](_render/D08-control-plane.html)

## What it shows

Five DynamoDB tables, who writes them, and who reads them. Together they turn **"did last night work?"** from a log search into a query — and they are what makes barriers possible at all.

## The five tables

| Table | Holds |
|---|---|
| `runs` | one row per job execution — status, start, end, rows, error |
| `watermarks` | the high-water mark per table, and whether it is dirty |
| `pipeline-state` | live per-source state, so the dispatcher knows what is safe |
| `lineage_edges` | which output came from which input, for impact analysis |
| `coordination` | single-flight locks — conditional writes are what make barriers work |

## Who writes

Glue jobs (every run, every table) · Step Functions (phase transitions) · the dispatcher (what runs tonight) · writers (lineage on every write).

## Who reads

The ops console (what ran, when, how long) · the barrier gate (may phase 2 start?) · the next run (reads its own watermark) · alarms (stale, failed or missing).

## The one line that matters

```
ConditionExpression: attribute_not_exists(pk)
```

The first writer wins; a second attempt fails harmlessly. That single expression gives you single-flight locks, idempotent phase transitions, and safety against two schedulers firing at once (D25).

## Why this is not "just logging"

Logs are for reading **after** you already know something is wrong. The control plane is for **asking**:

- Did XStore load last night? → a query
- What is the watermark for this table? → a query
- Is it safe to start phase 2? → a query
- If I change this source, what breaks? → a query against lineage

Every one of those becomes a person's time if the answer only exists in CloudWatch Logs.

## The dirty-watermark guard

`watermarks` carries more than a value — it carries whether the last run left it **dirty**. A job that failed part-way must not let the next run advance past data it never wrote. That flag is the difference between a failed load and a silent gap.

## Checklist

- [ ] I can name the five tables and what each holds
- [ ] I know who writes each and who reads each
- [ ] I can explain the conditional write and what it prevents
- [ ] I know why a watermark carries a dirty flag
- [ ] I can answer "did it run?" with a query, not a log search
- [ ] Lineage is written on every load, not reconstructed later

## You've got it when you can…

…be asked at 7am whether last night worked, and answer in ten seconds from a query — then say which table you looked at and why.
