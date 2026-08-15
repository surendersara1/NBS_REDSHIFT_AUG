# L32 · Dates, Times and Time Zones

> **Module 01 · Lesson 32** · ~35 min

**Slide:** [`_render/L32-dates-and-timezones.html`](_render/L32-dates-and-timezones.html)

## What it is

Tamimi runs in **Asia/Riyadh** (UTC+3, no daylight saving). Redshift runs in **UTC**.

Every "yesterday's sales are wrong" ticket you will ever get lives in that three-hour gap.

**The rule: store UTC, convert once, at the reporting boundary.**

A *business day* is a local-time concept. A *timestamp* is a physical instant. Keep them apart, and name every column so nobody has to guess which one they are holding.

## 1 · TIMESTAMP vs TIMESTAMPTZ — pick one, everywhere

| Type | Stores a zone? | On write | On read |
|---|---|---|---|
| `TIMESTAMP` | No | Value stored verbatim | Returned verbatim |
| `TIMESTAMPTZ` | No (normalised) | Converted to UTC using the session zone | Rendered in the session zone |

`TIMESTAMP` is by far the more common choice in a warehouse, precisely *because* it does nothing clever — you write UTC, you read UTC, no session setting can change what you get back.

`TIMESTAMPTZ` is convenient for ingest from an application that sends offsets, but it makes the value you read depend on the reader's session zone. That is fine for a human at a console and dangerous inside an ETL job.

**Mixing them across tables causes silent drift.** Pick one convention for the whole warehouse and write it in the standards doc.

```sql
-- the convention this course teaches
sold_at_utc   TIMESTAMP     NOT NULL,   -- the instant, always UTC
sale_date     DATE          NOT NULL,   -- the LOCAL business day, precomputed
loaded_at_utc TIMESTAMP     NOT NULL DEFAULT GETDATE()
```

Precomputing `sale_date` at load time is deliberate: it is your `SORTKEY`, and it lets every downstream query filter on a bare column.

## 2 · Naming: the cheapest fix in this lesson

```
❌ date, time, timestamp, created, dt
✅ sold_at_utc, sale_date_local, loaded_at_utc, valid_from_utc
```

A column called `date` has caused more incorrect reports than any optimiser bug. Suffix every timestamp with `_utc` and every local-day column with `_local` or nothing-but-`_date`, and half the class of problem disappears.

## 3 · Converting

`CONVERT_TIMEZONE(source_zone, target_zone, timestamp)`:

```sql
SELECT sold_at_utc,
       CONVERT_TIMEZONE('UTC', 'Asia/Riyadh', sold_at_utc)                    AS sold_at_local,
       DATE_TRUNC('day',
         CONVERT_TIMEZONE('UTC', 'Asia/Riyadh', sold_at_utc))::DATE           AS sale_date_local
FROM   staging.sales_line;
```

Two-argument form assumes the input is UTC — `CONVERT_TIMEZONE('Asia/Riyadh', sold_at_utc)`. Prefer the three-argument form; it documents the assumption.

**Truncate the converted local time, never the raw UTC value.** `DATE_TRUNC('day', sold_at_utc)` gives you a UTC day, which starts at 03:00 Riyadh time — so three hours of every evening's trade lands on the wrong day.

## 4 · The grain: DATE_TRUNC

```sql
DATE_TRUNC('day',   ts)   -- 2026-08-10 00:00:00
DATE_TRUNC('week',  ts)   -- Monday-start week
DATE_TRUNC('month', ts)   -- 2026-08-01 00:00:00
DATE_TRUNC('quarter', ts)
```

⚠️ **`DATE_TRUNC('week', …)` starts on Monday.** In Saudi Arabia the working week starts Sunday. Do not fight this in SQL — put the answer in `dim_date`.

Also useful:

```sql
DATEDIFF('day', a, b)          -- integer difference, note the unit comes FIRST
DATEADD('month', -1, sale_date)
LAST_DAY(sale_date)
EXTRACT(hour FROM sold_at_utc)
TO_CHAR(sale_date, 'YYYY-MM')   -- for labels only, never for filtering
```

⚠️ **`DATEDIFF` counts boundary crossings, not elapsed time.** `DATEDIFF('day', '2026-08-10 23:00', '2026-08-11 01:00')` is `1`, from two hours apart.

## 5 · A real date dimension

Fiscal periods, Ramadan, Eid, weekends that start Friday, retail 4-4-5 calendars — **none of that is derivable from a timestamp.** It belongs in a table.

