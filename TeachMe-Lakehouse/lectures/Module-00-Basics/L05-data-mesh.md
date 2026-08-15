# L05 · Data Mesh Is Not A Product

> **Module 0 · Lesson 05** · ~40 min

**Slide:** [`_render/L05-data-mesh.html`](_render/L05-data-mesh.html)

## What it is

Data mesh is an **operating model for organisations**, wearing the costume of an architecture. It is the most over-used and least-understood of the four words, and you will meet it in RFPs written by people who could not implement it.

Nothing in a mesh is a service you can switch on. Every part of it is a decision about teams, ownership and accountability. You can build a mesh *on* a lakehouse. You cannot buy one.

## The four principles — all four are about people

### 1. Domain ownership

The team that **produces** the data owns it — its quality, its documentation, and its pager. Not a central data team that inherited a pipeline from a consultant three years ago.

### 2. Data as a product

Each dataset has a named owner, a published schema, a stated SLA, and consumers who are entitled to complain when it breaks. "Product" is not a metaphor here; it means someone is accountable for whether it is any good.

### 3. Federated governance

A central group sets the rules — naming, classification, PII handling, retention — and each domain applies them to its own data. Nobody has to queue behind a central team to publish.

### 4. Self-serve platform

Domains publish data without filing a ticket, because the platform itself is built as a product for them to use. If publishing requires a platform engineer, you do not have a mesh; you have a bottleneck with extra ceremony.

## How AWS actually implements the sharing

The organisational parts are yours to build. The technical sharing is well supported:

| Need | AWS mechanism |
|---|---|
| Share catalog tables across accounts | **Lake Formation** cross-account grants over **AWS RAM** |
| Grant by classification rather than by name | **LF-TBAC** — tag-based access control |
| Make a shared database appear locally | **Resource links** |
| Share live warehouse data | **Redshift datashares** — across clusters, accounts and Regions |
| Expose a domain's system without copying it | **Federated catalogs** (Lesson 29) |

Two grant styles are worth knowing apart: **named-resource** grants name specific tables, and **tag-based** grants apply to anything carrying a tag. Tag-based scales; named-resource does not.

## When it makes sense

**A mesh pays off when:**
- There are many domains, each with its own engineers who can own data
- The central data team has genuinely become the bottleneck
- Governance can be automated and enforced, not manually policed

**It does not pay off when:**
- There is one team and one platform. Then it is pure overhead — meetings, standards documents and ownership matrices with no autonomy to enable.

## In practice

**Neither Tamimi nor Apparel Group is a mesh, and neither needs to be.** One platform team owns ingestion, transformation, the warehouse and the reporting layer end to end.

Learn the word properly anyway — because someone will propose a mesh in a steering meeting, and the useful response is not "no", it is *"which domain teams would own which products, and who is on call for them?"* That question resolves the conversation quickly and honestly.

## Checklist

- [ ] I can state the four principles and say why each is organisational
- [ ] I can explain why you cannot buy a mesh
- [ ] I know which AWS mechanisms implement cross-domain sharing
- [ ] I know the difference between named-resource and tag-based grants
- [ ] I can say why our platform is not a mesh, without being dismissive

## You've got it when you can…

…hear "we should build a data mesh" in a meeting and ask the two questions that establish whether the organisation is actually shaped for one — without either agreeing reflexively or dismissing it.
