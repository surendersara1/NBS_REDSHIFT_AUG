# D03 · The Medallion Layers

> **Module 3 · Architecture 03** · ~15 min

**Diagram:** [`_render/D03-medallion-layers.html`](_render/D03-medallion-layers.html)

## What it shows

Four layers and **the promise each one makes**. The names are not the lesson — plenty of teams have raw/bronze/silver/gold prefixes and no idea what distinguishes them. The lesson is what changes at every boundary.

## The four promises

### RAW — *"we can always rebuild everything from here"*
S3, plain files, exactly as received. Immutable, written once, no schema enforced, kept for years. **Never queried by a report.** This is evidence, not data.

### BRONZE — *"re-running a day changes nothing"*
Iceberg tables. Types applied, columns named, MERGE on the natural key, one row per source record. Still source-shaped — no business meaning has been added yet.

### SILVER — *"a column means the same thing in every table"*
Iceberg tables, conformed and joined. Business rules applied, sources joined into entities, one meaning per column. Read in place by Spectrum rather than copied into the warehouse.

### GOLD — *"the same question gives the same answer twice"*
Redshift tables. Dimensionally modelled, Type 2 history preserved, loaded rather than pointed at. The only layer BI reads.

## What changes at each boundary

> **raw → bronze:** types and a key
> **bronze → silver:** meaning and joins
> **silver → gold:** a model, and a promise about the number

If you cannot say which of those three a piece of logic belongs to, it is in the wrong layer. That single test resolves most "where should this transformation live?" arguments.

## Why raw is never deleted

Because bronze, silver and gold are all **derived**. When a business rule turns out to have been wrong for six months, you fix the rule and reprocess — and nothing was lost, because nothing downstream was ever the only copy (D30).

That property is the entire justification for paying to keep raw. It is not hoarding; it is the second undo button.

## The common failure

Skipping silver. Teams go bronze → gold directly, and the conforming logic ends up duplicated inside three different gold models, drifting apart. The symptom is two dashboards disagreeing about "region", and the cause is that region was defined three times.

## Checklist

- [ ] I can state each layer's promise in one sentence
- [ ] I know what changes at each of the three boundaries
- [ ] I can place a given transformation in the right layer
- [ ] I know why raw is immutable and retained
- [ ] I would notice bronze → gold with no silver

## You've got it when you can…

…be shown a piece of business logic and say which boundary it belongs to — and explain what breaks if it is put one layer too early or too late.
