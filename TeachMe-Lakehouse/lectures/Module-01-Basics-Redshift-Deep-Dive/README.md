# Module 01 · Basics — Redshift Deep Dive
### "From Node.js developer to competent Redshift engineer"

**45 lessons · complete · ~30 hours · no Redshift background assumed.**
Format: [`../LECTURE-STYLE.md`](../LECTURE-STYLE.md) · One-file deck: **[`Module-01-Basics-Redshift-Deep-Dive.pdf`](Module-01-Basics-Redshift-Deep-Dive.pdf)**
Hands-on companion: **[`Module-01-Redshift-Hands-On-Labs.pdf`](Module-01-Redshift-Hands-On-Labs.pdf)** — four days of
AWS labs mapped to these lessons, source in [`LAB-TRACK.md`](LAB-TRACK.md)

> **Build status: complete.** All **45 lessons** built — slide + take-home each, all 45
> passing the full render gate (missing-icon, canvas-bounds, box-containment, webfont)
> and the PDF notes-clipping gate.
>
> **All seven parts are done:** what Redshift is · objects and types · physical design ·
> getting data in and out · SQL that performs · programmability · operating it.
>
> Every take-home carries **runnable SQL**: `svv_table_info`, `sys_query_history`,
> `svl_query_summary`, `stl_scan`, `stl_load_errors`, `stl_unload_log`, `stv_locks`,
> `svv_transactions`, `pg_table_def`, `svl_auto_worker_action`,
> `svv_alter_table_recommendations`, `sys_serverless_usage`, `ANALYZE COMPRESSION`, the
> full stage → validate → dedup → `MERGE` transaction, the rename-swap, the deep copy,
> the hash-driven SCD2 load with its overlap test, and the Data API client from Node
> with backoff, pagination and a 1023 retry wrapper.
>
> **Three lessons are the ones to read first if time is short:** L14 (there are no
> indexes), L39 (calling Redshift from Node.js), L44 (the six-question diagnosis
> playbook).

> **Who this is for.** Three application developers who write Node.js, know an app
> database (Postgres, MySQL, Mongo) and have never touched a data warehouse — who
> are about to be responsible for one.
>
> **The problem this module solves.** Every instinct that makes you good at an app
> database makes you bad at Redshift. Normalise, index, insert row by row, wrap it in
> a transaction, let the ORM handle it — all correct there, all wrong here. This
> module replaces those instincts one at a time, and gives you the SQL to prove it.

Each lesson: **WHAT IT IS → HOW IT WORKS → THE SQL → GOTCHAS**, plus a plain-English line.
Take-homes carry **runnable SQL** — the slide is the lecture, the `.md` is the reference
you keep open while working.

---

## Part A — What Redshift actually is (7 lessons)

| # | Lesson | The instinct it replaces |
|---|---|---|
| L01 | Redshift Is Not Your App Database | "it's Postgres, I know Postgres" |
| L02 | Clusters, Nodes and Slices | "a database is one machine" |
| L03 | Provisioned vs Serverless | "you size a server" |
| L04 | Redshift Managed Storage | "storage and compute are the same thing" |
| L05 | How A Query Actually Runs | "the database just runs my SQL" |
| L06 | Connecting To Redshift | "open a pool and hold connections" |
| L07 | Databases, Schemas and search_path | "one database, one schema" |

## Part B — Objects and types (6 lessons)

| # | Lesson | |
|---|---|---|
| L08 | CREATE TABLE, Anatomy Of | every clause, and which ones matter |
| L09 | Data Types That Will Bite You | VARCHAR sizing, no TEXT, DECIMAL vs FLOAT |
| L10 | SUPER and Semi-Structured Data | JSON for people coming from Mongo |
| L11 | Views, Late-Binding and Materialized | three things called "view" |
| L12 | External Schemas — Spectrum and Federated | querying what you never loaded |
| L13 | Users, Groups, Roles and GRANT | who is allowed |

## Part C — Physical design (7 lessons)

| # | Lesson | |
|---|---|---|
| L14 | **There Are No Indexes** ⭐ | what replaces them, and why |
| L15 | Distribution Styles In Depth | KEY · ALL · EVEN · AUTO |
| L16 | Sort Keys and Zone Maps | how Redshift skips data it cannot need |
| L17 | Compression and Encodings | `ANALYZE COMPRESSION`, az64, zstd |
| L18 | Constraints Are Hints, Not Rules ⭐ | PRIMARY KEY does not enforce anything |
| L19 | AUTO — When To Let Redshift Decide | and when not to |
| L20 | Designing A Fact And Its Dimensions | the worked example |

