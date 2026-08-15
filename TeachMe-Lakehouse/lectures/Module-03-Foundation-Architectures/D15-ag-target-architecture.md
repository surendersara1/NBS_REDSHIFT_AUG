# D15 · Apparel Group — Target Architecture

> **Module 3 · Architecture 15 · proposed** · ~15 min · **the headline picture**

**Diagram:** [`_render/D15-ag-target-architecture.html`](_render/D15-ag-target-architecture.html)

## What it shows

Eight sources, one lakehouse, one warehouse. **The same shape as Tamimi (D09), with the lessons already applied.**

This is the diagram that goes in the proposal. It should be recognisable to anyone who has seen D01, because the point is that this is a known pattern being applied deliberately — not an invention.

## The eight sources, in five classes

| Class | Sources |
|---|---|
| Oracle databases | RMS · SIM · XStore |
| SaaS APIs | Epsilon (PII) · MoEngage |
| E-commerce | Magento — DB or API, to confirm |
| File drops | Vemco · Irisys footfall |

Five classes, **three connector classes** (D16). The variety lives in the specs.

## What we do differently this time

Four things, stated plainly because they are the value of having done this before:

1. **Engine before pipelines.** The spec-driven engine exists before source one, not retrofitted at source five.
2. **Separate state and OIDC trust per environment, from day one** — verified in code, not assumed from comments (D13).
3. **PII masked at the column**, never by keeping a filtered second copy (D19).
4. **The ops console ships with the platform**, not after go-live (D26). It reads the control plane, which exists anyway.

## The open decisions this diagram does not settle

Deliberately, because they need evidence rather than a picture:

- **How the three Oracle sources are ingested** — Glue JDBC, DMS CDC or zero-ETL (D17). Worth a measured spike on one source.
- **Whether Magento is a database or an API.** Affects which connector class it joins.
- **Whether SageMaker is in scope at go-live.** Drawn, but marked "later" — it is a common source of scope creep.

## What is not on this diagram

Streaming. Nothing in the SOW requires it, and drawing it would invite a conversation that costs money and delivers nothing (D24). If it becomes a requirement, it is an addition, not a redesign.

## Checklist

- [ ] I can name the eight sources and their five classes
- [ ] I can name the four things we are doing differently
- [ ] I know which decisions this diagram deliberately leaves open
- [ ] I know why streaming is absent
- [ ] I can present this to a client sponsor in five minutes

## You've got it when you can…

…show this alongside D09 and make the case that we are applying a proven pattern rather than experimenting on their money.
