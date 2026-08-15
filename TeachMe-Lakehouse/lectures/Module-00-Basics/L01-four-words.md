# L01 · Four Words For Where Data Lives

> **Module 0 · Lesson 01** · ~40 min

**Slide:** [`_render/L01-four-words.html`](_render/L01-four-words.html)

## What it is

You are going to hear four words this week — **data warehouse**, **data lake**, **lakehouse**, **data mesh** — and you will hear them used as if they were interchangeable, or as if they were stages you graduate through. They are neither.

They are four different answers to the same question: *where does the organisation's data live, and on what terms?* Most companies run more than one of them at once, deliberately.

The reason the words feel slippery is that vendors blur them. Every product is marketed as whichever word is currently fashionable. So instead of memorising definitions, learn the four questions that actually separate them — then you can classify any system, including ones that have not been invented yet.

## The four questions

### 1. Schema — who decides the shape, and when?

- **Schema on write** — the shape is fixed before data is allowed in. Anything that does not fit is rejected at the door.
- **Schema on read** — data lands as it arrives; meaning is applied by whoever queries it later.

This one question drives most of the others. Schema-on-write buys you trust and costs you flexibility. Schema-on-read is the reverse.

### 2. Access — who is allowed to read it, and at what grain?

Not "is there security" — everything has security. The real question is the *granularity*: can you grant one team access to one column of one table, or is the smallest unit "the whole database"? A system that can only grant whole databases will eventually force people to make copies, and copies are where governance goes to die.

### 3. Cost — what does one query cost, and who pays?

Two very different billing models:
- **Per hour of compute** — you rent a cluster; queries are then "free". Someone runs an accidental cross join and nobody notices.
- **Per terabyte scanned** — each query has a price. A badly written query is *visibly* expensive, which changes behaviour.

Neither is better. But they produce completely different engineering cultures, and you should know which one you are in.

### 4. Ownership — who owns the data?

- **Central** — one data team owns every pipeline and every table.
- **Federated** — the domain that produces the data owns it, publishes it, and is on call for it.

This is an organisational question wearing a technical costume, which is exactly why Lesson 05 exists.

## The short answer

| Word | One sentence |
|---|---|
| **Warehouse** | Modelled, trusted, expensive — schema on write |
| **Lake** | Cheap, raw, needs governing — schema on read |
| **Lakehouse** | One store, both behaviours — a table format bridges them |
| **Mesh** | An ownership model, not a place to put data |

Three of them are places. One of them is a rule about who holds the keys. Confusing that is the single most common mistake in this whole vocabulary.

## In practice

Both the Tamimi platform and the Apparel Group platform being designed are **lakehouses**: S3 for storage, Apache Iceberg for table behaviour, Redshift for the modelled reporting layer.

Neither is a mesh. One platform team owns everything end to end. That is the right call at this size, and Lesson 05 explains why.

## Checklist

- [ ] I can state the four separating questions without looking
- [ ] I can classify a system I am shown by answering them
- [ ] I know which of the four words describes ownership rather than storage
- [ ] I can name what our platform is, and why

## You've got it when you can…

…be shown an unfamiliar architecture diagram and say, in one sentence each, where its schema is decided, how finely access can be granted, who pays per query, and who owns the data — and then name which of the four words applies, without anyone having told you.
