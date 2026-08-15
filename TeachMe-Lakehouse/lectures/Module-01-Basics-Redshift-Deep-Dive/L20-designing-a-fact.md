# L20 · Designing A Fact And Its Dimensions

> **Module 01 · Lesson 20** · ~50 min · **the Part C worked example**

**Slide:** [`_render/L20-designing-a-fact.html`](_render/L20-designing-a-fact.html)

## What it is

Everything in Part C, applied once, end to end. Six decisions **in order** — and the first one is a sentence, not a keyword.

## 1 · State the grain

> **"One row = one line on one receipt."**

Say it out loud before typing `CREATE TABLE`. Every later argument about a number is really an argument about this sentence.

**One grain per fact table.** Mixing "one row = one receipt line" with "one row = one receipt" in the same table guarantees double counting that nobody can explain six months later.

## 2 · Choose the columns

Three kinds, and nothing else:

- **Measures** — numbers you sum: `quantity`, `net_amount`, `vat_amount`
- **Foreign keys** — surrogate keys to dimensions: `store_sk`, `product_sk`, `date_sk`
- **Degenerate dimensions** — identifiers with no attributes of their own: `receipt_no`

Plus operational columns: `merge_key` for idempotent loads (L24), `loaded_at` for lineage.

## 3 · Choose the DISTKEY — the busiest join

Not the primary key by reflex. The column this table is **most often joined on**, with enough distinct values to spread evenly across slices.

```sql
-- check cardinality and look for a dominant value
SELECT COUNT(DISTINCT store_sk) AS distinct_vals, COUNT(*) AS rows
FROM   staging.sales_line;

SELECT store_sk, COUNT(*) FROM staging.sales_line
GROUP BY 1 ORDER BY 2 DESC LIMIT 10;
```

## 4 · Choose the SORTKEY — the always-filter

The column in every `WHERE` clause. For retail facts, `sale_date`.

Sorting on an **ever-increasing** column also means new rows land where they belong, so the table drifts unsorted slowly rather than fragmenting on every load (L16).

## 5 · Dimensions get DISTSTYLE ALL

Small, slow-changing dimensions get a full copy on every node, so every join to them is local.

## 6 · Then test it

Nothing else will check uniqueness (L18).

## The complete example

```sql
-- ── dimensions ──────────────────────────────────────────────────
CREATE TABLE gold.dim_date (
    date_sk      INTEGER      NOT NULL,
    full_date    DATE         NOT NULL,
    fiscal_year  SMALLINT     NOT NULL,
    fiscal_week  SMALLINT     NOT NULL,
    day_name     VARCHAR(9)   NOT NULL,
    is_weekend   BOOLEAN      NOT NULL,
    PRIMARY KEY (date_sk)
)
DISTSTYLE ALL
SORTKEY (date_sk);

CREATE TABLE gold.dim_store (
    store_sk     BIGINT       NOT NULL,
    store_id     VARCHAR(20)  NOT NULL,   -- business key
    store_name   VARCHAR(120),
    region       VARCHAR(32),
    valid_from   TIMESTAMP    NOT NULL,   -- Type 2
    valid_to     TIMESTAMP,
    is_current   BOOLEAN      NOT NULL,
    PRIMARY KEY (store_sk)
)
DISTSTYLE ALL
SORTKEY (store_sk);

-- ── the fact ────────────────────────────────────────────────────
CREATE TABLE gold.fct_sales_line (
    sale_date    DATE           NOT NULL ENCODE raw,     -- sort key: leave raw
    date_sk      INTEGER        NOT NULL ENCODE az64,
    store_sk     BIGINT         NOT NULL ENCODE az64,    -- dist key
    product_sk   BIGINT         NOT NULL ENCODE az64,
    receipt_no   VARCHAR(32)             ENCODE zstd,    -- degenerate dim
    line_no      SMALLINT                ENCODE az64,
    quantity     DECIMAL(12,3)           ENCODE az64,
    net_amount   DECIMAL(14,2)           ENCODE az64,
    vat_amount   DECIMAL(14,2)           ENCODE az64,
    merge_key    VARCHAR(64)    NOT NULL ENCODE zstd,
    loaded_at    TIMESTAMP      DEFAULT SYSDATE
)
DISTSTYLE KEY
DISTKEY  (store_sk)
COMPOUND SORTKEY (sale_date, store_sk);
```

## Verify after the first real load

```sql
-- 1. did the distribution work out?
SELECT "table", diststyle, sortkey1, skew_rows, unsorted, stats_off, size AS mb
FROM   svv_table_info
WHERE  "schema" = 'gold'
ORDER  BY tbl_rows DESC;

-- 2. is the join co-located?
EXPLAIN
SELECT s.region, SUM(f.net_amount)
FROM   gold.fct_sales_line f
JOIN   gold.dim_store      s USING (store_sk)
GROUP  BY 1;
-- want: DS_DIST_ALL_NONE or DS_DIST_NONE.  not: DS_BCAST_INNER

-- 3. are zone maps skipping?
SELECT SUM(blocks_read) AS read, SUM(blocks_skipped) AS skipped
FROM   stl_scan WHERE query = pg_last_query_id();

-- 4. is the key actually unique?
SELECT COUNT(*) AS rows, COUNT(DISTINCT merge_key) AS keys
FROM   gold.fct_sales_line;
```

Those four checks, in that order, after the first load of any new fact table.

## The design review questions

Ask these of any table design, including your own:

1. What is the grain, in one sentence?
2. Why that `DISTKEY`? What is the cardinality, and is there a dominant value?
3. Why that `SORTKEY`? Is it in every `WHERE` clause?
4. Which dimensions are `ALL`, and are they small enough to stay that way?
5. What tests uniqueness?
6. What would have to happen for this design to be wrong, and how would we notice?

## Gotchas

- **Two grains in one fact** — guaranteed double counting.
- **A `DISTKEY` chosen because it was the PK** rather than because it is joined on.
- **A `SORTKEY` on a column nobody filters** — pure cost.
- **Forgetting the fourth check.** Duplicates are silent (L18).
- **No `merge_key`** — the load cannot be made idempotent later without a rebuild.

## Checklist

- [ ] Grain written down as a sentence, in the model documentation
- [ ] One grain per fact table
- [ ] `DISTKEY` justified by join frequency and cardinality
- [ ] `SORTKEY` is the always-filter column, first
- [ ] Small dimensions are `DISTSTYLE ALL`
- [ ] `merge_key` exists from day one
- [ ] All four post-load checks run after the first real load
- [ ] A uniqueness test exists and runs on every build

## You've got it when you can…

…be handed a source table you have never seen, produce a fact-and-dimension design in twenty minutes, and defend every one of the six decisions in a review — including what would make each of them wrong.
