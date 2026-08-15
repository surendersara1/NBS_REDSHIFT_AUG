# Module 2 (Foundation) — How To Build It
### "The decisions you will make on the new platform, how to set each one up, and why"

> **Status:** PLAN — drives slide production.
> **Duration:** 18 hours · 24 lessons · format per [`../LECTURE-STYLE.md`](../LECTURE-STYLE.md)
> **Prerequisite:** Module 1 (vocabulary + the map).
> **Target project:** **Apparel Group — Enterprise Data & AI Platform on AWS** (12 weeks; workstreams: Data Foundation, Price Optimization, Inter-store Transfer, Amazon Quick / Retail IQ).

---

## 1. Why this module exists (and how it differs from `Module-02-Tamimi`)

`Module-02-Tamimi` documents **what this codebase does and what went wrong** — it is a superb reference for anyone maintaining Tamimi, and it stays.

**This module is the teaching version.** Same subject matter, opposite stance:

| `Module-02-Tamimi` (keep, for reference) | **`Module-02-Foundation` (teach from this)** |
|---|---|
| "MBEW at 16 partitions timed out on 2026-08-04" | "**Size JDBC parallelism like this**, and here's the formula" |
| "The TVKMT join doubled every sales row" | "**Always constrain language/type-keyed lookups**; here's how to prove the grain held" |
| "CRIT-01 regressed — state buckets are shared" | "**Isolate Terraform state per environment**; here's the layout and the migration" |
| "The barrier had an `== running` bug (R31)" | "**Gate on terminal states, never on 'running'** — here's why that's the safe predicate" |
| Retrospective · incident-led | **Prescriptive · decision-led** |

> **Rule for every slide in this module:** a learner who has never seen Tamimi must be able to **set the thing up on Apparel Group** from the slide alone. Past incidents are permitted only as a compressed *"why this rule exists"* line — never as narrative.

## 2. The fixed shape of every lesson

Each slide carries the same four zones, in this order:

1. **THE DECISION** — the choice they will actually face on the new build.
2. **DO THIS** — the recommended setup: concrete config, file layout, code shape. This is the biggest zone.
3. **WHY** — the reasoning, plus *"what breaks if you don't"* compressed to one line.
4. **ON APPAREL GROUP** — how this applies to their 8 sources. Named, specific.

Plus the standard **IN PLAIN ENGLISH** strip.

**Banned on these slides:** dates of past failures, ticket/risk IDs (R31, CRIT-01, HIGH-06…), "we discovered", "on 2026-…". Tamimi may be cited as *a worked example* (`unified_sales.sql` shows the pattern), never as *a war story*.

## 3. The 8 sources this module keeps pointing at

| # | Source | Kind | Ingestion shape they'll choose |
|---|---|---|---|
| 1 | Oracle Retail (RMS) | Oracle DB | JDBC · large master + txn tables |
| 2 | Oracle SIM | Oracle DB | JDBC · inventory positions, high churn |
| 3 | Oracle XStore | Oracle DB | JDBC · POS transactions, the "giant" |
| 4 | Epsilon | SaaS API | API/file drop · loyalty + customer master (PII) |
| 5 | MoEngage | SaaS API | API/file drop · campaign & engagement |
| 6 | Magento | DB or API | e-commerce orders/customers/products |
| 7 | Vemco Footfall | file/API | optional · small, per-store counts |
| 8 | Irisys Footfall | file/API | optional · small, per-store counts |

**Three recurring teaching moves:** classify a source → choose its load strategy → write its spec.

---

## PART A — Standing up ingestion (5 lessons · 4 hrs)

### L01 · Design the Engine Before the Pipelines
**Decision:** one job per table, or one engine + many specs?
**Do:** build a spec-driven engine — a Pydantic-validated spec, a connector registry, a writer, a control plane. Adding a table becomes a YAML file, not a deployment.
**Why:** 8 sources × dozens of tables = unmaintainable as bespoke jobs; the config path is testable and reviewable.
**AG:** the 48-table Tamimi engine is the reference shape for RMS + SIM + XStore.

### L02 · Define the Source Contract First
**Decision:** how does a new system plug in?
**Do:** write the connector `Protocol` (`read_full` / `read_incremental` / `read_range` / `emit_metrics`) and a `@register` registry; the engine must never name a vendor.
**Why:** Oracle, an API and a file drop all satisfy one interface — swapping sources becomes additive.
**AG:** exactly what makes 8 heterogeneous sources tractable; show where the Oracle branch lands.

