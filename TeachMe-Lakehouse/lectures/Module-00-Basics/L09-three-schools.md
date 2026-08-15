# L09 · Three Schools Of Warehouse Design

> **Module 0 · Lesson 09** · ~40 min

**Slide:** [`_render/L09-three-schools.html`](_render/L09-three-schools.html)

## What it is

Three named schools of warehouse design. You will meet all three in interviews, RFPs and consultancy decks. They agree on the destination — business users querying trustworthy tables — and disagree about **what you build first and how much you model up front**.

## Kimball — bottom-up

Build the **marts first**, one business process at a time. Sales this quarter, stock next quarter. Each mart is a star schema, designed for querying.

- **Strength:** fast to first value, and business users can understand the model
- **Weakness:** marts drift apart unless you enforce **conformed dimensions** across them
- **On AWS:** dbt marts on Redshift

## Inmon — top-down

Build one **normalised 3NF core** for the whole enterprise first. Marts are then derived from that core.

- **Strength:** single version of truth by construction, not by discipline
- **Weakness:** slow to first value; needs a large modelling effort before anyone sees a dashboard
- **On AWS:** a 3NF core schema in Redshift, marts built from it

## Data Vault — audit-first

Model as **hubs** (business keys), **links** (relationships) and **satellites** (attributes with history).

- **Strength:** built for change and full auditability; every source keeps its own lineage and history
- **Weakness:** a great many tables; genuinely needs code generation and strong tooling
- **On AWS:** generated dbt models

## Which one we use, and why

Modern lakehouses come out **Kimball-shaped at the gold layer**.

The reason is structural, not fashion: bronze and silver already hold the raw, historical, source-shaped data that Inmon's 3NF core and Data Vault's satellites exist to preserve. The lake does that job now. So the warehouse layer is free to be purely about *making questions easy to ask* — which is exactly what Kimball is for.

Put another way: the medallion architecture already gave you the top-down layer. Building a second one inside the warehouse is paying twice.

## When the other two are right

- **Inmon** — a very large enterprise with many source systems feeding one regulated definition of a customer or a product, where the cost of inconsistency is higher than the cost of delay.
- **Data Vault** — heavy regulation, where you must be able to prove where any value came from and what it was at any past moment, across many changing sources.

Both are legitimate. Neither is what a retail group with eight sources and a reporting mandate needs.

## Checklist

- [ ] I can describe each school in one sentence
- [ ] I can say what each optimises for and what it costs
- [ ] I can explain why lakehouses land on Kimball at the gold layer
- [ ] I can name a situation where Inmon or Data Vault would be right
- [ ] I would not be intimidated by a vendor deck built on one of them

## You've got it when you can…

…hear a consultant propose Data Vault, understand what they are actually optimising for, and either agree with a reason or decline with one — rather than nodding because the diagram looked authoritative.