```sql
CREATE TABLE gold.dim_date (
    date_key           DATE     NOT NULL,   -- the local business day
    day_of_week        SMALLINT NOT NULL,
    day_name           VARCHAR(9)  NOT NULL,
    is_weekend         BOOLEAN  NOT NULL,   -- Fri/Sat here, not Sat/Sun
    week_start_sunday  DATE     NOT NULL,
    month_num          SMALLINT NOT NULL,
    month_name         VARCHAR(9)  NOT NULL,
    quarter_num        SMALLINT NOT NULL,
    year_num           SMALLINT NOT NULL,
    fiscal_year        SMALLINT NOT NULL,
    fiscal_period      SMALLINT NOT NULL,
    hijri_date         VARCHAR(20),
    is_ramadan         BOOLEAN  NOT NULL DEFAULT FALSE,
    is_public_holiday  BOOLEAN  NOT NULL DEFAULT FALSE,
    holiday_name       VARCHAR(60)
)
DISTSTYLE ALL                  -- tiny, joined by everything
SORTKEY (date_key);
```

`DISTSTYLE ALL` is exactly right here: a few thousand rows, joined by every query. See L15.

**It also acts as your date spine** — the thing that lets a report show a day with zero sales, which no amount of clever SQL over the fact table can do (L33).

## 6 · Sargable predicates only

Wrapping the sort column in a function defeats zone-map pruning (L16). Compare the **bare column** to a computed literal range:

```sql
-- ❌ function on the column: full scan
WHERE DATE_TRUNC('month', sale_date) = '2026-08-01'
WHERE EXTRACT(year FROM sale_date) = 2026
WHERE TO_CHAR(sale_date, 'YYYY-MM') = '2026-08'

-- ✅ bare column, literal range: zone maps prune
WHERE sale_date >= '2026-08-01' AND sale_date < '2026-09-01'
```

The same applies when you filter a UTC timestamp for a local day — convert the *boundaries*, not the column:

```sql
-- the local day 2026-08-10 in Riyadh is 21:00 the previous day, UTC
WHERE sold_at_utc >= '2026-08-09 21:00:00'
  AND sold_at_utc <  '2026-08-10 21:00:00'
```

This is the single most valuable habit in this lesson.

## Gotchas

- **`GETDATE()` and `SYSDATE` return UTC**, not the store's clock. `CURRENT_DATE` is a UTC date.
- **`CURRENT_DATE` inside a load makes it non-reproducible.** Pass the business date in as a parameter so a rerun of yesterday's job loads yesterday. This matters more than it sounds — it is the difference between a pipeline you can replay and one you cannot.
- **`DATE_TRUNC` on the sort key kills pruning.** Never in a `WHERE`.
- **`DATEDIFF` counts boundary crossings.**
- **`DATE_TRUNC('week')` is Monday-based.** Use `dim_date`.
- **`DATE` minus `DATE` gives an integer**; `TIMESTAMP` minus `TIMESTAMP` gives an interval.
- **`Asia/Riyadh` has no DST**, which makes life easy — but if the group expands to a DST zone, hard-coded `+3` breaks and `CONVERT_TIMEZONE` does not. Never hard-code the offset.

## Try it

```sql
-- prove the three-hour problem to yourself
SELECT DATE_TRUNC('day', sold_at_utc)::DATE                              AS utc_day,
       DATE_TRUNC('day', CONVERT_TIMEZONE('UTC','Asia/Riyadh',
                                          sold_at_utc))::DATE           AS local_day,
       COUNT(*)
FROM   staging.sales_line
WHERE  sold_at_utc >= '2026-08-09' AND sold_at_utc < '2026-08-12'
GROUP  BY 1, 2
ORDER  BY 1, 2;
```

Rows where `utc_day <> local_day` are the evening trade that a naive report attributes to the wrong day. Count them and you have the size of the bug.

## Checklist

- [ ] One timestamp convention for the whole warehouse
- [ ] Every timestamp column suffixed `_utc`
- [ ] `sale_date` precomputed as the local business day, and it is the `SORTKEY`
- [ ] Conversions use three-argument `CONVERT_TIMEZONE`, never a hard-coded `+3`
- [ ] `dim_date` exists, is `DISTSTYLE ALL`, and owns the fiscal and holiday calendar
- [ ] No function ever wraps the sort column in a `WHERE`
- [ ] Loads take the business date as a parameter, not `CURRENT_DATE`

## You've got it when you can…

…be told "the Riyadh 10 pm sales are showing on the wrong day" and know, before opening anything, that someone truncated a UTC timestamp.
