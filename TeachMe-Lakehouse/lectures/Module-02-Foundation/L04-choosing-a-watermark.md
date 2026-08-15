# L04 · Choose a Watermark You Can Trust

> **Module 2 · Lesson 04** · ~45 min

**Slide:** [`_render/L04-choosing-a-watermark.html`](_render/L04-choosing-a-watermark.html)

## The decision

An incremental load is one stored value interpolated into one `WHERE` clause. That value is the **watermark**, and it decides which rows the platform believes are new.

> **Which column means "this row is new" — and what do you do when no column qualifies?**

Every future run will trust that column without asking questions. It is a bookmark you place once and then rely on, unattended, for years. So the decision is not "which column looks like a date" — it is **which column can you prove is safe to trust**, and what you do with the tables where the honest answer is *none of them*.

## Do this

### 1 · Qualify the column against four tests. All four, or it is not a watermark.

| Test | What it means | How to check it |
|---|---|---|
| **MONOTONIC** | Only ever increases, and an **update** moves it | Does the application write it on `UPDATE`, or only on `INSERT`? A creation-date column cannot see edits or hard deletes. |
| **INDEXED** | The delta predicate must not table-scan | Read the execution plan for `WHERE col > :wm`. If it scans, your "cheap" delta costs more than a full read. |
| **NON-NULL** | A NULL row is invisible forever | `SELECT count(*) FROM t WHERE col IS NULL`. Any non-zero answer disqualifies the column, or requires a `COALESCE` with a documented sentinel. |
| **PARSEABLE** | You know its exact type and format | Is it a real `DATE`/`TIMESTAMP`, or text? What format is the text? Is it timezone-aware? Never assume. |

Do this **before** you write the spec, and record the answers next to the column name. A watermark chosen after the spec is written is a watermark chosen to fit the code.

### 2 · Prefer an update stamp, then an id, then a creation date

1. **`last_updated` / `row_version` / SCN** — sees inserts *and* updates. The right answer when the source offers one.
2. **A monotonic surrogate id** — sees inserts only, but is dense, indexed and unambiguous.
3. **A creation date** — sees inserts only, and **cannot see updates or hard deletes**. Usable, but write the limitation down: this table will need a periodic full refresh to stay correct.

### 3 · Declare the format explicitly in the spec

```yaml
watermark_column: last_update_date
watermark_type:   timestamp        # or: integer_id | text_date
watermark_format: "YYYY-MM-DD HH24:MI:SS"
safety_buffer:    1d               # widen the READ window; never move the stored value
```

If the column is text, the format field is load-bearing: a mismatch produces a predicate that matches nothing, the run succeeds, and zero rows land. A silent zero is much worse than a loud failure.

### 4 · Validate the value before it goes near SQL

Check the stored watermark against the declared format **every time**, immediately before interpolation. Anything that does not match raises rather than being spliced. This is an injection defence and a corruption detector in the same three lines.

Distinguish two cases carefully:

- **Empty / absent** — the "no watermark yet" sentinel for a first-ever run. Legal. Fall back to the full-load path.
- **Present but unparseable** — corruption. Raise.

Treating the first as the second sends every first run straight into the guard.

### 5 · Never persist a watermark you would refuse to reuse

This is the rule the whole lesson exists for.

```
candidate = MAX(watermark_column) over the rows just read
if candidate would fail your own validation      -> keep the previous watermark
if candidate < stored watermark                  -> keep the previous watermark   (forward-only)
if rows_with_errors > 0                          -> keep the previous watermark
```

Compute `MAX()` over **plausible rows only** — inside the declared format, inside a sane range (not before the system existed, not in the future). Rows that fail those bounds still land; they simply cannot become the bookmark.

Keeping the old watermark costs you one repeated delta, and repeating a delta is free because your load is idempotent (see [L07](L07-idempotent-loads.md) — the merge on the natural key absorbs it). Storing a bad watermark costs you **every future run** until a human notices.

The **forward-only** rule matters more than it looks: with a safety buffer, the read window starts *before* the stored watermark, so a hard delete upstream can make the window's `MAX()` come back lower than what you already have. Persisting that rewinds progress a little every single night.

*Worked example:* the refusal-and-forward-only sequence in [`sources/sap_hana.py`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py), `read_incremental`.

### 6 · Guard the projection

