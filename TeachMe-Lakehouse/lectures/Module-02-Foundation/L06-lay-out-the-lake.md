# L06 · Lay Out the Lake

> **Module 2 · Lesson 06** · ~45 min
> **Slide:** [`_render/L06-lay-out-the-lake.html`](_render/L06-lay-out-the-lake.html)

---

## The decision

**Zones, buckets, namespaces, retention — how is storage carved up?**

You will make this decision in week one, on a whiteboard, before a single row has landed. It looks like a naming argument. It is not. Every path you choose here gets baked into ingestion specs, transformation models, IAM policies, KMS key policies, lifecycle rules, catalog entries and the Power BI connection strings — and it gets baked in *permanently*, because moving terabytes between buckets means re-running everything that ever wrote them.

The two candidate answers:

| | One bucket, prefixes inside | **Four zones, four buckets** |
|---|---|---|
| Boundary | a string prefix | a real resource boundary |
| Access control | one policy, conditioned on paths | one policy per zone |
| Encryption | one key for everything | one key per zone |
| Cost visibility | one line on the bill | four lines on the bill |
| Retention | one lifecycle rule, or per-prefix rules | one rule per zone, obviously correct |
| Changing your mind | rewrite every path everywhere | still a migration, but a smaller one |

Choose **four zones, four buckets**. The single-bucket layout is not wrong on day one; it is wrong on day four hundred, and by then it cannot be undone.

## Do this

1. **Cut four zones — raw, bronze, silver, gold — and give each one its own bucket.** A separate bucket is a separate policy, a separate encryption key and a separate blast radius. `ag-raw-<env>` · `ag-bronze-<env>` · `ag-silver-<env>` · `ag-gold-<env>`. Put the zone *and* the environment in the name, so anyone reading a path or a policy can see what it touches without opening a console.

2. **Make raw immutable and replayable.** Raw is written exactly once per source, per table, per cycle, and never edited afterwards. Its job is to let you rebuild every downstream layer from scratch without going back to the source system — which matters enormously when the source is someone else's production Oracle database and you get one extraction window a night.

   ```
   s3://ag-raw-<env>/<source>/<table>/cycle=<cycle_id>/part-*.parquet
   ```

   The `cycle=<cycle_id>` component is doing real work: it makes a re-run overwrite *exactly one* cycle's worth of files. Without it, a retried download writes a second copy alongside the first and the duplication surfaces one layer up (see [L07](L07-idempotent-loads.md)).

3. **Give every source system its own namespace, and never mix two systems in one.** One namespace per source, one table per source table:

   ```
   bronze.rms · bronze.sim · bronze.xstore · bronze.epsilon
   bronze.moengage · bronze.magento · bronze.vemco · bronze.irisys
   ```

   This is what makes "add a ninth source" an additive change rather than a refactor. It also gives you a natural grant boundary: a team that needs loyalty data gets `epsilon`, not "the bronze bucket".

4. **Set lifecycle and retention rules when the bucket is created**, in the same infrastructure code that creates it — not as a follow-up ticket. Raw gets a long retention with an archive transition (it is your replay tape and it is the cheapest data you own). Bronze and silver get noncurrent-version expiry so old copies do not accumulate. Gold is small and usually keeps everything.

5. **Decide the zone contract in one sentence each, and write it in the repo README:**
   - **raw** — exactly what the source gave us, unmodified, replayable, partitioned by cycle.
   - **bronze** — one table per source table, typed, deduped, upserted on the declared key.
   - **silver** — conformed and joined; business rules live here; source-neutral names.
   - **gold** — the star schema the BI tool reads. No raw column names survive to this layer.

   The value is not the prose. It is that a reviewer can now reject a pull request with "that transformation belongs in silver, not bronze" and point at a line.

**Worked example of the pattern:** the Tamimi lakehouse uses exactly this shape — a raw S3 bucket partitioned by cycle, then Bronze and Silver as separate Iceberg table buckets with per-bucket lifecycle settings declared in `infra/modules/s3-data-lake/main.tf`, and one Bronze namespace per source system. Read the namespace list next to the spec directory (`src/glue/specs/bronze/`) and the one-to-one mapping is immediately visible.

## Why

Each zone carries a genuinely different **retention, cost and access profile**. Raw is large, cold, rarely read and must be kept for a long time. Gold is small, hot, read constantly and can be rebuilt in an hour. Bronze sits in between. A bucket boundary is the only place where you can enforce retention, encryption and access for a zone *at once*, in one declarative place, and prove it to an auditor by pointing at a single resource.

The namespace rule buys something different: **independence**. When Magento's schema changes, nothing in the RMS namespace can be affected, because there is no shared object between them. Adding the ninth source touches nothing that already exists.

The lifecycle rule buys the thing nobody thinks about in week one: **you never get a good moment to add retention later.** By the time storage cost is noticeable, the bucket contains data whose deletability nobody is sure about, and the safe answer is always "keep it".

**What breaks if you don't:** fixing the layout later means rewriting every path, spec, job, policy and grant you have written — so it does not get fixed, and you live with it.

## On Apparel Group

Eight sources, eight namespaces, one layout:

| Namespace | Source | What drives the layout decision |
|---|---|---|
| `rms` | Oracle Retail RMS | Large masters + transaction tables. Mostly full refreshes; modest storage. |
| `sim` | Oracle SIM | Inventory positions, high churn. Many writes, moderate volume. |
| `xstore` | Oracle XStore | **The giant.** POS transactions. Size raw retention and the storage bill against this one, not against RMS. |
| `epsilon` | Epsilon | Loyalty + customer master. **PII** — own prefix, own KMS key, own grant, from day one, not after a classification review. |
| `moengage` | MoEngage | Campaign and engagement events. API/file drop cadence. |
| `magento` | Magento | E-commerce orders, customers, products. |
| `vemco` | Vemco Footfall | Small per-store counts, frequent files. |
| `irisys` | Irisys Footfall | Same shape as Vemco. Keep them separate anyway — they are different vendors with different formats. |

Three Apparel-Group-specific calls to make in week one:

- **Size raw retention against XStore.** Whatever retention you can afford for XStore is the retention policy; the other seven are rounding errors next to it. Decide the number before you sign off the storage estimate, not after the first invoice.
- **Epsilon is PII and it is not negotiable.** Its own prefix and its own key are what let you grant "loyalty analytics" to a team without granting them sales, and what let you delete a customer's data without touching seven other namespaces.
- **Keep Vemco and Irisys apart even though they do the same job.** They are optional sources that may be swapped or dropped. Merging them into a `footfall` namespace saves one line of config and costs you the ability to remove one vendor cleanly.

## Checklist

- [ ] Four zones exist as four buckets, each with the zone and the environment in its name
- [ ] Raw is write-once, partitioned by cycle id, and nothing ever edits it in place
- [ ] Every source system has its own namespace; no namespace holds two systems
- [ ] Lifecycle and retention are declared in the same infrastructure code that creates the bucket
- [ ] Each zone's contract is written down in one sentence, in the repo
- [ ] Epsilon (PII) has its own prefix and its own key, decided before first ingestion
- [ ] Raw retention was sized against XStore, not against an average table
- [ ] I can name the blast radius of any grant by reading the bucket name

## You've got it when you can…

…draw the four zones and their buckets from memory, state each zone's one-sentence contract, explain why the cycle id belongs in the raw path, and answer "can we just use one bucket and sort it out with prefixes?" with **"we can, and in eighteen months we will not be able to un-do it"** — then name the three things a bucket boundary gives you that a prefix does not.
