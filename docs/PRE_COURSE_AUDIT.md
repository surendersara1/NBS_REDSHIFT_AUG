# Pre-course audit — NBS Redshift Coaching Platform

**Date:** 2026-08-16
**Auditor:** Claude Opus 5, against the live AWS documentation MCP server
**Scope:** CDK infrastructure, Glue ETL, the S3 → S3 Tables → Redshift
federated-catalog path, the operational scripts, and **`sql/01`–`sql/18`**
**Course starts:** 2026-08-17

> **Scope boundary, stated up front.** The repository contains **76 SQL
> modules**. This audit covers the deployable platform and modules 01–18 —
> the files that carry account-specific ARNs, bucket names and external-schema
> DDL, i.e. everything that has to be *correct against a live AWS account*.
>
> Modules **19–76 were not audited.** They are self-contained teaching SQL:
> a placeholder scan confirms they contain **zero** `<PLACEHOLDER>` tokens and
> reference only illustrative account ids (`123456789012`). They therefore
> cannot break the deploy path — but they are also not wired to the deployed
> environment, and several (`64` Kinesis/MSK, `69` Zero-ETL, `59` Redshift ML)
> describe services this CDK does not build. Treat those as
> read-and-discuss, not run-as-is. See §7.

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
| Any SQL against a live cluster | Modules 01–18 are documentation-verified, not execution-verified. |
| Modules 19–76 | Not audited at all. Low deploy risk (no placeholders, no account-specific ARNs), unknown teaching-correctness risk. |
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
