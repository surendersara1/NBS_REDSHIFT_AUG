# L18 · Copy It, Or Point At It?

> **Module 0 · Lesson 18** · ~40 min · **decide this per table, not once for the platform**

**Slide:** [`_render/L18-copy-or-point.html`](_render/L18-copy-or-point.html)

## The question

> Does this table earn its storage — or is it cheaper to fetch it when someone asks?

Copying costs storage **once** and query time **never**.
Pointing costs storage **never** and query time **every single time**.

Neither is free. The mistake is treating "zero-copy" as if it meant "zero-cost".

## The same table, four ways

### Load it — `COPY` + `MERGE`

- Data lives inside Redshift
- Fastest joins, full SQL, sort keys and distribution work for you
- You store the bytes twice
- As fresh as the last load
- **You pay for:** storage plus the load job
- **Use for:** gold facts and dimensions

### Point at S3 — Spectrum

- Data stays in the lake
- No second copy and no load job to operate
- Slower joins; you scan the files on every query
- As fresh as whatever wrote the files
- **You pay for:** bytes scanned, per query
- **Use for:** cold history

### Point at the OLTP database — federated query

- Data stays in the live database
- Always current — zero lag
- **Puts analytical load on production**
- Filters push down; large scans do not
- **You pay for:** load on the source system
- **Use for:** small live lookups

### Share it — datashare

- Data stays in another warehouse
- Live, no copy, works across accounts and Regions
- Both sides must be Redshift
- Writes are possible with `--allow-writes`
- **You pay for:** the consumer's own compute
- **Use for:** another team's data

## The rule

> **Copy what you join hard and often. Point at what you scan rarely.
> Never point at production for a report that runs every hour.**

## How to actually decide

Four questions, in order:

1. **How often is it queried?** Many times a day → lean toward loading. Twice a month → point at it.
2. **Is it joined, or just filtered?** Heavy joins want co-located data and sort keys. A filtered scan does not.
3. **How fresh must it be?** "Right now" narrows you to federated query or a datashare. "This morning" opens everything.
4. **Who pays, and do they know?** A pointer moves cost onto the querier, or onto someone else's production system. That is a decision to make explicitly, not to discover.

## The trap

Zero-copy architectures demo beautifully and degrade quietly. The failure looks like this: someone points at a source for a small lookup, the report gets popular, the query runs hourly instead of weekly, and six months later a production database is struggling for a reason nobody connects to the dashboard.

The defence is to write down, per external schema, **what it is for and roughly how often it should be hit** — and to alarm when reality diverges.

## In practice

- **Gold is loaded. Silver is pointed at.**
- That is not an accident of implementation; it follows directly from the rule above. Gold is joined hard and queried constantly. Silver is scanned occasionally for reprocessing and investigation.

## Checklist

- [ ] I can state the trade in one sentence each way
- [ ] I know the four options and what each costs
- [ ] I can name who pays for each
- [ ] I decide this per table, not once for the platform
- [ ] I would never point a frequent report at a production database
- [ ] I know why gold is loaded and silver is not

## You've got it when you can…

…design a new dataset's access path in a design review, name who pays for it, and predict what would go wrong if the query frequency went up tenfold.
