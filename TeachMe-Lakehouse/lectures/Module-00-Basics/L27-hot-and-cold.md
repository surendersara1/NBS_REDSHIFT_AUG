# L27 · Hot Data, Cold Data

> **Module 0 · Lesson 27** · ~40 min

**Slide:** [`_render/L27-hot-and-cold.html`](_render/L27-hot-and-cold.html)

## What it is

S3 storage classes look like a discount menu. They are really **a bet about how often you will read the data again**.

There is no free tier change. Every step down the ladder moves cost from the monthly storage bill onto whoever runs the next query.

## The ladder

| Class | Retrieval | Use it for |
|---|---|---|
| **S3 Standard** | instant, free | everything you query this quarter |
| **Standard-IA** | instant, charged per GB | read a few times a year |
| **Glacier Instant Retrieval** | instant, charged | archive you must still be able to query |
| **Glacier Flexible Retrieval** | minutes to hours | true archive, occasional restore |
| **Deep Archive** | up to ~12 hours | regulatory retention only |

**S3 Intelligent-Tiering** sits alongside these: it moves objects between tiers based on observed access, for a small monitoring fee per object. It is a reasonable default when access patterns are genuinely unknown — and a poor one when you already know them, because you are paying for a decision you could have made yourself.

## The mistake everyone makes

> **Archiving data you still query is a cost *increase*, not a saving.**

Retrieval is billed. A partition moved to Glacier Instant Retrieval to "save money", which a dashboard then scans every morning, now costs more than it did in Standard — and nobody notices, because the saving appears on the storage line and the cost appears on the retrieval line.

Before any lifecycle rule, ask: **what still reads this?** If the answer is "a report", the rule is wrong.

## The fine print that catches people

- **Retrieval is charged separately**, per GB, and it is not small at the colder tiers
- **Minimum storage durations apply** — deleting an object early still bills you for the minimum period
- **Restores below Instant Retrieval are not instant.** Deep Archive can take most of a day, which means it cannot serve an urgent audit request without notice
- **Per-object monitoring fees** on Intelligent-Tiering make it a poor fit for very many small objects

## A real retention design

| Age | Class | Why |
|---|---|---|
| 0–90 days | **Standard** | actively queried; reprocessing happens here |
| 90 days | **Standard-IA** | occasionally re-read for investigation |
| 1 year | **Glacier Instant Retrieval** | still queryable for audit, rarely touched |
| 7 years | **expire** | retention period ends |

The important property: this is expressed as **lifecycle rules**, not as a person remembering. A retention policy that depends on someone running a script every quarter is not a policy.

## The connection to Lesson 26

Lifecycle rules act on **prefixes**. Which means your partitioning scheme decides what you can tier. Partitioned by date, "everything older than a year" is one rule. Not partitioned by date, it is not expressible at all.

Another reason the prefix convention is a contract, not a preference.

## Checklist

- [ ] I can name the five classes in order and their retrieval behaviour
- [ ] I know retrieval is billed separately
- [ ] I know minimum storage durations exist
- [ ] I ask "what still reads this?" before writing a lifecycle rule
- [ ] I express retention as lifecycle rules, not as a manual process
- [ ] I understand why date partitioning is what makes tiering possible

## You've got it when you can…

…be handed a cost report showing a rising S3 retrieval line, trace it to a lifecycle rule someone added to save money, and explain why it did the opposite.
