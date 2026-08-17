# Pre-course audit — NBS Redshift Coaching Platform

**Date:** 2026-08-16
**Auditor:** Claude Opus 5, against the live AWS documentation MCP server
**Scope:** CDK infrastructure, Glue ETL, the S3 → S3 Tables → Redshift
federated-catalog path, the operational scripts, and **all 76 SQL modules**
**Course starts:** 2026-08-17

> **Scope boundary, stated up front.** The repository contains **76 SQL
> modules**. This audit covers the **deployable platform** — CDK, Glue jobs,
> scripts — plus **all 76 SQL modules, read line by line.**
>
> The first pass (2026-08-16, §1–§7) covered the platform and 26 modules.
> The second pass (§8) read the remaining 50 and re-scanned the rest.
>
> | | Modules |
> |---|---|
> | **Read in full** | **`01`–`76` — all 76** |
> | **Bugs found and fixed in** | `01`, `02`, `06`, `07`, `08`, `09`, `16`, `19`, `20`, `23`, `24`, `25`, `26`, `28`, `29`, `30`, `31`, `33`, `34`, `35`, `36`, `37`, `38`, `40`, `42`, `43`, `44`, `45`, `46`, `47`, `49`, `50`, `51`, `52`, `53`, `54`, `56`, `57`, `58`, `59`, `60`, `62`, `63`, `64`, `65`, `66`, `67`, `68`, `69`, `70`, `71`, `72`, `73`, `74`, `75`, `76` |
> | **Read, found clean** | `03`, `04`, `05`, `10`–`15`, `17`, `18`, `21`, `22`, `27`, `32`, `39`, `41`, `48`, `55`, `61` |
>
> The earlier estimate — "roughly 20 more defects" in the then-unread modules —
> was low. The second pass found **substantially more than that**, including
> several that would stop a lesson dead. The complete list is in §8.
>
> Modules **19–76** remain self-contained teaching SQL: zero `<PLACEHOLDER>`
> tokens, illustrative account ids only (`123456789012`). They cannot break the
> deploy path. Several (`64` Kinesis/MSK, `69` Zero-ETL, `59` Redshift ML,
> `63` cross-account sharing) describe services this CDK does not build. Treat
> those as read-and-discuss, not run-as-is. See §7.

---

## Executive summary

The platform was built to a **single shared cluster** model. The course is
being run on a **per-learner deploy** model — eight people each running
`cdk deploy` with their own AWS credentials.

That change of model, plus an independent correctness pass against current
AWS documentation, surfaced **12 defects, 6 of them course-stopping.** All 12
are fixed. Two items remain that cannot be fixed in code and need an
administrative action before Monday.

**Recommendation: approve, conditional on the two pre-course actions in
§4.** The code is now structurally sound and documentation-verified. It has
still never been deployed to a real AWS account — that gap is unchanged by
this audit and is the main residual risk (§5).

### Before the audit

- Eight learners could not deploy. The second deploy onward would have failed
  midway on name collisions, leaving broken stacks to clean up by hand.
- Any deploy that got that far would have failed on two CloudFormation
  validation errors.
- If a deploy had succeeded, `sql/03` — the S3 Tables → Redshift lesson,
  which is the architectural centrepiece of the week — would have failed with
  a misleading error, and the documentation pointed at the wrong fix.

### After

- `cdk synth` is clean: 3 stacks, exit 0, **zero** CloudFormation validation
  warnings.
- Two-learner synth shows **zero** overlapping resource names.
- `sql/03` rewritten against the verified AWS syntax, with all three
  prerequisites now automated by one idempotent script.

---

## 1. Findings

Severity: **S1** stops the course · **S2** costs hours · **S3** costs money or
clarity.

