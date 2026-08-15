# L19 · Eight Kinds Of Source

> **Module 0 · Lesson 19** · ~40 min

**Slide:** [`_render/L19-source-taxonomy.html`](_render/L19-source-taxonomy.html)

## What it is

Classify the source **before** you choose the pipeline. The class decides the mechanism — and every project turns out to have more classes than the kick-off deck admitted.

The payoff is direct: eight sources reduce to about five classes, and five classes reduce to three connectors. The variety lives in the configuration, not in a hundred bespoke jobs.

## The taxonomy

| Kind | What makes it hard | How you move it | Apparel Group |
|---|---|---|---|
| **OLTP relational** | huge tables, live load, no downtime window | JDBC batch · CDC · zero-ETL | RMS · SIM · XStore |
| **SaaS API** | rate limits, cursor paging, no bulk export | API pull · AppFlow · zero-ETL | Epsilon · MoEngage |
| **E-commerce** | sometimes a DB, sometimes an API, sometimes both | JDBC or API | Magento |
| **File drop** | arrives late, arrives twice, or not at all | S3 landing · Transfer Family | Vemco · Irisys |
| **Streams & events** | unbounded; ordering and duplicates both matter | Kinesis · MSK · Firehose | none today |
| **Logs & clickstream** | enormous volume, very low value per row | Firehose to S3, partitioned | web analytics |
| **On-prem** | behind a firewall; needs a network path first | VPN / Direct Connect + Glue | legacy stores |
| **Third-party feed** | you do not control the schema, and it will change | contract + validate on landing | market data |

## What each class demands of you

### OLTP relational
The question that decides everything: **does the source hard-delete rows?** If it does, a timestamp-based batch pull will silently drift wrong and never tell you — see Lesson 22. Ask this on day one, of every relational source.

Also ask: is there a reliable modification timestamp, is it indexed, and is it set by the database or by the application? Application-set timestamps lie.

### SaaS API
Rate limits and paging are the whole engineering problem. Assume the API will be slow, will page inconsistently, and will change without notice. Budget for full reloads being impossible.

### File drop
The three failure modes are in the table: late, twice, and never. All three are normal. Design for them rather than treating each as an incident — idempotent loads make "twice" harmless and a freshness alarm makes "never" visible.

### On-prem
The network path is a **prerequisite, not a task**. It is procured, not coded, and it has a lead time measured in weeks. Raise it in week one or it becomes the critical path in week nine.

### Third-party feed
You do not control the schema. So write down the contract you expect, validate against it on landing, and fail loudly when reality diverges — rather than discovering it downstream in a report.

## In practice

Eight Apparel Group sources, five classes, **three connectors**:

- Three Oracle databases → **one Oracle JDBC connector**
- Two cursor-paged SaaS APIs → **one API connector**
- Two footfall file feeds → **one file-drop connector**
- Magento → whichever of the first two it turns out to be

## Checklist

- [ ] I can classify a new source in under a minute
- [ ] I ask about hard deletes on every relational source
- [ ] I ask about rate limits and paging on every API source
- [ ] I raise network access for on-prem sources in week one
- [ ] I know how many connector classes our eight sources actually need
- [ ] I write a contract for feeds whose schema I do not control

## You've got it when you can…

…be handed a list of source systems you have never seen, group them into classes, and estimate the work as "N connectors plus one spec per table" — instead of "N pipelines".