If the spec's column list omits the watermark column, `MAX(watermark_column)` fails — *after* the entire extract has been paid for. Validate at spec-parse time that the watermark column is in the projection. One validator, one whole class of expensive late failure removed.

### 7 · No column qualifies? Declare full-refresh. Do not fake CDC.

Some tables genuinely have no trustworthy change column: reference and code tables, tables keyed on a constant, tables where the "date" column is populated by hand. For those, set the read mode to full in the spec and route the table so the delta path never runs at all.

This is a **legitimate, documented design choice**, not a compromise. Faking CDC on a column you cannot trust produces a pipeline that succeeds every night while quietly losing rows — and nobody finds out for months, because there is no error to find.

## Why

- **A watermark is trusted unconditionally.** No downstream consumer re-checks it. Whatever it says is what the platform believes.
- **It has exactly two failure modes, and both are nasty.** It either **skips rows in silence** — the run succeeds, the data is wrong, and no alarm exists for "rows that were never asked for" — or it **wedges the table**, failing at the same guard every night until someone edits the stored value by hand.
- **Re-reading is free; wedging is not.** Because the load is idempotent, the conservative choice (keep the old mark, read a bit more) has almost no cost. The aggressive choice (store it and hope) has an unbounded one.
- **A loud failure is a gift.** An exception costs an hour. A silent gap costs a quarter, and the credibility of the whole platform along with it.

**What breaks if you don't:** the gap surfaces months later, in a report nobody can reconcile, with no way to tell which nights are affected.

## On Apparel Group

**Do the watermark survey before any spec is written.** For each table on each Oracle source, one row: column name, type, format, indexed?, NULL count, does it move on update?

| Source | Watermark strategy |
|---|---|
| **Oracle Retail (RMS)** | Facts: prefer `LAST_UPDATE_DATETIME` / `LAST_UPDATE_ID` where the RMS table offers one. Masters and code tables: expect several with no usable change column — full-refresh them, they are small. |
| **Oracle SIM** | Inventory positions churn constantly; a **true update stamp is essential**, not a creation date. A creation-date watermark on a position table will silently miss every quantity change — which is the only thing anyone cares about. |
| **Oracle XStore** | POS transactions are append-heavy, so a business date or transaction id works well. Confirm the timezone: store-local vs UTC will shift a day's takings across the date boundary. |
| **Epsilon** | Use **their** cursor/token. Do not derive a watermark from a payload field — persist the vendor's cursor exactly as issued, opaquely. Same refusal rules apply. |
| **MoEngage** | As Epsilon: their cursor, persisted verbatim, forward-only. |
| **Magento** | `updated_at` is usually present and usually trustworthy. Verify it is indexed before you rely on it. |
| **Vemco / Irisys Footfall** | Small per-store counts. **Full-refresh.** Do not build CDC for a table you can re-read in seconds. |

Two Apparel-Group traps worth naming up front:

- **Retail systems love a soft-delete flag.** A row "deleted" by a status change is an *update*. If your watermark only sees inserts, deletions never propagate and your stock and sales figures drift upward forever.
- **Timezones across a multi-country estate.** Store-local timestamps across several countries mean "yesterday" is not a single interval. Decide — and write down — whether watermarks are UTC or store-local, once, for the whole platform.

## Checklist

- [ ] Every table has a watermark decision recorded **before** its spec is written
- [ ] Candidate column passes all four tests: monotonic, indexed, non-null, parseable
- [ ] Column type and format declared explicitly in the spec
- [ ] It is known and written down whether the column moves on `UPDATE` — and if not, a periodic full refresh is scheduled
- [ ] Empty watermark is handled as "first run", not as corruption
- [ ] Value is validated against its declared format immediately before interpolation
- [ ] `MAX()` is computed over plausible rows only
- [ ] A candidate that fails validation is **discarded**, keeping the previous value
- [ ] Forward-only: a candidate below the stored value is discarded
- [ ] Rows-with-errors > 0 blocks the watermark advance
- [ ] Spec validator asserts the watermark column is in the projection
- [ ] Tables with no qualifying column are declared full-refresh and routed away from the delta path
- [ ] Timezone convention decided once, platform-wide

## You've got it when you can…

…answer *"why didn't the watermark move even though the job succeeded?"* with a specific reason — empty delta, unparseable candidate, or a value behind the stored one — name the log line each case emits, and explain why refusing to move it was the **correct** outcome in all three.
