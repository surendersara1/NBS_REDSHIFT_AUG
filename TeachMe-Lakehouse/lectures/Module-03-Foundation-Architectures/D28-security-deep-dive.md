# D28 · One Query, Every Control It Passes

> **Module 3 · Architecture 28 · deep dive** · ~20 min

**Diagram:** [`_render/D28-security-deep-dive.html`](_render/D28-security-deep-dive.html)

## What this pattern is for

Security on a lakehouse is not one gate. It is nine, and they are owned by different services. Following a single analyst's `SELECT` through all of them is the fastest way to understand which one you are actually debugging.

**If any one control is missing, the others do not save you.**

## The nine checks

**1 · The analyst has no database password.** Not "a strong password" — none. Removing the credential removes the whole class of problems that come with rotating, sharing and leaking one.

**2 · Identity Center authenticates them.** Federated login against the corporate directory. Joiners and leavers are handled where they are already handled, not in a second place someone has to remember.

**3 · They assume a role.** Short-lived, scoped credentials. The role — not the person — carries the permissions, which is why a leaver is removed from a group rather than hunted through scattered grants.

**4 · The query is issued.** Athena or Redshift. Note that nothing so far has considered *the data* — everything up to here is about identity.

**5 · Lake Formation checks the grant.** ⭐ At catalog, database, table **and column** level. This is where authorisation actually happens for anything read through the catalog, and — crucially — **the same grant is enforced by every engine**. Athena, Spark, EMR and Redshift Spectrum all honour it. Define once, applies everywhere.

**6 · Columns are filtered out.** ⭐ PII columns the role was not granted simply **do not appear in the result**. Not blanked, not masked in the report — absent from what the engine returns. This is the difference between a control and a convention.

**7 · Rows are filtered.** Row-level security in Redshift narrows what the role can see: one region's stores, one brand's products. Applied by the database, not by whoever wrote the dashboard.

**8 · Only the surviving bytes are read.** Which is a nice property: the column and row filters reduce cost as well as exposure. Governance and the bill point the same way for once.

**9 · KMS and CloudTrail bracket the whole thing.** ⭐ The role also needs **decrypt permission on the KMS key** — a grant on the table is not enough if the key says no, which is the single most confusing "access denied" on a lakehouse. And **CloudTrail records the entire path**, so the question "who read the customer table last March?" has an answer.

**Macie** runs alongside, scanning for PII in places nobody classified. It is how you find the column somebody added six months ago and never told anyone about.

## Where the "it works for me" bugs come from

| Symptom | Usually |
|---|---|
| Works in Athena, not in Redshift | two grant systems — Redshift `GRANT` vs Lake Formation (Module 0 L17) |
| Access denied with a valid table grant | **KMS key policy**, not the table grant |
| Sees a column they should not | grant made at table level instead of column level |
| Sees all rows | RLS policy exists but the role is exempt |
| Nobody can explain who granted it | it was clicked in the console, not written in Terraform |

That last row is why every grant belongs in Terraform: an access grant made in the console has no author, no reason and no reviewer — and nobody will ever dare remove it.

## On Apparel Group

**Epsilon carries customer PII.** The control that matters is step 6: masked **at the column**, never by maintaining a separate filtered copy. A copy is a second thing to secure, a second thing to keep in sync, and a second thing to leak.

Verify masking **from the consumer's seat**, not from an admin session. An admin can see everything, which makes admin a useless place to test from.

## Checklist

- [ ] No database passwords anywhere
- [ ] Grants go to roles, never to individuals
- [ ] PII is column-level granted, not report-filtered
- [ ] RLS applied where a role should see only some rows
- [ ] The role has **KMS decrypt** as well as the table grant
- [ ] CloudTrail is on and retained long enough to answer an audit
- [ ] Every grant lives in Terraform
- [ ] Masking tested from a real consumer role

## You've got it when you can…

…be handed "access denied" on a table the user was definitely granted, and check the KMS key policy before anything else — because that is the one nobody thinks of.
