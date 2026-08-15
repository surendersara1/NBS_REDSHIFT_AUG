# D19 · PII And The Security Model

> **Module 3 · Architecture 19 · proposed** · ~15 min

**Diagram:** [`_render/D19-pii-security.html`](_render/D19-pii-security.html)

## What it shows

Four layers between customer data and someone who should not see it — and **none of them is a filtered copy**.

**Epsilon carries PII.** That single fact drives most of the design decisions on this diagram.

## The four layers

### 1 · Identity — *who you are*
IAM roles, Identity Center for federated login, OIDC for CI. **No user has a database password.**
*The rule:* grant to roles, never to people. A leaver is removed from a role, not hunted through scattered grants.

### 2 · Encryption — *at rest and in transit*
KMS with a key per bucket, Secrets Manager for source credentials, TLS everywhere.
*The rule:* the bucket policy **denies any unencrypted write**, so nobody has to remember.

### 3 · Data access — *what you may see*
Lake Formation column-level grants, RLS and CLS inside Redshift, Macie scanning for PII nobody classified.
*The rule:* **mask at the column, never by keeping a second filtered copy.** A copy is a second thing to secure, a second thing to keep in sync, and a second thing to leak.

### 4 · Audit — *prove it later*
CloudTrail records who did what. GuardDuty flags unusual behaviour. Config detects drift.
*The rule:* every grant is Terraform, so access has an author, a reason and a reviewer.

## The layer that actually matters

**Layer 3.** The other three are hygiene that any competent platform has. Layer 3 is where teams take the shortcut — building a "safe" copy of the customer table with the sensitive columns dropped, and handing that out.

That shortcut fails in three ways: the copy drifts, the copy has to be secured separately, and the moment someone needs one more column the whole thing is rebuilt. Column-level grants against **one** table have none of those problems.

## Test it from the right seat

**Verify masking from a real consumer role, not from an admin session.** An admin sees everything, which makes admin a useless place to test from — and it is exactly where most people test.

## The KMS trap

A role can hold a perfectly good Lake Formation grant on a table and still get access denied, because it lacks **decrypt permission on the KMS key**. It is the single most confusing failure in the stack (D28), and it is worth knowing before you meet it at speed.

## Checklist

- [ ] No database passwords anywhere
- [ ] Grants go to roles, never to individuals
- [ ] Bucket policy denies unencrypted writes
- [ ] PII masked with column grants, not a filtered copy
- [ ] Roles have **KMS decrypt** as well as the table grant
- [ ] CloudTrail on, retained long enough for an audit
- [ ] Every grant in Terraform
- [ ] Masking tested from a consumer role, not an admin one

## You've got it when you can…

…be asked for "a version of the customer table without the personal data" and set up a column-level grant instead — then show the requester it works from their own login.
