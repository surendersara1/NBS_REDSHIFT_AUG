# L15 · Getting Data Out Again

> **Module 0 · Lesson 15** · ~35 min

**Slide:** [`_render/L15-getting-data-out.html`](_render/L15-getting-data-out.html)

## What it is

A warehouse that only lets people in through one door becomes the exact bottleneck it was built to remove.

Four different kinds of consumer want the same numbers, and none of them wants them the same way. Give each the right exit and they stop building workarounds — because **every unofficial copy of your data started life as a missing door**.

## The four exits

### 1. UNLOAD — the most overlooked

```sql
UNLOAD ('SELECT * FROM gold.fct_sales_line WHERE sale_date >= ...')
TO 's3://bucket/published/fct_sales_line/'
IAM_ROLE 'arn:aws:iam::...:role/redshift-unloader'
FORMAT AS PARQUET
PARTITION BY (sale_date);
```

Writes query results to S3 as Parquet. This is how **gold data gets republished back to the lake** so cheaper engines — Athena, Spark, a data scientist's notebook — can read it without touching the warehouse at all.

Publishing gold back to S3 is what stops Redshift from becoming the only way to the data. It is the single highest-leverage thing in this lesson.

### 2. JDBC / ODBC — the BI path

Power BI, Tableau and QuickSight all connect this way.

**Point them at views, never at raw fact tables.** A view is a contract: you can restructure the model underneath it, add a column, change a distribution key, and the report keeps working. Point a report at a base table and you have frozen your schema by accident.

Late-binding views are useful here: they are not bound to the underlying objects until query time, so you can rebuild the model beneath them without dropping and recreating the view.

### 3. Data API — for applications

HTTP calls, no driver, no persistent connection. The right choice from Lambda, Step Functions, and any application that would otherwise need VPC plumbing and a connection pool to talk to the warehouse.

### 4. Engines and ML

Glue, EMR and Spark read frames straight out through the Redshift connector. **Redshift ML** trains and scores without the data leaving the warehouse at all.

## Picking by consumer

| Consumer | Exit |
|---|---|
| Dashboards | JDBC onto **views** |
| Applications and Lambda | Data API |
| Other engines, data science | `UNLOAD` to Parquet |
| ML training | Spark connector or Redshift ML |

**Never** let BI tools query the fact tables directly. It looks like it works right up until you need to change the model.

## In practice

- Power BI reads **reporting views only**.
- Views are **late-binding**, so models can be rebuilt beneath them.
- The BI role has `SELECT` on views and nothing else — no base tables, no write.

That last point is worth stating: the reader/writer split (Lesson 17) is enforced through which objects each role can even see.

## Checklist

- [ ] I know `UNLOAD` exists and what publishing gold back to S3 buys
- [ ] I point BI at views, never base tables, and can say why
- [ ] I know why late-binding views help
- [ ] I use the Data API from Lambda rather than a JDBC driver
- [ ] I can name what the BI role is permitted to do
- [ ] I can spot an unofficial data copy and name the missing door that caused it

## You've got it when you can…

…find a spreadsheet someone maintains by hand from a weekly CSV export, work out which exit was missing, and replace it — instead of just asking them to stop.
