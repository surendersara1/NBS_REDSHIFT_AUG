# D02 · Four Paradigms, Four Architectures

> **Module 3 · Architecture 02** · ~15 min

**Diagram:** [`_render/D02-four-paradigms.html`](_render/D02-four-paradigms.html)

## What it shows

The four words from Module 0 — warehouse, lake, lakehouse, mesh — drawn as the **services each one actually resolves to on AWS**. Definitions are easy to nod along to; four stacks side by side are harder to be vague about.

## The four stacks

| | Warehouse | Lake | **Lakehouse** | Mesh |
|---|---|---|---|---|
| Source | RDS / OLTP | any files | S3 Tables | — |
| Middle | ETL, model first | S3, cheap and immutable | Glue / EMR, MERGE not append | Lake Formation + RAM |
| Store | Amazon Redshift | Glue Data Catalog | Redshift, gold only | Redshift datashares |
| Read | BI, trusted numbers | Athena, per TB scanned | many engines, one table | domain teams |
| **You buy** | **trust** | **optionality** | **both** | **autonomy** |

## The one that matters

**Lakehouse.** Lake economics with warehouse guarantees, bridged by an open table format. It is what Tamimi is and what Apparel Group will be.

The reason is not fashion. With eight unfamiliar source systems you will be wrong about the meaning of fields, repeatedly. A pure warehouse makes every correction a migration; a pure lake cannot give finance a number they will sign. A lakehouse lets you land cheaply and model the part that needs modelling, without moving the data to do it.

## Mesh is drawn dashed on purpose

Because it is not a place to put data. It is an ownership model that sits **on top of** one of the other three. The AWS pieces are real — Lake Formation grants over RAM, datashares, federated catalogs (D27) — but they implement the sharing, not the organisation.

Learn it so that when it is proposed you can ask the useful question: *which domain teams would own which products, and who is on call for them?*

## The trade to say out loud

Every option has a characteristic bad day:

- **Warehouse** — a schema migration nobody scoped.
- **Lake** — discovering the file format changed upstream two months ago.
- **Lakehouse** — compaction, snapshot expiry, and a catalog that must be kept correct.
- **Mesh** — a domain team that stopped answering.

Choose the bad day you can staff.

## Checklist

- [ ] I can name what each option *buys* in one word
- [ ] I can name the AWS services in each stack
- [ ] I can explain why a lakehouse suits eight unfamiliar sources
- [ ] I know why mesh is drawn dashed
- [ ] I can name each option's characteristic bad day

## You've got it when you can…

…sit in a design review where four people advocate four architectures and reframe it from "which is best" to "which trade-off are we willing to operate".
