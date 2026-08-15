# L17 · Who Is Actually Allowed

> **Module 0 · Lesson 17** · ~45 min

**Slide:** [`_render/L17-permissions.html`](_render/L17-permissions.html)

## What it is

Two permission systems govern one platform:

- **Redshift** governs its own tables.
- **Lake Formation** governs everything read **through the catalog**.

> If two systems can grant access to the same table, you must know which one wins.

That sentence is the single most common source of "it works for me but not for them" on a lakehouse. Learn where the boundary sits before you debug it at speed.

## Four layers, from the database outwards

### 1. Redshift roles

Users, groups and **roles**. `GRANT` on schemas and tables, plus:

- **Row-level security (RLS)** — a policy limits which rows a role can see
- **Column-level security (CLS)** — `GRANT SELECT (col_a, col_b)` rather than on the whole table

```sql
CREATE ROLE bi_reader;
GRANT USAGE ON SCHEMA reporting TO ROLE bi_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA reporting TO ROLE bi_reader;
```

Grant to **roles**, never to individual users. A user who leaves should be removed from a role, not audited for scattered grants.

### 2. IAM authentication

Federated login through IAM or IAM Identity Center instead of database passwords. The identity decides what the session may do, and there is no shared secret to rotate or leak.

### 3. Lake Formation

Grants at **catalog → database → table → column** level, and — this is the important part — **enforced by every engine that reads through the catalog**. Athena, Spark, EMR and Redshift Spectrum all honour the same grant.

Define the permission once; it applies everywhere. That is the whole value proposition, and it is why the catalog matters as much as the storage.

### 4. The reader/writer split

The pattern that matters more than any individual grant:

- The **ETL role** writes. It is assumed by jobs, never by people.
- The **BI role** reads reporting views. Not base tables, not writes.
- **No human account holds both.**

## Where the boundary sits

| Object | Governed by |
|---|---|
| Redshift-native tables and views | Redshift `GRANT` |
| External tables read via the catalog | **Lake Formation** |
| S3 Tables / Iceberg via the catalog | **Lake Formation** |
| Datashares | Redshift, plus Lake Formation for LF-managed shares |

When someone can query a table in Athena but not through Spectrum — or the reverse — this table is where you start.

## Rules of thumb

- Grant to **roles**, never to individual users
- Mask PII at the **column**, not in the report — a report-level filter is not a control
- Expose **views** to BI, never base tables
- **Never** share one superuser between people or between jobs

## In practice

- Epsilon customer data is **PII**. It is masked at the column level, with grants — not by maintaining a separate filtered copy, which would be a second thing to keep correct.
- Every role is defined in **Terraform**, never clicked in the console. Access is code, and it is reviewed like code.

That last point is not bureaucracy. An access grant made in the console has no author, no reason and no review — and nobody will ever dare remove it.

## Checklist

- [ ] I know which system governs which kind of object
- [ ] I grant to roles, never to users
- [ ] I can write a column-level grant
- [ ] I know what RLS and CLS are and when to reach for each
- [ ] I can explain the reader/writer split and why no human holds both
- [ ] I know that our roles live in Terraform, and why that matters

## You've got it when you can…

…debug "she can see it in Athena but not in Redshift" by asking which system owns that object — and fix it in the right place rather than by adding another grant somewhere and hoping.
