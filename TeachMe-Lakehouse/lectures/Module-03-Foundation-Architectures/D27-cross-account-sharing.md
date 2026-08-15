# D27 · Sharing Across Accounts

> **Module 3 · Architecture 27 · deep dive** · ~20 min

**Diagram:** [`_render/D27-cross-account-sharing.html`](_render/D27-cross-account-sharing.html)

## What this pattern is for

Letting another team read your data **without giving them a copy of it**. This is how a data mesh (Module 0 L05) is actually plumbed on AWS — the organisational parts are yours to build, but the sharing is well supported.

The thing to notice on the diagram: **no data crosses the middle.** What crosses is permission.

## The nine steps

**1 · The producer owns the storage.** S3 and Iceberg tables in the producing team's account. They stay there. Ownership is not transferred, delegated or duplicated.

**2 · The tables are registered in the catalog.** Named, described, discoverable. A dataset nobody can find is not shared however permissive the policy is.

**3 · Lake Formation grants, with the grant option.** ⭐ The producer grants at **catalog, database, table or column** level. Two styles: **named-resource** grants (explicit, one per resource) and **tag-based, LF-TBAC** (grant by classification — this is the one that scales past a handful of tables).

**4 · AWS RAM carries the share.** ⭐ RAM shares the *resource*, not the bytes. This is the step people expect to be a copy job and it is not one — nothing is transferred, staged or synchronised.

**5 · The consumer accepts the invitation.** An explicit action in the consuming account. Sharing is not something that happens *to* an account; someone there has to accept it, which is what makes the audit trail meaningful.

**6 · A resource link makes it local.** ⭐ The shared database appears in the consumer's own catalog under a name they choose. From this point their tooling treats it like any other database — no special paths, no cross-account syntax in every query.

**7 · Query in place, still governed.** ⭐ Athena, Spark and EMR read it directly, and **Lake Formation still enforces the producer's grants**. Column masking applied by the producer is applied here too. Governance does not stop at the account boundary — this is the property that makes the whole pattern trustworthy.

**8 · Warehouse data uses a datashare instead.** For Redshift-to-Redshift, the mechanism is a **datashare**: a producer/consumer container sharing live data across clusters, accounts and Regions.

**9 · The consumer creates a database from it.** ⭐ And — the correction most material misses — **datashares are no longer read-only**:

```bash
aws redshift authorize-data-share \
  --data-share-arn arn:aws:redshift:...:datashare:.../salesshare \
  --consumer-identifier <consumer> \
  --allow-writes
```

With `--allow-writes` the consumer can `INSERT` and `UPDATE` the producer's data. That is a serious grant. Give it deliberately, and know that most documentation written before it landed says it is impossible.

## Why this beats sending extracts

| | Shared in place | A nightly extract |
|---|---|---|
| Freshness | live | as of last night |
| Governance | producer's grants still apply | gone the moment it lands |
| Cost | consumer's own compute | storage twice, plus a pipeline |
| Revocation | immediate | you cannot un-send a file |
| Drift | impossible | inevitable |

That fourth row is the one to lead with in a governance conversation.

## What breaks if you skip a piece

- **Named-resource grants at scale** — a grant per table per consumer, and nobody can audit it. Use tags.
- **No resource link** — consumers write awkward cross-account references everywhere.
- **Assuming governance stops at the boundary** — it does not, and that is the point; teams who assume otherwise build a second masking layer for nothing.
- **`--allow-writes` granted casually** — cross-account write access to your data.

## On Apparel Group

Not needed at go-live: one platform team, one account per environment. It becomes relevant if Apparel Group later wants a brand or a region to own and publish its own data — and it is worth knowing now, because the answer to *"can another team have this data?"* should be **"yes, shared"**, never **"yes, I'll send you a file."**

## Checklist

- [ ] Producer retains ownership of storage
- [ ] Grants are tag-based where there is more than a handful of tables
- [ ] Consumer explicitly accepts the RAM share
- [ ] A resource link exists so it looks local
- [ ] Column-level masking is verified **from the consumer side**
- [ ] `--allow-writes` is granted only where genuinely intended
- [ ] Nobody is emailing extracts

## You've got it when you can…

…be asked for "a copy of the sales data for the marketing team" and set up a governed share instead — then show that a masked column is still masked when they query it.
