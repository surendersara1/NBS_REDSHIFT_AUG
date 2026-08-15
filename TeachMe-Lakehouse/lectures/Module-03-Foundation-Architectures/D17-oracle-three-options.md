# D17 · Oracle — Three Ways In

> **Module 3 · Architecture 17 · the decision** · ~20 min · ⭐ **the one that changes the build**

**Diagram:** [`_render/D17-oracle-three-options.html`](_render/D17-oracle-three-options.html)

## Why this diagram exists

**Three of Apparel Group's eight sources are Oracle**, and they are the three that carry the volume. How we ingest them is the single largest technical decision in the programme.

It is a real decision with real arguments on both sides — not a preference, and not something to settle in a slide.

## Option 1 · Glue JDBC

Oracle → Glue → S3 / Iceberg

- Full transformation control
- **Lands in the lake — medallion intact**
- Cheapest per row at XStore volume
- ⚠️ You build it, and you operate it

**Verdict: the default for all three**, unless the spike says otherwise.

## Option 2 · DMS · CDC

Oracle redo → DMS → S3 / Redshift

- **Catches hard deletes** — usually the decider
- Minutes, not hours
- Almost no query load on the source
- ⚠️ Still a pipeline to operate, plus compaction (D22)

**Verdict: if deletes matter.** Ask of every table, in week one, of someone who knows.

## Option 3 · Zero-ETL

Oracle → managed integration → Redshift **only**

- No pipeline to build or operate
- ⚠️ **Self-managed sources can only target Redshift** — not S3, not S3 Tables, not RMS
- ⚠️ No transformation in flight at all
- ⚠️ Ongoing cost on a very large, high-churn table

**Verdict: spike it first.** One source, measured, before committing.

## The rule

> **Decide per source, not once for the platform.**

XStore's volume argues for Glue. A small, slow-changing reference table argues for zero-ETL — or for not ingesting it at all and **mounting it as a federated catalog** (D06), which is the option people forget entirely.

## The two questions that decide it

1. **Does this source hard-delete rows?** If yes, a watermarked batch pull will drift wrong and never tell you. That points at CDC or zero-ETL.
2. **Does our architecture need it in the lake first?** If yes, zero-ETL is out for a self-managed source, because it can only reach Redshift. That constraint alone eliminates option 3 for anything that must flow through bronze and silver.

Those two questions, asked per source, resolve most of the matrix before anyone runs a benchmark.

## What the spike should measure

Not "does it work" — it will. Measure:

- **Throughput** on the largest table, and what it costs
- **Ongoing cost** at realistic change rates, over a week not an hour
- **Operational surface** — what breaks, how you would know, how you would fix it
- **Where the transformation lands**, and who owns it there

## Checklist

- [ ] I can present all three options with their real limits
- [ ] I know self-managed zero-ETL targets Redshift only
- [ ] I have asked the hard-delete question for every Oracle table
- [ ] I know federated catalog mounting is a fourth option for reference data
- [ ] The decision is per source, and written down with its reason
- [ ] A spike is planned before commitment, with what it measures defined

## You've got it when you can…

…be pushed to "just pick one for all three Oracle sources" and explain, with the two questions, why that would be the wrong shape of decision.
