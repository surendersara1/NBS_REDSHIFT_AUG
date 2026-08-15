# L16 · Reading Without Copying

> **Module 0 · Lesson 16** · ~45 min

**Slide:** [`_render/L16-reading-without-copying.html`](_render/L16-reading-without-copying.html)

## What it is

An **external schema is a pointer, not a copy**. The table appears inside Redshift and you query it with ordinary SQL — but the bytes never move.

Which means: **the cost moves, it does not vanish.** You have swapped a storage bill and a load job for a per-query bill somewhere else. That is often a good trade. It is never a free one.

Three doors, pointing at three different kinds of thing.

## 1. Spectrum → S3

```sql
CREATE EXTERNAL SCHEMA lake_ext
FROM DATA CATALOG
DATABASE 'silver'
IAM_ROLE 'arn:aws:iam::...:role/redshift-spectrum';
```

Redshift reads files in the lake through the Glue Data Catalog, without loading them.

**Formats it reads:** Parquet, ORC, CSV, JSON, Avro — plus the transactional table formats: **Apache Iceberg**, **Apache Hudi Copy-on-Write**, and **Delta Lake** (via symlink manifest tables).

You can also build a **materialized view over external tables** with incremental maintenance — caching an expensive S3 scan inside the warehouse (Lesson 12).

## 2. Federated query → a live database

```sql
CREATE EXTERNAL SCHEMA live_pg
FROM POSTGRES
DATABASE 'orders' SCHEMA 'public'
URI 'my-aurora-cluster...rds.amazonaws.com'
IAM_ROLE '...' SECRET_ARN '...';
```

Redshift queries an **RDS or Aurora PostgreSQL or MySQL** database *as it is right now*. Filters are **pushed down** to the source, so the remote database does the narrowing rather than shipping everything back.

The catch is the obvious one: this puts analytical load on a production transactional database. Predicate pushdown makes small lookups cheap; it does not make a large scan safe.

## 3. Datashares → another Redshift

Live data from another cluster, account or Region. No copy, no ETL, no lag. The producer creates a datashare, adds objects, and authorises a consumer; the consumer creates a database from it and queries it like any other.

### The correction worth making out loud

**Datashares are no longer read-only.**

```bash
aws redshift authorize-data-share \
  --data-share-arn arn:aws:redshift:...:datashare:.../salesshare \
  --consumer-identifier <consumer> \
  --allow-writes
```

With `--allow-writes`, a consumer can `INSERT` and `UPDATE` the producer's data. Most material written before this landed says datashares are read-only. It is worth knowing, and worth being careful with — cross-account write access is a serious grant.

## When to use which

| Door | Right for |
|---|---|
| **Spectrum** | cold history you scan rarely |
| **Federated query** | small, live lookups |
| **Datashare** | another team's warehouse |

**Never** use federated query for a big analytical scan. You will find out about it from the on-call engineer of the production system, not from your own monitoring.

## In practice

- An external schema exposes S3 Tables data inside Redshift, so Redshift reads Iceberg it never loaded.
- **Gold is loaded; silver is pointed at.** That split is deliberate.
- The rule of thumb: **load what you join hard, point at the rest.**

## Checklist

- [ ] I can write a `CREATE EXTERNAL SCHEMA` for both Spectrum and federated
- [ ] I know which file and table formats Spectrum reads
- [ ] I can explain predicate pushdown and its limits
- [ ] I know datashares support writes, and what flag enables it
- [ ] I would refuse a federated query used for a large scan
- [ ] I know which of our layers is loaded and which is pointed at

## You've got it when you can…

…be asked to "just point Redshift at the production database" for a daily report, explain exactly what that would do to the production database, and offer the right alternative instead.
