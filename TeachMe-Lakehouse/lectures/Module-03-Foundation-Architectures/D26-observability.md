# D26 · Observability And The Ops Console

> **Module 3 · Architecture 26 · deep dive** · ~20 min

**Diagram:** [`_render/D26-observability.html`](_render/D26-observability.html)

## What this pattern is for

Two completely different questions, which need two completely different paths:

- **"Something is broken, wake someone."**
- **"Did last night work?"** — asked at 9am, by someone who does not want to open CloudWatch.

A platform with only the first path forces every routine question through a person. That person becomes the observability layer, and they get tired.

## The nine steps

**1 · Jobs emit structured logs.** Not `print()`. Structured events with the run id, source, table and row counts, so they can be queried rather than read.

**2 · Metrics come out alongside.** Duration, rows processed, watermark lag. Metrics are what you alarm on; logs are what you read afterwards to find out why.

**3 · Alarm on stale, not only on failed.** ⭐ The dangerous state is **silence**. A job that failed loudly gets fixed by lunchtime; a job that stopped being scheduled three weeks ago and never errored is the one that puts a wrong number in a board pack. Alarm on **freshness** — "this table has not been updated in N hours" — as well as on error.

**4 · SNS routes to the on-call rota.** Not to a shared mailbox nobody owns. An alert with no named recipient is a log line with extra steps.

**5 · The alert carries a runbook link.** ⭐ An alarm that says "GlueJobFailed" and nothing else costs the responder twenty minutes of orientation. One line — *what this means, what to check first, how to re-run safely* — turns a page into a task.

**6 · The answer path starts at the control plane.** Run state already lives in DynamoDB (D08): what ran, when, how long, with what outcome. Nothing extra needs to be collected.

**7 · A read-only API in front of it.** Small, read-only, deployed per environment. It cannot start, stop or retry anything — that constraint is what makes it safe to give out.

**8 · The ops console reads it.** ⭐ **One console per environment**, not a global one with an environment switcher. Prod has its own, with its own access. The switcher is how someone reads dev numbers in a prod incident.

**9 · The team lead answers without asking anyone.** Which is the actual measure of success. If "did XStore load?" still requires a message to an engineer, the console has not landed regardless of how good it looks.

## Optionally in the middle

**Amazon Managed Grafana** is a reasonable middle step: better than raw CloudWatch dashboards, far cheaper than building a console. The two-tier plan is Grafana first, custom console when the audience is non-technical.

## The two-path rule

| | Alert path | Answer path |
|---|---|---|
| Trigger | something broke | someone asked |
| Latency | seconds | whenever |
| Audience | on-call engineer | team lead, analyst, client |
| Ends in | a page with a runbook | a screen with a number |
| Cost of missing it | an incident | everyone messages an engineer |

## What breaks if you skip a piece

- **No freshness alarm** — silent staleness, discovered in a report.
- **No runbook link** — every page starts from zero.
- **No answer path** — routine questions become interruptions.
- **A global console** — someone reads the wrong environment during an incident.

## On Apparel Group

Ship the console **with** the platform, not after it. It reads the control plane, which exists from day one anyway, so the marginal cost is small — and it is what makes handover (M05) possible at all.

## Checklist

- [ ] Logs are structured and carry the run id
- [ ] Metrics include duration, rows and lag
- [ ] There is a **freshness** alarm, not only a failure alarm
- [ ] Alerts route to a named rota
- [ ] Every alarm has a runbook line
- [ ] Run state is queryable, not only logged
- [ ] The console is read-only and per-environment

## You've got it when you can…

…point at a table that has been silently stale for three days and show the alarm that would have caught it — then explain why nobody noticed without it.