## Part D — Getting data in and out (7 lessons)

| # | Lesson | |
|---|---|---|
| L21 | COPY In Depth | the only load path that scales |
| L22 | When COPY Fails | `STL_LOAD_ERRORS`, MAXERROR, the workflow |
| L23 | INSERT, UPDATE, DELETE and Their Cost | why row-by-row is fatal |
| L24 | MERGE and Idempotent Loads ⭐ | re-running must be safe |
| L25 | Transactions, Locks and Serializable Isolation | the error that confuses everyone |
| L26 | Staging Patterns | stage → validate → swap |
| L27 | UNLOAD | publishing back to S3 |

## Part E — SQL that performs (7 lessons)

| # | Lesson | |
|---|---|---|
| L28 | Reading An EXPLAIN Plan ⭐ | DS_BCAST_INNER and friends |
| L29 | Joins and Data Distribution | why the same join is 100× slower |
| L30 | Window Functions | the warehouse workhorse |
| L31 | CTEs, Subqueries and the Optimizer | what gets inlined, what does not |
| L32 | Dates, Times and Time Zones | the quiet source of wrong numbers |
| L33 | Warehouse SQL Patterns | dedup, SCD2, gaps and islands |
| L34 | Result Caching | why the second run is instant |

## Part F — Programmability (6 lessons)

| # | Lesson | |
|---|---|---|
| L35 | Stored Procedures | PL/pgSQL in Redshift |
| L36 | Control Flow, Cursors and Exceptions | loops, RAISE, transaction rules |
| L37 | User-Defined Functions | SQL UDFs — and why Python UDFs are out of support |
| L38 | Lambda UDFs | your Node code, called mid-query |
| L39 | **Calling Redshift From Node.js** ⭐ | Data API vs `pg` — the lesson written for you |
| L40 | Scheduling and Automation | EventBridge, Step Functions, the Data API |

## Part G — Operating it (5 lessons)

| # | Lesson | |
|---|---|---|
| L41 | Workload Management and Concurrency Scaling | queues, slots, short-query acceleration |
| L42 | VACUUM, ANALYZE and Auto Maintenance | what is automatic now, what is not |
| L43 | The System Tables You Actually Use | `SYS_*`, `STL_*`, `SVL_*`, `STV_*` |
| L44 | Diagnosing A Slow Query ⭐ | the workflow, in order |
| L45 | Cost, Sizing and The Mastery Map | where money goes, and what to know cold |

---

## The five habits to unlearn

| From Node + app DB | In Redshift |
|---|---|
| `INSERT` per row | `COPY` in bulk, then `MERGE` |
| Add an index | Choose a **sort key** and a **distribution style** |
| `PRIMARY KEY` prevents duplicates | It does **not** — you test for them |
| Hold a connection pool | Use the **Data API** — no connection to hold |
| Normalise everything | **Denormalise** the gold layer deliberately |

## The ten things to carry out (L45)

1. It is columnar and MPP. Never `SELECT *`, never row-at-a-time.
2. There are no indexes. `DISTKEY` and `SORTKEY` are the design.
3. Size every `VARCHAR` honestly — oversizing causes disk spill.
4. Constraints are hints. Uniqueness is a test you write and run.
5. Load with `COPY` from S3. Never a loop of `INSERT`s.
6. Every load is idempotent for its batch date, or it is not finished.
7. Hunt `DS_BCAST_INNER`. Small dimensions go `DISTSTYLE ALL`.
8. `ANALYZE` after every load. The cheapest fix that exists.
9. Store UTC. Convert once, at the reporting boundary.
10. Diagnose in order. Rewriting the SQL is the last step, not the first.

## Verified against AWS documentation

Two facts in this module were confirmed live rather than assumed, because both change
what you would teach:

- **Python UDFs are out of support.** Creation blocked after patch 198 (30 Oct 2025);
  existing UDFs reached end of support 30 Jun 2026. Lambda UDFs are the replacement.
  → L37, L38
- **`sys_query_history` exposes `result_cache_hit`**, which is how L34's benchmarking
  method is verifiable rather than folklore.

## Rebuild

```bash
cd lectures
python render_slides.py Module-01-Basics-Redshift-Deep-Dive
python make_pdf.py     Module-01-Basics-Redshift-Deep-Dive
```
