# D05 · Six Ways To Move Data

> **Module 3 · Architecture 05** · ~15 min · **the design-review table**

**Diagram:** [`_render/D05-six-ways-to-move-data.html`](_render/D05-six-ways-to-move-data.html)

## What it shows

Every mechanism drawn as **source → mechanism → target**, with the latency each one buys.

> **Latency improves down the list. The control you keep gets worse.**
> Those two move together, and no configuration separates them.

## The six

| Mechanism | Service | Latency | Choose it when |
|---|---|---|---|
| **Batch ETL** | Glue · EMR | hours | you must transform on the way — the medallion default |
| **CDC replication** | AWS DMS | minutes | continuous, and the source hard-deletes |
| **Zero-ETL** | managed integration | min – 1 hr | you want it there with **no pipeline at all** |
| **Federated query** | Redshift · Athena | live | a small lookup against a live database |
| **Streaming** | Kinesis · MSK · Firehose | seconds | genuinely event-driven — rare in retail |
| **File transfer** | Transfer Family · DataSync · AppFlow | scheduled | SFTP drops and SaaS you would rather not code |

## The rule

> **Pick the latency you actually need, then take the most managed option that still gives you it.**

Note the shape of the federated-query row on the diagram: a **dashed arrow with no middle icon**. Nothing is moved. That is the visual reminder that it is a pointer, and that the cost lands on the source system every time somebody runs the query.

## How to use it in a design review

Four questions, in order:

1. **What latency does the *decision* need?** Not what was requested. "Real-time" in a requirements document usually means "not yesterday's". Find out what someone does differently at 9am than at 9pm.
2. **Does the shape need to change on the way?** If yes, managed replication is out for that source.
3. **Who operates it at 3am?** A path with no code has no code to debug, and that has real value.
4. **What happens when volume triples?** Per-row costs and always-on costs scale very differently.

## The comparison that matters for us

Rows one, two and three against the **same Oracle source** — that is D17, and it is a genuine decision with arguments on both sides rather than a preference.

## Checklist

- [ ] I can reproduce the six-row table from memory
- [ ] I can state the latency-versus-control rule in one sentence
- [ ] I know which mechanism reads the source's log rather than its tables
- [ ] I know zero-ETL supports Oracle and SAP, not just Aurora
- [ ] I ask what latency the decision needs, not what was requested
- [ ] I consider who operates it at 3am

## You've got it when you can…

…enter a design review where a mechanism has already been chosen, ask the four questions, and either confirm it with reasons or change it — inside ten minutes.