### L03 · Size JDBC Parallelism Properly
**Decision:** how many parallel readers for a big table?
**Do:** teach the sizing rule — target ≈5–10 M rows per partition; total concurrent connections = lanes × partitions; stay well under the source's connection ceiling; set generous connect/read timeouts for a cross-network hop.
**Why:** too few = timeouts and OOM; too many = you exhaust the source's connection headroom and every read fails.
**AG:** XStore is the giant — size it first; RMS masters need almost none.

### L04 · Choose a Watermark You Can Trust
**Decision:** what column drives "only the new rows"?
**Do:** pick a monotonic, indexed, non-null change column; validate the format; **never persist a watermark you would refuse to reuse**; if a table has no usable change column, declare it full-refresh instead of faking CDC.
**Why:** a bad watermark either loses rows silently or wedges every future run.
**AG:** map a watermark per Oracle table up front; SaaS sources use their own cursor/token.

### L05 · Plan the Load Strategy per Table
**Decision:** full, windowed, or incremental — and what does day 1 look like?
**Do:** classify every table (full-only master / incremental fact / windowed giant); make the **initial load complete**, then hand over to CDC; define the empty-result policy (an empty *full* pull is a failure; an empty *delta* is normal).
**Why:** an incomplete initial load makes every later reconciliation wrong, and the error surfaces months later.
**AG:** produce the classification table for all 8 sources as the lesson's exercise.

## PART B — Laying out storage (4 lessons · 3 hrs)

### L06 · Lay Out the Lake
**Decision:** zones, buckets, namespaces, retention.
**Do:** raw (immutable, replayable, long retention) → bronze → silver → gold; one namespace per source system; separate buckets per zone; set lifecycle from day one.
**Why:** the layout is nearly impossible to change once terabytes have landed.

### L07 · Make Every Load Idempotent
**Decision:** how do you re-run safely?
**Do:** declare the natural key as `merge_key`, upsert with `MERGE`, and **dedupe the source to one row per key before merging**; make the landing write overwrite-per-cycle.
**Why:** replays, overlapping windows and retries are normal; append-only turns each one into duplicate rows. A one-match violation is the engine protecting you.
**AG:** identify the true PK per Oracle table *before* writing the spec — don't assume it.

### L08 · Plan Table Maintenance on Day One
**Decision:** who compacts, and who expires snapshots?
**Do:** decide what the platform manages vs what you must schedule; put snapshot expiry and file cleanup on a schedule with the pipeline, not "later".
**Why:** frequent small writes degrade read performance and grow metadata without bound.

### L09 · Make Schema Change a Controlled Event
**Decision:** what happens when the source adds or widens a column?
**Do:** fail loudly on unexpected drift rather than silently absorbing it; pre-cast numerics to a stable width; set the partition spec at creation.
**Why:** silent absorption produces wrong numbers no one notices; a loud failure costs an hour.

## PART C — Building transformations (5 lessons · 4 hrs)

### L10 · Choose Set-Based or Ordered — Deliberately
**Decision:** can this logic be a join?
**Do:** default to set-based SQL/DataFrame work; use an ordered per-group fold **only** when meaning depends on row order (POS receipt logs, event streams); keep that fold pure and unit-tested.
**Why:** ordered logic in Spark is expensive and easy to get wrong — but some source formats genuinely require it.
**AG:** XStore transaction logs are the candidate; RMS is pure set-based.

### L11 · Reproduce Source Business Rules Faithfully
**Decision:** re-implement, or re-derive?
**Do:** get the source logic (code, spec, or a signed-off rule statement); reproduce it exactly, including quirks, and **prove parity with a reconciliation query** before anyone builds on it. Document every intentional deviation.
**Why:** "we improved it while porting" is how a lakehouse quietly disagrees with the system of record.
**AG:** Oracle Retail has decades of embedded pricing/costing rules — get them, don't infer them.

### L12 · Write Spark That Scales
**Decision:** why is this job slow or unstable?
**Do:** cache a frame consumed more than once; watch shuffles; size partitions; avoid collecting to the driver; measure before tuning.
**Why:** a lazily-evaluated frame read three times pulls the source three times.

### L13 · Build Incremental Models Correctly
**Decision:** view, table, or incremental — and on what key?
**Do:** incremental + `merge` on a real unique key; use a sentinel rather than NULL in any key column; keep the reprocess window wide enough for late data and schedule periodic full refreshes.
**Why:** NULL never equals NULL in a merge predicate, so NULL-keyed rows re-insert forever.

