# L07 · Make Every Load Idempotent

> **Module 2 · Lesson 07** · ~45 min
> **Slide:** [`_render/L07-idempotent-loads.html`](_render/L07-idempotent-loads.html)

---

## The decision

**How do you re-run a load without changing the row count?**

Not *if* you re-run it. You will re-run it. A cross-network extraction from someone else's production Oracle database times out; the orchestrator retries; the extraction window overlaps with yesterday's by an hour because someone widened it to catch late data; a backfill re-processes a month; a developer runs the same job twice while testing. Every one of those is a normal Tuesday, and every one of them delivers the same rows to your writer a second time.

So the design question is not "how do we avoid re-running" — it is **"what does the load do the second time?"**

| | Append-only | **Dedupe, then MERGE** |
|---|---|---|
| Second run | adds rows | changes nothing |
| Row count after retry | doubled | identical |
| Failure signal | none — it looks fine | a loud cardinality error if the source is dirty |
| Fixing a bad day | delete-and-reload, by hand | re-run the job |
| Cost of getting it wrong | permanent, silent duplication | one failed job |

Choose **dedupe, then MERGE**. An append-only load is a load you can never safely retry, which means it is a load nobody can operate.

## Do this

1. **Find the real primary key in the source DDL.** Not the column called `id`, not the column that "looks unique", not the one the source team says is unique. Pull the constraint definition, and then prove it on real data before you write anything:

   ```sql
   SELECT COUNT(*), COUNT(DISTINCT (col_a, col_b, col_c)) FROM source_table;
   ```

   If those two numbers differ, you have not found the key yet — keep going. This step takes ten minutes per table and it is the single highest-value ten minutes in the whole ingestion build.

2. **Declare that key on the spec as `merge_key`.** It belongs in configuration, next to the table definition, where a reviewer can see it:

   ```yaml
   table: xstore.transactions
   merge_key: [store_id, business_date, transaction_no]
   ```

   Make the engine **refuse to run** a table that has no declared key rather than fall back to a guess. A guessed key produces a load that appears to work and silently corrupts.

3. **Dedupe the source frame to exactly one row per key, before the MERGE ever sees it.** Rank and keep the winner deterministically — do not use an arbitrary "drop duplicates", because on a re-run you want the *same* row to win both times:

   ```sql
   SELECT * FROM (
     SELECT *, ROW_NUMBER() OVER (
                 PARTITION BY store_id, business_date, transaction_no
                 ORDER BY _ingested_at DESC, _run_id DESC) AS _rn
     FROM source
   ) WHERE _rn = 1
   ```

   Say out loud *why* this is safe for your load shape. For a watermark-range delta or a full snapshot, the source carries one current-state row per key, so collapsing duplicates only ever drops identical copies. For a true change stream carrying delete markers it is **not** safe, because collapsing would discard a delete. Different shape, different rule.

4. **Upsert with `MERGE`.** Matched rows update, unmatched rows insert. Never a plain append on a keyed table:

   ```sql
   MERGE INTO target t USING source s ON t.key = s.key
   WHEN MATCHED     THEN UPDATE SET *
   WHEN NOT MATCHED THEN INSERT *
   ```

   If the feed carries delete markers, add the third arm — `WHEN MATCHED AND s.op = 'D' THEN DELETE`, and exclude already-absent deletes from the insert arm.

5. **Make the landing write overwrite its own cycle prefix.** The raw layer writes to `.../cycle=<cycle_id>/` and a retry of that cycle *replaces* what is there rather than adding beside it. One cycle id, one prefix, one write. This is the same discipline as the MERGE, one layer earlier — and it is where duplication is cheapest to stop.

6. **Watch out for the first write.** On a table that does not exist yet, `MERGE` cannot run: the engine creates the table and appends the frame verbatim. If you deduped in step 3, that is correct. If you skipped step 3 because "the first load is a clean snapshot", the duplicates become permanent from row one and the MERGE will never remove them. **Dedupe on the first load too.**

