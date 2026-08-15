# L06 · So Which One Do You Need?

> **Module 0 · Lesson 06** · ~40 min

**Slide:** [`_render/L06-which-one.html`](_render/L06-which-one.html)

## The question

You are not choosing a favourite. You are choosing **what to pay for**, because every option buys one thing and gives up another.

Name what you are buying before you name the technology. Teams that do it the other way round end up defending a choice they made for reasons they cannot articulate.

## Side by side

| | Warehouse | Lake | **Lakehouse** | Mesh |
|---|---|---|---|---|
| **Schema** | on write, modelled first | on read, decide later | lake storage, warehouse behaviour | n/a — it is an ownership model |
| **Strength** | fast joins, numbers reconcile | keeps everything, costs little | ACID, MERGE, time travel | domains own their products |
| **Weakness** | rigid; change costs a migration | no updates, no guarantees | more moving parts to operate | needs many teams to pay off |
| **Priced** | per hour of compute | per TB scanned | both, depending on engine | sits on top of one of the others |
| **On AWS** | Amazon Redshift | S3 + Glue + Athena | **S3 Tables + Redshift** | Lake Formation + RAM |
| **You buy** | trust | optionality | both | autonomy |

## The honest recommendation

For a retail group with **one platform team, eight source systems, and reporting as the primary use case**: build the **lakehouse**.

The reasoning, stated plainly:

- A pure warehouse forces you to decide the meaning of every field before you have seen the data. With eight unfamiliar source systems, you will be wrong, and every correction is a migration.
- A pure lake cannot give the finance team a number they can sign off on, because nothing enforces the shape.
- A lakehouse lets you land everything cheaply and *then* model the part that needs modelling, without moving the data to do it.
- A mesh solves a coordination problem you do not have yet. Revisit it when you have five domain teams and a genuine queue for the central team.

## The mistake to avoid

Do not pick the architecture with the best conference talks. Pick the one whose **trade-off you are willing to live with on a Tuesday afternoon in month nine**.

Every one of these options has a bad day built into it:
- The warehouse's bad day is a schema migration nobody scoped.
- The lake's bad day is discovering the file format changed upstream two months ago.
- The lakehouse's bad day is compaction, snapshot expiry and a catalog that has to be kept correct.
- The mesh's bad day is a domain team that stopped answering.

Choose the bad day you can staff.

## Checklist

- [ ] I can fill in the comparison table from memory
- [ ] I can state what each option *buys* in one word
- [ ] I can give the honest recommendation for our situation and defend it
- [ ] I can name the characteristic bad day for each option
- [ ] I know what would have to change for a mesh to become the right answer

## You've got it when you can…

…sit in a design review, hear four people advocate four different architectures, and reframe the argument from "which is best" to "which trade-off are we willing to operate" — then land the decision.