### L14 · Guarantee Correctness by Construction
**Decision:** how do you know the numbers are right?
**Do:** state the grain of every table in one sentence; constrain language/type-keyed lookup joins; exclude synthetic rollup rows from any aggregate; add a uniqueness test on every merge key and a reconciliation test on every total.
**Why:** the failure mode is not an error — it's a plausible number that is quietly double.
**AG:** apparel dimensions (style/colour/size/season) multiply fast; grain discipline matters more, not less.

## PART D — Orchestration you can operate (4 lessons · 3 hrs)

### L15 · Design the Schedule and the Dispatcher
**Do:** one daily cycle id; a dispatcher that decides today's work from config + state; explicit run modes (initial / incremental / rerun / backfill); keep orchestration payloads small — pass references, not data.
**Why:** hardcoded schedules per table don't survive 8 sources.

### L16 · Make Phase Hand-offs Safe
**Do:** gate each phase with a barrier that claims a single-flight lock via a **conditional write**; decide on **terminal states**, never on "is it running"; treat losing the lock as success, not error.
**Why:** parallel sources finish together; two callers will race, and exactly one must act.

### L17 · Design the Control Plane
**Do:** record runs (per stage), watermarks, live pipeline state, and lineage. Every operator question should be answerable by a lookup, not a log grep.
**Why:** you cannot operate — or build a dashboard for — what you never recorded.

### L18 · Design for Failure Before You Ship
**Do:** make every stage idempotent and re-runnable; add a sweeper for stuck cycles; check for an in-flight job before starting one; define recovery modes (rerun / backfill / re-baseline) and who may run each.
**Why:** at-least-once delivery means a job *will* run twice.

## PART E — Platform setup (4 lessons · 3 hrs)

### L19 · Structure Terraform for Three Environments
**Do:** reusable modules + thin per-env composition; pin providers in every module; **isolate state per environment — separate bucket, lock table and key**; `prevent_destroy` on stateful resources; name resources with the env in them.
**Why:** shared state means a dev mistake can destroy prod. Comments claiming isolation are not isolation — verify the values.

### L20 · Set Up CI/CD With Real Gates
**Do:** OIDC federation, never static keys; plan → **apply the reviewed plan artifact**; manual gate on QA and Prod; per-env deploy roles; pin and checksum every downloaded tool and driver; **make the branch in the OIDC trust match the branch the pipeline deploys from.**
**Why:** a re-planned auto-apply means the human approved something other than what shipped.

### L21 · Set Up Security and Governance
**Do:** least-privilege per workload role; condition service principals in key policies on the source account; one key per data layer; tag-based access for data; secrets by reference only; permissions boundary on any role that can create roles.
**Why:** a full-access managed policy on a job role is an account-wide data-plane grant.
**AG:** Epsilon loyalty data is PII — classify and mask before it reaches a report.

### L22 · Connect to On-Prem Sources Safely
**Do:** private subnets for compute; interface endpoints instead of NAT for AWS APIs; enforce TLS on every database connection; route only the specific source CIDR; **size the subnet against the ENI count your parallel jobs will consume** and cap concurrency to match; enable flow logs.
**Why:** the network gives out before the database does, and the error looks like a database problem.

## PART F — Operate and extend (2 lessons · 1 hr)

### L23 · Set Up Observability From Day One
**Do:** define the freshness SLA per table, alarm on failure *and* on lateness, route to a real distribution list, and write the runbook alongside the pipeline. Build the operational view on the control plane you designed in L17.
**Why:** an alarm that reaches nobody is not monitoring.

### L24 · The Standard Procedure for Adding a Source ⭐
**Do:** the repeatable checklist — classify → confirm PK and watermark → connector (only if the protocol isn't already satisfied) → download spec → bronze spec → catalog row → staging model + tests → gold model → deploy through the gate.
**Why:** this is the loop they will run 8 times on Apparel Group.
**Ends with:** "Do this once for RMS. Then it's a habit."

---

## 4. Production notes
- Same deliverables per lesson: `L##.png` (1920×1080) + `L##.md` + `_render/L##.html`, plus one wide 16:9 PDF.
- **Take-home format changes** to match the stance: *The decision / Do this / Why / On Apparel Group / Checklist / You've got it when you can…*
- Tamimi files may be cited as **worked examples of the pattern**, never as incident evidence.
