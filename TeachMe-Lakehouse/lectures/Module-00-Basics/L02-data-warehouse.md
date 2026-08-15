# L02 · The Data Warehouse

> **Module 0 · Lesson 02** · ~40 min

**Slide:** [`_render/L02-data-warehouse.html`](_render/L02-data-warehouse.html)

## What it is

A data warehouse is a database designed for **analytical** questions rather than transactional ones, where the shape of the data is decided *before* it is loaded.

That trade — flexibility for trust — is the entire point. When the finance team asks "what were sales last quarter?" twice, six weeks apart, they get the same number. That is not an accident; it is what you bought by modelling first.

**On AWS: Amazon Redshift**, either provisioned or Serverless, storing into **Redshift Managed Storage (RMS)** — a storage tier that sits on S3, scales to petabytes, and lets compute and storage scale independently of each other.

## How it works

### Columnar storage

An application database stores a row together, because applications fetch whole rows. A warehouse stores each **column** together, because analytical queries touch a few columns of very many rows.

A query reading 3 columns from a 200-column fact table reads roughly 1.5% of the bytes. That single design decision is most of the performance difference.

### MPP — massively parallel processing

The table is split across **slices**, and the same query plan runs on every slice simultaneously. Adding compute adds parallelism. This is why a warehouse can scan a billion rows in seconds and an application database cannot.

### Schema on write

Types, keys and grain are fixed at load time. Bad rows fail on arrival, where someone is watching, rather than six months later inside a board report.

### RMS — separating storage from compute

Older warehouses coupled the two: more storage meant more nodes whether you needed the CPU or not. RMS decouples them. You size compute for your query load and let storage grow on its own.

## When to use it

**Use a warehouse for:**
- Repeatable business reporting where consistency matters more than flexibility
- Numbers that have to reconcile against each other and against source systems
- Queries that join across many dimensions

**Do not use it for:**
- Raw, unmodelled or unknown-shape data — that belongs in the lake (Lesson 03)
- Machine-learning feature engineering on unstructured input
- Anything you have not yet decided the meaning of

## The thing that surprises SQL developers

`SELECT` is fast **because you paid the cost at load time**. There is no magic. Everything that makes reads fast — sorting, distribution, compression, modelling — is work done during the load. A warehouse where loading is cheap and querying is slow has been built backwards.

## In practice

On our platforms:
- **Redshift Serverless holds the gold layer only** — modelled facts and dimensions.
- **Bronze and silver stay in Iceberg on S3**, because they are not yet trustworthy enough to be warehouse tables and re-reading them is cheap.
- **Power BI reads Redshift, never the lake.** The warehouse is the trust boundary.

The rule to take away: *gold = modelled = trusted.* If something has not been modelled, it does not belong in the warehouse yet.

## Checklist

- [ ] I can explain columnar storage to someone who only knows row storage
- [ ] I can explain why MPP makes big scans fast
- [ ] I can say what schema-on-write buys and what it costs
- [ ] I know what RMS is and why separating storage from compute matters
- [ ] I know which layer of our platform lives in Redshift, and which does not

## You've got it when you can…

…explain to an application developer why the database pattern they already know — normalise, index, query — produces a *slow* warehouse, and what you do instead.