| # | Sev | Finding | Status |
|---|-----|---------|--------|
| 1 | S1 | **13 resource names hardcoded.** Buckets, 3 IAM roles, KMS alias, cluster id, Glue DB, S3 Tables bucket, 2 Glue jobs and 3 stack names were fixed strings. The 2nd–8th learner deploying into one account collides on all of them, ~4 min in. | Fixed |
| 2 | S1 | **`sql/03` federated-catalog syntax wrong in three ways.** `DATABASE` was given the S3 namespace instead of the Glue resource link name; `CATALOG_ID` used the composite `<account>:s3tablescatalog/<bucket>` form where AWS requires a bare account id; the mandatory `REGION` clause was absent. | Fixed |
| 3 | S1 | **Lake Formation grants entirely missing.** Not in the code, not in the docs. Without them `CREATE EXTERNAL SCHEMA` *succeeds* and returns an empty table list — no error, no AccessDenied. The worst failure mode in the platform. | Fixed |
| 4 | S1 | **Glue resource link documented as optional.** SETUP.md said "needed only for Method 2". AWS requires it for **all three** query methods. | Fixed |
| 5 | S1 | **`AWS::S3Tables::Table` status casing.** `Compaction.Status` and `SnapshotManagement.Status` were `"Enabled"`; the resource accepts only `"enabled"`/`"disabled"`. The sibling `TableBucket` property uses the capitalised form — same service, same template, opposite casing. Passes `synth` as a warning, fails the deploy. | Fixed |
| 6 | S1 | **Em-dash in a SecurityGroup description.** CloudFormation validates `GroupDescription` against a charset that excludes `—`. Deploy-time failure whose error names no field. | Fixed |
| 7 | S2 | **Enhanced VPC routing + SSE-KMS + no KMS endpoint.** All COPY/UNLOAD traffic is forced through isolated subnets with no NAT. Every bucket is KMS-encrypted, so each COPY needs a KMS call that had no route out. Symptom: query sits in RUNNING until it times out. | Fixed — added KMS interface endpoint |
| 8 | S2 | **`awsdatacatalog` requires an IAM login.** `sql/03` §3.3 needs Federated Access to Spectrum. Connected as `nbsadmin` the catalog looks empty and reads like a permissions bug. Undocumented. | Fixed |
| 9 | S2 | **CDK CLI/library schema mismatch.** `requirements.txt` floats `aws-cdk-lib` to a version emitting cloud-assembly schema 54.0.0; CLI < 2.1136.0 cannot read it. Blocks `cdk synth` before anything else. | Documented + floor stated |
| 10 | S3 | **`nodes` defaulted to 2**, contradicting the single-node `ra3.large` cost model the README and stack docstring both argue for. Silently doubled every learner's cluster cost. | Fixed — default 1 |
| 11 | S3 | **`render_sql.sh` could half-render silently.** Unresolved placeholders were printed but the script still exited 0, so a partially-rendered SQL set could reach the room. | Fixed — exits non-zero |
| 12 | S3 | **`create_learners.sh` is obsolete** in the per-learner model — it creates 8 logins on one shared cluster. Left in place, now labelled. | Documented |

---

## 2. Evidence

### CDK synthesizes clean

```
$ cdk synth --quiet -c user=suren
Successfully synthesized to D:\NBS_Coaching_Redshift\infra\cdk.out
=== EXIT: 0 ===
```

Zero CloudFormation validation warnings. Before the fixes, the same command
produced seven `W3030` warnings and an `F3031` pattern violation.

### The `user` guard actually fires

```
$ cdk synth --quiet
ERROR: -c user=<yourname> is required.

$ cdk synth --quiet -c user=Suren-Sara
ERROR: user='suren-sara' is not usable as a resource name.
  Rules: 2-12 characters, start with a letter, lowercase letters and digits only.
```

Failing at synth with an explanation is the point — the alternative is
failing six minutes into a deploy with `already exists`.

### Per-learner isolation, proven not asserted

Synthed `user=suren` and `user=priya`, then extracted every `BucketName`,
`RoleName`, `ClusterIdentifier`, `TableBucketName`, `AliasName` and `Name`
from all six templates:

| suren | priya |
|---|---|
| `alias/nbs-suren-dev` | `alias/nbs-priya-dev` |
| `nbs_suren_raw_dev` | `nbs_priya_raw_dev` |
| `nbs-suren-dev` (cluster) | `nbs-priya-dev` |
| `nbs-suren-raw` / `-curated` / `-scripts` | `nbs-priya-raw` / `-curated` / `-scripts` |
| `nbs-suren-tables-dev` | `nbs-priya-tables-dev` |
| `nbs-suren-glue-dev` | `nbs-priya-glue-dev` |
| `nbs-suren-rs-spectrum-dev` | `nbs-priya-rs-spectrum-dev` |
| `nbs-suren-rs-s3tables-dev` | `nbs-priya-rs-s3tables-dev` |
| `nbs-suren-raw-to-bronze-dev` | `nbs-priya-raw-to-bronze-dev` |
| `nbs-suren-bronze-to-silver-dev` | `nbs-priya-bronze-to-silver-dev` |

Zero intersection, including CloudFormation export names.

### Sources for the S3 Tables corrections

Every change to `sql/03` traces to a specific AWS page, read during the audit:

- Redshift Database Developer Guide — *Query Amazon S3 Tables from Amazon
  Redshift* (the `CREATE EXTERNAL SCHEMA` form, the resource-link
  requirement, the FAS prerequisite for `awsdatacatalog`)
- Lake Formation Developer Guide — *Granting permissions* on S3 tables
  catalog objects (the three grant levels)
- Glue Developer Guide — *Enabling S3 Tables integration with the Data
  Catalog* (the `glue create-catalog` form used by the bootstrap script)

---

## 3. What changed

| File | Change |
|---|---|
| `infra/app.py` | Required, validated `user` context; every name derived from it; `nodes` default 1 |
| `infra/stacks/foundation_stack.py` | Per-learner names; KMS interface endpoint; ASCII-only CFN descriptions; VPC quota warning |
| `infra/stacks/lakehouse_stack.py` | Per-learner names; status casing; exports table-bucket name, namespace, resource-link name |
| `infra/stacks/redshift_stack.py` | Per-learner names; ASCII SG description; extra outputs |
| `infra/cdk.json` | Removed the shared-name defaults that made collisions possible |
| `sql/03_s3tables_federated_catalog.sql` | Rewritten. Correct syntax, all three methods, preflight checks, and a failure-mode guide |
| `scripts/bootstrap_s3tables.sh` | **New.** Automates the three prerequisites; idempotent; `--verify` and `--grants-only` |
| `scripts/render_sql.sh` | Per-learner; new placeholders; fails loudly on partial render |
| `SETUP.md` | Rewritten for per-learner deploy; quota and Lake Formation prerequisites; 8× cost model |
| `README.md` | Deploy flow, cost, status |

---

## 4. Two actions needed before Monday — neither is code

### 4.1 Raise the VPC quota ⚠ do this today

