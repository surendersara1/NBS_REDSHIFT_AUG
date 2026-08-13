# Coverage and gaps

Written so you know the boundary of this course before you hand it over —
what a learner will and will not be able to do at the end of it.

## Verification status

Every SQL file was written against AWS documentation, and the highest-risk
system-view columns were checked against the reference pages directly. That
pass found **four real bugs**, all now fixed:

| Bug | Where | Fix |
|---|---|---|
| `stl_scan.blocks_read` / `blocks_skipped` — **these columns do not exist** | `11`, `15` | `rows_pre_filter` + `is_rrscan`, which is the actual evidence of block skipping |
| `sys_query_detail.is_distkey` — does not exist | `06`, `10` | `step_name IN ('distribute','broadcast')` — redistribution is a step, not a flag |
| `sys_query_detail.network_distribute_bytes` — does not exist | `10` | `stl_dist` (rows, bytes, packets) |
| `staging.sales_line` referenced but never created | `16` | table added |

The `blocks_skipped` one is worth flagging: it came from the source slide
material and would have failed in front of the room on day 4.

Confirmed present and correct: `is_rrscan` (in **both** `stl_scan` and
`sys_query_detail`), `rows_pre_filter`, `spilled_block_local_disk`,
`spilled_block_remote_disk`, `step_name`, `table_name`, `source`.

**Still unverified:** nothing has been executed against a live cluster. The
column names are now documentation-checked; the *logic* is not runtime-proven.

## What is covered — 18 modules

| | Module | A learner can then… |
|---|---|---|
| 01 | Objects, schemas, roles | Create every object type; know what Redshift lacks |
| 02 | Spectrum, COPY, UNLOAD | Load and unload; diagnose from `stl_load_errors` |
| 03 | S3 Tables federated catalog | Query Iceberg from Redshift with no load |
| 04 | Modelling, MVs, compute | Build a fact, an MV, and a window-function compute |
| 05 | Stored procedures | Write set-based, re-runnable procedures |
| 06 | SVV/SYS/STL/STV/SVL | Answer operational questions from the catalog |
| 07 | Views, late-binding, MVs | Choose correctly between the three |
| 08 | Two kinds of external schema | Tell Spectrum from federated; find the LF boundary |
| 09 | Roles, CLS, RLS | Grant safely; apply engine-enforced controls |
| 10 | The four mechanisms | *Measure* zone maps, collocation, columnar, stats |
| 11 | Sort-key design | Prove skipping; spot the function-in-WHERE trap |
| 12 | Compression | Find uncompressed tables; recommend without touching prod |
| 13 | Constraints are hints | Prove PK is unenforced; run the four tests |
| 14 | AUTO | Decide AUTO vs explicit |
| 15 | Fact + dimension design | Design a star schema and verify it in four checks |
| 16 | COPY in depth | Diagnose a slow load from slice/file counts |
| 17 | **Dialect for MySQL/MSSQL devs** | Write Redshift SQL without porting bugs |
| 18 | **Applications, transactions, WLM** | Connect an app; retry serialization failures; tune |

Modules 17 and 18 were not in the original brief. I added them because for
*this specific audience* — strong app developers, 5–10 years, MySQL/MSSQL,
zero Redshift — they are the two highest-value files in the repo. Everything
else teaches Redshift; these two stop them writing SQL Server against it and
stop them designing an application that exhausts the connection pool in
week one.

## Gaps — what is NOT covered, ranked

Honest list. None of these is required to *start* a warehouse project; the
first three will come up within the first month of a real one.

### 1. Data sharing / datashares — HIGH
Producer/consumer clusters, cross-account sharing, and the read-only
semantics. The standard way real organisations separate ETL from BI compute.
Not covered at all. Roughly one module.

### 2. Incremental loading and SCD Type 2 — HIGH
`15` builds the Type 2 dimension *structure* (`valid_from`/`valid_to`/
`is_current`) but never the MERGE logic that maintains it. `16` covers
whole-partition reload. The genuinely incremental case — late-arriving
facts, dimension versioning — is a real gap and is where most project
defects live.

### 3. Snapshots, restore, resize, DR — HIGH for operations
Automated and manual snapshots, cross-region copy, restore-to-new-cluster,
elastic vs classic resize. Purely operational, entirely absent.

### 4. Redshift Serverless — MEDIUM
The course teaches provisioned. Serverless has a different cost model (RPUs),
different scaling, and no `pause`. If the target project might be
serverless, this needs a decision framework.

### 5. Streaming ingestion — MEDIUM
Kinesis and MSK straight into a materialized view. Only relevant if the
project ingests streams; AWS has a dedicated workshop
([amazon-redshift-streaming-workshop](https://github.com/aws-samples/amazon-redshift-streaming-workshop)).

### 6. Zero-ETL from Aurora — MEDIUM
Increasingly how operational data reaches Redshift without a pipeline.
Worth a briefing even if unused.

### 7. dbt on Redshift — MEDIUM
`13` gestures at dbt tests. If the project uses dbt, that is its own course.

### 8. Redshift ML, federated query hands-on, Lambda UDFs — LOW
`08` gives federated query as reference shape only, since the teaching
environment has no RDS. Redshift ML is out of scope.

## My recommendation on sequencing

The five days as written cover modules 01–16. **Move 17 earlier than its
number suggests** — it belongs on the morning of day 1, before anyone writes
a line of SQL, because it prevents the errors the rest of the week would
otherwise spend time on. Module 18 fits day 5 alongside the catalog work.

Suggested revision:

- **Day 1** 17 (dialect) → 01 (objects) → 13 (constraints)
- **Day 2** 02 (COPY/Spectrum) → 16 (COPY depth)
- **Day 3** Glue jobs → 03 (S3 Tables) → 08 (external schemas)
- **Day 4** 10 → 11 → 12 → 15 (the physical-design core — never cut this)
- **Day 5** 04 → 05 → 07 → 09 → 06 → 18

Day 4 is the day that pays for the project. If time is lost, take it from
day 3.

## What "mastery" honestly means here

At the end of five days these people will be **competent**, not masters.
They will be able to build a correct star schema, load it efficiently,
diagnose a slow query systematically, and avoid the traps that cost weeks.

Mastery is 6–12 months of running a real warehouse. What this course can do
is make sure the first three months are not spent learning that constraints
are not enforced and that a function in a `WHERE` clause defeats zone maps.

The single best predictor of whether it worked: on day 30 of the project,
does someone reach for `svv_table_info` before they reach for a guess?