**Worked example of the pattern:** the Tamimi engine declares `merge_key` per Bronze spec, dedupes in the job immediately before the writer call, dedupes again inside `writers/s3_tables.py::merge_into()` with a ranked window, and ranks a third time in the dbt staging models. Three layers, same rule, because the cost of a duplicate rises at every hop.

## Why

Replays, overlapping windows and automatic retries are routine. **Append-only turns every one of them into duplicate rows.** And duplicates in a keyed table are not a storage problem — they are a correctness problem, because the very next join fans out. One duplicated row in a dimension multiplies every fact row that joins to it, and the resulting number is plausible, not obviously broken.

The MERGE's one-match constraint is worth understanding properly, because you will meet it as an error message. A target row may be claimed by **at most one** source row. Two source rows matching the same target is a cardinality violation and the job stops. That is not the engine being fragile; it is the engine refusing to guess which of two conflicting rows should win. **A cardinality violation is never a bug in the target — it is a duplicate that arrived with the source**, and the fix is always upstream.

There is a second reason, and it is operational rather than mathematical. A load you can safely re-run is a load an on-call engineer can fix at 3am by pressing one button. A load that is not idempotent requires someone to work out *what already landed* before they dare touch it — which is why non-idempotent pipelines are the ones that stay broken until morning.

**What breaks if you don't:** the very first write can land duplicate keys, and once they are in, they are permanent — the MERGE will faithfully update both of them forever.

## On Apparel Group

**Find the true primary key before you write the spec. Do not assume it.**

| Source | Where the key comes from | Watch out for |
|---|---|---|
| **Oracle Retail RMS** | Composite keys on almost every table — item/location, item/supplier, and so on. Read the DDL. | The "obvious" single-column key is usually the master key of a different table. |
| **Oracle SIM** | Inventory position keyed by item + location (+ status or bucket on some tables). | High churn — the same key is legitimately updated many times a day, which is exactly what MERGE is for. |
| **Oracle XStore** | Transaction identity is composite: store + business date + transaction number. Line detail adds a line sequence. | Transaction numbers recycle per store per day. A number alone is **not** unique. |
| **Magento** | Orders on order id; order lines on order id + line item id. | Guest checkouts and re-created carts can reuse identifiers across environments. |
| **Epsilon** | Loyalty/customer master on the customer identifier; events on an event id. | PII — dedupe and merge behaviour has to be consistent with your deletion process. |
| **MoEngage** | Campaign/engagement events on an event id. | At-least-once delivery is the vendor's normal mode — assume repeats. |
| **Vemco / Irisys Footfall** | Store + interval start timestamp. | Files are frequently re-delivered for the same day. Overwrite the cycle, then merge. |

The three Oracle sources are where this lesson earns its keep: **RMS, SIM and XStore all use composite keys**, all three are being ingested by people who did not build them, and all three will happily return duplicate rows for a re-run window. Produce the key table for all eight sources as the exercise, with a `COUNT(*)` vs `COUNT(DISTINCT key)` result next to each row. That table is a deliverable, not a note.

## Checklist

- [ ] The primary key came from the source DDL, not from a column name
- [ ] `COUNT(*) = COUNT(DISTINCT key)` was proven on real data, and the result is recorded
- [ ] `merge_key` is declared in the spec; a table without one refuses to load
- [ ] The source is deduped to one row per key **before** the MERGE, including on the first load
- [ ] The dedupe picks a winner deterministically (ranked), not arbitrarily
- [ ] I can say why deduping is safe for *this* load shape
- [ ] Delete markers, if any, are handled by a third MERGE arm — not by dedupe
- [ ] The landing write overwrites its cycle prefix rather than adding beside it
- [ ] Running the job twice in Dev leaves the row count unchanged — verified, not assumed

## You've got it when you can…

…read a cardinality-violation error and say, without opening the target table, **"two source rows share a merge key — something upstream landed twice"**; name the three places a mature pipeline dedupes and why each one exists; explain why deduping is safe for a snapshot delta but dangerous for a change stream carrying deletes; and prove your load is idempotent by running it twice and showing the row count did not move.
