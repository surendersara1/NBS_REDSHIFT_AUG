# L34 · The Cost And Latency Ladder

> **Module 0 · Lesson 34** · ~35 min · **the closing lesson**

**Slide:** [`_render/L34-cost-and-latency-ladder.html`](_render/L34-cost-and-latency-ladder.html)

## What it is

Everything in this module, placed on two axes: **freshness** and **cost**.

The principle underneath it:

> **Freshness is bought, and it is never bought once.**

Every step up the ladder is a **recurring** cost that someone pays forever. Buy the freshness a decision actually needs, and not one rung more.

## The ladder

| Mechanism | Freshness | What you pay, forever |
|---|---|---|
| **Nightly batch** | yesterday | cheapest per row, most control |
| **Hourly batch** | within the hour | same shape, 24× the compute runs |
| **Zero-ETL · CDC** | minutes | no pipeline to run — and no transform |
| **Federated query** | live | the source system, on every query |
| **Streaming** | seconds | always-on cost, even at 3am on Sunday |

### And the one that goes sideways

A **materialized view** buys read speed in exchange for storage plus a refresh. It does **not** buy freshness — it is at best as fresh as its last refresh. Reaching for an MV to solve a freshness problem is a category error, and a common one.

## The five questions

Ask these before adding anything to an architecture:

### 1. Who reads this, and how often?
Determines whether it earns storage or should be pointed at (Lesson 18). "The finance team, monthly" and "every dashboard, hourly" are different systems.

### 2. How fresh does it truly need to be?
Not what was requested — what the **decision** needs. "Real-time" in a requirements document usually means "not yesterday's". Find out what someone does differently at 9am than at 9pm, and if the answer is nothing, you have a batch requirement.

### 3. Must I transform it on the way?
If yes, managed replication and zero-ETL are out for that source (Lesson 21). This question alone eliminates half the options on most sources.

### 4. Who pays when someone queries it?
Pointer-based designs move the cost onto the querier, or onto someone else's production system (Lesson 31). Make that explicit while it is a design, not a surprise in month three.

### 5. What happens the day it breaks?
Every rung has a different failure. Batch is late. CDC falls behind. Federated query takes production with it. Streaming drops events. Pick the failure you can staff and detect.

## Where you go next

- **Module 1** — how our platform is actually built: the medallion layers, the catalog, the repo.
- **Module 2** — how to build the next one: the decisions, the setup and the reasoning, aimed at the Apparel Group build.

Every architectural choice in those modules is one of the choices on this ladder, made once and lived with. **You now know the vocabulary** — the rest is judgement, and judgement is what the next two modules are for.

## Checklist

- [ ] I can place any mechanism on the ladder
- [ ] I know an MV buys read speed, not freshness
- [ ] I ask "what decision changes?" before accepting a freshness requirement
- [ ] I ask who pays for every pointer-based design
- [ ] I ask what the failure mode is before choosing a rung
- [ ] I can explain the recurring nature of freshness cost to a non-engineer

## You've got it when you can…

…sit in a requirements session, hear "we need it in real time", ask the five questions, and land on the honest answer — which is very often an hourly batch that costs a fraction of what was about to be built.