Default is **5 VPCs per region per account**. Each learner's stack creates
one. **The sixth learner's deploy fails** with `The maximum number of VPCs has
been reached`, about four minutes in, leaving a `ROLLBACK_COMPLETE` stack.

Service Quotas → Amazon VPC → "VPCs per Region" → request **15**.

Approval is usually quick but is not instant, and it cannot be worked around
on the morning. The alternative is one AWS account per learner.

### 4.2 Confirm Lake Formation data lake admin for every learner

The S3 Tables path needs it. Lake Formation console → Administrative roles
and tasks. `./scripts/bootstrap_s3tables.sh --user <slug> --verify` reports
clearly if it is missing.

---

## 5. Residual risk — stated plainly

**This has never been deployed.** Static verification is thorough; it is not
a deploy. Specifically still unproven:

| Unverified | Why it matters |
|---|---|
| A real `cdk deploy` | Synth validates structure and the CFN resource spec. It does not catch IAM propagation timing, S3 Tables regional behaviour, or quota limits. |
| The Glue Iceberg REST config | The `--conf` string wiring Spark to the S3 Tables REST catalog is written to the documented shape but has not run. Most likely single point of failure on day 2. |
| Any SQL against a live cluster | Nothing has been executed. `sql/03` is documentation-verified but not run. |
| Any SQL executed on a live cluster | All 76 modules are now read and documentation-verified, but **none has been run.** Every fix in §8 is verified against the AWS documentation, not against a running Redshift. |
| The `ra3.large` price | The one figure in this repo not checked against a published table. |

**Mitigation, and it is not optional: one person deploys end-to-end and runs
`sql/01`–`sql/04` before the other seven start.** Half a day. That converts
the largest residual risk into a known quantity while there is still time to
react. `bootstrap_s3tables.sh --verify` is designed to be the fast checkpoint
in that walk-through.

---

## 7. Modules 19–76 — what I can say without auditing them

A structural scan, not a correctness review:

| Property | Finding |
|---|---|
| Placeholder tokens | **Zero.** `render_sql.sh` has nothing to substitute in them, so it cannot half-render them. |
| Account-specific ARNs | None real. Illustrative ids only (`123456789012`, `111222333444`). |
| Deploy-path risk | **None.** They reference no resource this CDK creates. |
| Runnable as-is against this environment | **Partly.** Modules that need only Redshift (SQL semantics, window functions, SCD, sort keys, CTEs) will run. Modules describing services this CDK does not build will not. |

Modules that describe infrastructure the platform does **not** provision, and
so cannot be run end-to-end on day one:

- `59` Redshift ML — needs SageMaker
- `63` Data Sharing Cross-Account — needs a second account/namespace
- `64` Streaming Ingestion — needs Kinesis or MSK
- `69` Zero-ETL Integrations — needs Aurora or DynamoDB

Nothing is wrong with teaching these as concepts. The risk is a learner
hitting a wall mid-lab because a file looks runnable and is not. **Cheapest
mitigation: a one-line banner at the top of each of those four files saying
"concept module — requires infrastructure outside this platform".** Fifteen
minutes of work, and it removes the most likely source of day-3 confusion.

---

## 6. Assessment

The teaching content is strong and was not the problem. The SQL files carry
real explanation — the comments are the lesson and the queries make it
measurable — and the medallion pipeline exercises exactly the services the
team will meet.

What the audit found was a mismatch between how the platform was built
(one shared cluster) and how it is being run (eight independent deploys),
plus a genuinely difficult corner of AWS — the S3 Tables federated catalog —
where the original implementation had followed a plausible but incorrect
reading of the documentation. Both are now closed.

The honest risk is not the code. It is that a first deploy is a first
deploy, and there are eight of them happening at once on a Monday morning.
§4 and the §5 mitigation are what make that acceptable.

---

## 8. Second pass — modules 19–76 read line by line

**Date:** 2026-08-16 · **Method:** every system-view column, function name and
syntax construct checked against the live AWS documentation before any edit.

The first pass estimated ~20 further defects. The real number was higher, and
the severity was higher: several modules could not have run at all.

### 8.1 Things that would fail outright

| Where | Defect |
|---|---|
| `66`, `71`, `72`, `73`, `74`, `76` + 6 more | **Three schemas — `lab`, `gold`, `etl` — are referenced by 12 modules and created by none.** `sql/01` makes staging/analytics/admin, `sql/07` makes rpt. Every one of those 12 modules failed on its first statement. Also added `silver`, `bronze`, `bi`. |
| `26`, `34`, `44`, `45`, `46`, `47`, `50`, `52`, `62` | **`ON COMMIT DROP` — nine modules.** Redshift's `CREATE TABLE` and `CREATE TABLE AS` grammars have no `ON COMMIT` clause; temp tables are session-scoped. Module `45` taught it as "the mandatory standard". |
| `71` | **`LATERAL ( … )` keyword.** Absent from the documented FROM-clause grammar. Redshift provides lateral *semantics* via PartiQL unnesting, not the keyword. §5 was live SQL. |
| `73`, `69` | **`MERGE … WHEN MATCHED AND <cond>` and an alias on the MERGE target.** Neither exists in Redshift's grammar. Module `32` states this correctly; `73` and `69` contradicted it. |
| `56` | **`IFF()`** — Snowflake, not Redshift. |
| `58` | **`FNVD32_1`, `FNVD64_1`, `MURMUR3_32`** — the real names are `FNV_HASH` and `MURMUR3_32_HASH`. |
| `57` | **PostGIS `<->` operator** — Redshift has no indexes to back it. Also `ST_DWithin` called on `GEOGRAPHY` with a metre threshold; it takes `GEOMETRY` and measures degrees. |
| `52` | Materialized view selected `event_timestamp` and `region` from a table declared with only `sale_id` and `amount`. |
| `54` | Example selected `id` from a subquery that did not project it. |

### 8.2 Wrong system-view columns (all verified against the docs)

`23`, `24`, `33`, `50` — `sys_query_detail` has no `slice`, `local_scanned_bytes`
or `is_diskbased` · `26` — `svl_query_summary` uses `query`/`label`, not
`query_id`/`step_name` · `35` — `sys_query_history` has `service_class_id`,
`queue_time`, `execution_time` · `42` — no `error_code` · `44` — the lock-triage
queries used SVV_TRANSACTIONS columns against STL_LOCKS · `65` —
`short_query_accelerated` (a *character*, not boolean), not `is_accelerated` ·
`68` — SVV_TABLE_INFO is `schema`/`"table"`, not `schemaname`/`tablename` ·
`70` — five invalid columns on STL_WLM_RULE_ACTION, plus a nonexistent
`data_scanned_bytes` on SYS_SERVERLESS_USAGE · `74` — seven invalid columns on
SVL_QUERY_METRICS_SUMMARY, which is one row per *query*, in *seconds*.

### 8.3 Silently wrong results — the dangerous class

These ran without error and taught the wrong thing.

| Where | Defect |
|---|---|
| `20`, `49`, `50`, `53` | **`SYSDATE` returns transaction start, not statement start.** A procedure body is one transaction, so every `DATEDIFF(ms, v_step_start, SYSDATE)` logged **0**. Module `20` exists to teach per-step duration tracking; it recorded zeros. `GETDATE()` is the statement-scoped one. Module `53` documented the two backwards. |
| `76` | **The benchmarking lab could never pass its own correctness gate.** Its SLOW and FAST procedures filtered *different columns* (`created_at` vs `order_date`), so the Step 6 diff always reported FAIL. The module teaches "an optimisation must not change the output". |
| `66`, `76` | Seeded data from `stl_scan`, a system **log** table, so row counts varied per cluster and never reached the stated volume — breaking the "reproduce reliably" practice the lab teaches. |
| 17 blocks in 15 modules | Cross-join generators whose factors multiplied to **less than their `LIMIT`**, so the LIMIT never bound. Module `25` promised "~199,980 rows" — exact for 200,000 generated, but it generated 30,000. |
| `38` | `CHARGEBACK` was unreachable (every multiple of 20 is a multiple of 10, tested first), so that column was always 0.00. |
| `36` | Generated user_ids collided with the hand-crafted ones, so the bulk rows outranked them and the tie-breaker demonstration produced the wrong winner. |
| `73` | SCD2 change-detection hash concatenated five nullable columns with no `NVL` and no delimiter: one NULL made the hash NULL and the change undetectable. |
| `49` | Claimed to log stage failures; the handler only re-raised. |

### 8.4 Not changed — flagged instead

- **`IS DISTINCT FROM`** (module `56`): the AWS docs neither list nor exclude it.
  Working code was left alone rather than edited on a guess.
- **Module `61`**: RLS is enabled on `customer_pii_master` and the GDPR purge
  procedure then `UPDATE`s it. Redshift's restrictions on DML against
  RLS-protected tables were not confirmed either way. Worth a live test.
- **Module `66`** seeds 50M rows — several minutes and a few GB on a single-node
  `ra3.large`. A smaller `LIMIT` is noted inline for time-constrained sessions.

### 8.5 Verified clean after the pass

All 32 data generators reach their `LIMIT`. No unsupported token (`ON COMMIT`,
`LATERAL (`, `IFF(`, `FNVD*`, `MURMUR3_32`, `local_scanned_bytes`,
`is_accelerated`, `WHEN MATCHED AND`, `<->`) survives outside explanatory
comments. No module runs `VACUUM`, `ALTER TABLE APPEND` or
`CREATE EXTERNAL TABLE` inside a stored procedure, which Redshift forbids.
Every schema-qualified reference now resolves to a schema that is created,
except the external ones (`spectrum_raw`, `s3t_bronze`, `aurora_source`, and
the datashare databases in `63`), which come from `CREATE EXTERNAL SCHEMA`,
`CREATE DATABASE FROM INTEGRATION` and `CREATE DATABASE FROM DATASHARE`.
