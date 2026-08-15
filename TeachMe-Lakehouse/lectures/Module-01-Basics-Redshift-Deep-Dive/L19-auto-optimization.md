# L19 · AUTO — When To Let Redshift Decide

> **Module 01 · Lesson 19** · ~30 min

**Slide:** [`_render/L19-auto-optimization.html`](_render/L19-auto-optimization.html)

## What it is

**Automatic Table Optimization (ATO)** watches your actual queries, recommends a distribution and sort key, and applies them in the background.

It is genuinely good. It is also not a substitute for knowing your own join pattern on a table you designed yourself.

## What AUTO does, per setting

### `DISTSTYLE AUTO`
Starts a small table as `ALL`, converts it to `EVEN` as it grows, and may adopt a `KEY` once it has seen a repeated join. The transitions happen in the background.

### `SORTKEY AUTO`
Picks a sort column from predicates it sees repeatedly, then reorganises the table.

### `ENCODE AUTO`
Samples incoming data on a `COPY` into an **empty** table and applies compression. **This one is nearly always right** — there is little reason to override it unless you have measured something better.

## Where AUTO is the right answer

- **Early development**, before the query pattern exists
- **Small and medium tables** where the cost of being wrong is low
- **Tables with unpredictable access** — ad-hoc analysis, exploratory schemas
- **Compression, almost always**

## Where to state it explicitly

- **Large fact tables.** You already know the join column and the filter column. Telling Redshift is faster than waiting for it to infer, and you avoid it inferring something else.
- **Anything with a hard SLA.** ATO's background reorganisation is not something you want happening during a load window.
- **Tables where you have measured.** Once you know, encode the knowledge in the DDL where the next person can read it.

> **AUTO where you do not know. Explicit where you do.**

## Try it

```sql
-- what does Redshift want to change, and why?
SELECT type, database, table_name, group_id, ddl, auto_eligible
FROM   svv_alter_table_recommendations
ORDER  BY table_name;

-- what has it already done, unprompted?
SELECT eventtime, "type", status, table_id
FROM   svl_auto_worker_action
ORDER  BY eventtime DESC
LIMIT  50;

-- which tables are still on AUTO?
SELECT "table", diststyle, sortkey1, tbl_rows
FROM   svv_table_info
WHERE  diststyle LIKE 'AUTO%'
ORDER  BY tbl_rows DESC;
```

That last query is worth running on any inherited warehouse — a large fact still sitting on `AUTO(EVEN)` is usually an oversight rather than a decision.

## Reading a recommendation

`svv_alter_table_recommendations` gives you the exact `ddl` it would apply. You can:

- **Let it apply automatically** (the default for eligible tables), or
- **Take the DDL and apply it deliberately**, in a migration, with a review

The second is better for anything important. It puts the decision in version control instead of leaving it to a background process nobody watched.

## Gotchas

- **Background reorganisation consumes capacity you did not schedule.** On Serverless that is RPUs you pay for.
- **Do not benchmark a table ATO is actively rewriting.** Results will not be reproducible, and you will draw the wrong conclusion.
- **Stating a `DISTKEY` or `SORTKEY` turns AUTO off for that table.** That is the point — but know you now own it.
- **ATO needs days of workload**, not minutes, before its recommendations mean anything.

## Checklist

- [ ] Large facts have explicit `DISTKEY` and `SORTKEY`, not `AUTO`
- [ ] Compression is left to `AUTO` unless measured otherwise
- [ ] I have checked `svv_table_info` for large tables still on `AUTO`
- [ ] I read `svv_alter_table_recommendations` before accepting changes
- [ ] I do not benchmark during background reorganisation
- [ ] Deliberate decisions live in the DDL, in version control

## You've got it when you can…

…inherit a warehouse, list every large table still on `AUTO`, and say for each whether that is a reasonable default or an unmade decision.
