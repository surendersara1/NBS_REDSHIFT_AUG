# NBS Redshift Coaching Platform

A deployable Redshift teaching environment plus **77 numbered SQL modules**
(81 files, counting the `.1`/`.2` sub-modules) and a five-day curriculum, for
application developers with no Redshift experience who are joining a data
warehouse project.

Two things live here, and they are used differently:

1. **The lakehouse platform** — CDK stacks, Glue jobs, seed data, and modules
   `01`–`18`. You deploy it into your own AWS account and work through those
   modules against your own cluster.
2. **The SQL masterclass** — modules `19`–`77`. Each file generates its own
   data with `GENERATE_SERIES` and runs on any Redshift cluster or Serverless
   workgroup. No CDK deploy, no S3, no Glue.

Built from the NBS template library: composites in `E:\F369_LLM_TEMPLATES`,
canonical AWS patterns from the partials in
`E:\F369_CICD_Template\prompt_templates\partials\`.

## The pipeline this builds

```
  CSV (parent + child)
        │  cdk deploy uploads data/seed/
        ▼
  s3://nbs-raw-suren/parent/  /child/          RAW
        │  Glue: job_raw_to_bronze.py — typed, deduped, quarantined
        ▼
  S3 Tables (Iceberg)  coaching.bronze_customers
                       coaching.bronze_orders   BRONZE
        │  Glue: job_bronze_join_to_silver.py — the parent/child join
        ▼
  S3 Tables (Iceberg)  coaching.silver_customer_orders   SILVER
        │  Redshift reads it in place via the s3tablescatalog federated catalog
        ▼
  Redshift  analytics.fct_customer_orders      GOLD, native
            analytics.mv_segment_daily         materialized view
            analytics.fct_customer_metrics     window-function compute
        │  UNLOAD ... PARTITION BY (ltv_tier)
        ▼
  s3://nbs-raw-suren-curated/silver/customer_metrics/
        │  registered as an external table
        ▼
  Redshift Spectrum  spectrum_raw.silver_customer_metrics
```

Raw → bronze → Glue join → Redshift database and schema → materialized view →
compute → written back to a silver dump → read again through Spectrum, with
the federated catalog and S3 Tables wired throughout.

## Layout

```
infra/                  AWS CDK (Python)
  app.py                three stacks, explicit dependencies
  stacks/foundation_stack.py   VPC (no NAT), buckets, CMK
  stacks/lakehouse_stack.py    S3 Tables, Glue database, two Glue jobs
  stacks/redshift_stack.py     ra3.large single node, Spectrum + S3 Tables IAM
data/
  generate_sample_data.py      seeded parent/child CSVs with injected defects
  seed/parent/customers.csv    505 rows
  seed/child/orders.csv        5,000 rows
glue/
  job_raw_to_bronze.py         raw CSV -> bronze Iceberg, idempotent MERGE
  job_bronze_join_to_silver.py broadcast join -> silver Iceberg
sql/                    77 modules — see the module map below
scripts/
  bootstrap_s3tables.sh        s3tablescatalog + resource link + Lake Formation
                               grants; idempotent, with --verify
  render_sql.sh                resolves placeholders -> sql/_resolved/
  create_learners.sh           eight logins on ONE shared cluster; unused in the
                               per-learner-deploy model, kept for reference
  audit_sql_files.py           lints sql/ for stub procedures and placeholders
docs/
  PRE_COURSE_AUDIT.md          what was broken before the course, and the proof
  COVERAGE_AND_GAPS.md         the boundary of the course — what it does not teach
  NAMING.md                    why the bucket is nbs-<slug>-raw-<account>
  PLACEHOLDERS.md              the tokens render_sql.sh substitutes
  AWS_LABS_REFERENCES.md       what to clone from AWS and what it is good for
Design/                 the blueprint the SQL modules were generated from
  PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md   the practices that
                               modules 19-50 each map back to
  applied_redshift.md          the generation spec for modules 19-50
  missing_elements.md          the gap list that drove modules 63-77
PDF_Concepts/           rendered concept decks (Modules 00-03)
TeachMe-Lakehouse/      separate lakehouse enablement track — lectures,
                        diagrams, ops-console mockup; has its own README
CURRICULUM.md           the five-day plan
SETUP.md                account prerequisites, teardown, troubleshooting
```

## The module map

### `01`–`18` — the platform. Needs the deploy.

Run these in numeric order against your own cluster; they build on each
other's objects.

| | |
|---|---|
| `01_setup_and_objects` | databases, schemas, users, groups, every object type |
| `02_spectrum_copy_unload` | external schema, COPY, UNLOAD, load errors |
| `03_s3tables_federated_catalog` | S3 Tables (Iceberg) via the federated Glue catalog, three methods |
| `04_modeling_matviews_compute` | DISTKEY/SORTKEY/ENCODE, MVs, the compute round trip |
| `05_procedures` | five stored procedures |
| `06_svv_sys_deep_dive` | SVV / SYS / STL / STV / SVL, EXPLAIN |
| `07_views_and_bi_layer` | bound vs late-binding vs materialized; the `rpt/` BI layer |
| `08_external_schemas_two_kinds` | Spectrum vs FEDERATED, the Lake Formation boundary |
| `09_security_roles_rls_cls` | roles, ALTER DEFAULT PRIVILEGES, column- and row-level security |
| `10_four_mechanisms` | zone maps / collocation / columnar / stats — each measured |
| `11_sortkey_design` | sort-key design and the function-in-WHERE trap |
| `12_compression_encodings` | az64/zstd/bytedict/runlength/raw, ANALYZE COMPRESSION |
| `13_constraints_are_hints` | proves PK/UNIQUE are not enforced, and what to do instead |
| `14_auto_optimization` | what DISTSTYLE/SORTKEY/ENCODE AUTO really do |
| `15_fact_dimension_design` | grain → columns → distkey → sortkey → dimensions → tests |
| `16_copy_in_depth` | slices, file counts, manifests, parallelism from `stl_load_commits` |
| `17_dialect_for_mysql_mssql_devs` | **read first** — porting traps, SUPER/JSON, habits to unlearn |
| `18_applications_transactions_wlm` | Data API vs JDBC, serialization retries, WLM, the 6-step runbook |

Dependencies inside this block:

| File | Needs |
|---|---|
| `04` | the Glue jobs to have run (silver Iceberg table) |
| `07` | `04` — builds `dim_date` on top of `fct_customer_orders` |
| `10`, `11` | `04` and `07` |
| `12`, `15` | `11` — both read `analytics.fct_retail_sales` |
| `15` | `13` — calls `sp_assert_unique` |

Running `15` before `11` fails with "relation fct_retail_sales does not
exist", which is the one out-of-order failure worth knowing about.

### `19`–`50` — procedure optimization. Self-contained.

Written for engineers who will maintain thousands of Redshift stored
procedures. Every file follows the same shape: business scenario → data
generation block (`GENERATE_SERIES`, deliberate skew) → the naive version →
the measurement → the rewrite. Each maps to numbered practices in
[Design/PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md](Design/PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md).

| | |
|---|---|
| `19` | input validation and failing early |
| `20` | reproduce, measure, and audit |
| `21` | idempotency and watermarks |
| `22` | transaction blocks and rollbacks |
| `23` | set-based vs row-by-row (the app dev curse) |
| `24` | sargable predicates — preserving zone-map pruning |
| `25` | EXISTS vs IN and massive subquery lists |
| `26` | CTEs vs explicit temp tables |
| `27` | exploding joins and grain mismatches |
| `28` | distribution key alignment — DS_DIST_NONE vs DS_DIST_BOTH |
| `29` | broadcast dimensions — DISTSTYLE ALL for small lookups |
| `30` | filtering before joins — predicate pushdown |
| `31` | compound vs interleaved vs auto sort keys |
| `32` | MERGE vs DELETE/INSERT vs ALTER TABLE APPEND |
| `33` | late-arriving data and lookback windows |
| `34` | staged loads and ANALYZE on temp tables |
| `35` | batching massive loads — transaction log and commits |
| `36` | handling duplicates deterministically |
| `37` | GROUPING SETS, ROLLUP, CUBE |
| `38` | conditional aggregations — SUM(CASE) pivoting vs multi-joins |
| `39` | time-series gap filling — calendar dimensions and LOCF |
| `40` | arrays, JSON, SUPER, PartiQL unnesting |
| `41` | dynamic SQL in procedures — EXECUTE and quoting |
| `42` | exception handling and context |
| `43` | VACUUM and maintenance automation |
| `44` | locks, blocking, and concurrency conflicts |
| `45` | temp table lifecycle and catalog bloat |
| `46`–`48` | medallion: bronze→silver cleansing, silver→gold SCD2, silver→gold fact |
| `49` | orchestration, control tables, audit drivers |
| `50` | the master optimized enterprise pipeline |

### `51`–`62` — language and object deep dives. Self-contained.

| | |
|---|---|
| `51_Olap_Functions_Basics` | 16 window functions on tiny printed data — **start here** |
| `51.1_Olap_Function` | the advanced version; assumes `51` |
| `52_All_Table_Types` | permanent, temp, external, views, materialized views |
| `52.1_Join_Types` | MERGE vs HASH vs NESTED LOOP |
| `52.2_Locking_Object` | table locks, transactions, blocked sessions — two-session labs |
| `53`–`58` | 20 enterprise scenarios each: date/time, string and regex, JSON and SUPER, conditional and logical, geospatial, cryptographic and hash |
| `59_machine_learning_redshift_ml` | Redshift ML and SageMaker integration |
| `60_Storage_Architecture` | hybrid storage and lakehouse deep dive |
| `61_Security_Governance_Compliance` | GDPR and HIPAA — masking, RLS, right-to-be-forgotten purges |
| `62_Programming_Features` | the procedural and programming language masterclass |
| `62.1_Programming_And_Building_Business_Reports_Via_Code` | a retail warehouse built by code — 15 dimensions, 3 facts, 10 MVs, 10 business questions |

### `63`–`77` — enterprise platform features.

Several of these need AWS-side resources (an Aurora cluster, a Kinesis
stream, a second account) and are written to be read and adapted rather than
run cold.

| | |
|---|---|
| `63` | data sharing — cross-account, cross-cluster, zero-copy |
| `64` | streaming ingestion — Kinesis Data Streams and MSK |
| `65` | result cache, query acceleration, short-query optimization |
| `66` | approximate queries, HLL sketches, probabilistic counting |
| `67` | elastic resize, cluster scaling, Serverless RPU management |
| `68` | disaster recovery, cross-region snapshots, high availability |
| `69` | Zero-ETL integrations — Aurora, DynamoDB and beyond |
| `70` | cost control, RPU budgets, FinOps |
| `71` | LATERAL joins, array unnesting, correlated subquery replacement |
| `72` | recursive CTEs and hierarchical / graph traversal |
| `73` | SCD types 1, 2, 3 and 6 |
| `74` | query diagnostics — systematic performance triage |
| `75` | COPY advanced patterns — Parquet, manifests, error handling, retry |
| `76` | performance benchmarking lab — the complete optimization workflow |
| `77` | materialized view refresh — AUTO vs manual, incremental vs full |

## Deploy

Only needed for modules `01`–`18`. Modules `19`+ run on any cluster you
already have.

**You deploy your own copy into your own AWS account.** Pick a slug (2–12
lowercase chars) and use it everywhere — it names every resource
(`nbs-<slug>-*`) and the scripts key off it. `cdk` refuses to synthesize
without it.

```bash
npm install -g aws-cdk@latest                       # CLI must be >= 2.1136.0

cd infra
python -m venv .venv && source .venv/Scripts/activate   # Windows
pip install -r requirements.txt

cd ../data && python generate_sample_data.py && cd ../infra

export USER_SLUG=suren                              # <-- yours
cdk bootstrap                                       # once per account/region
cdk deploy --all -c user=$USER_SLUG --require-approval never
```

Then wire S3 Tables to Redshift, run the pipeline, and resolve the SQL:

```bash
cd ..
./scripts/bootstrap_s3tables.sh --user $USER_SLUG   # catalog + link + LF grants
aws glue start-job-run --job-name nbs-$USER_SLUG-raw-to-bronze-dev
aws glue start-job-run --job-name nbs-$USER_SLUG-bronze-to-silver-dev
./scripts/render_sql.sh --user $USER_SLUG           # -> sql/_resolved/
```

**Your own AWS account, your own root login, your own everything.** Nothing
here is shared with anyone. The 5-VPC default limit is per account and this
stack creates one, so **there is no quota to raise**. Run `cdk bootstrap` once
in your account + region and add yourself as Lake Formation data lake admin —
both self-serve, both yours. See [SETUP.md §1](SETUP.md).

Open **Redshift Query Editor v2** in the console and work through `sql/` in
numeric order. The cluster has no public endpoint deliberately — Query Editor
v2 reaches it through the Data API, so you can connect without VPN,
security-group, or `psql` setup.

## Decisions worth knowing before you review this

**`ra3.large`, single node.** Verified against the Redshift Management Guide
node-type table: `ra3.large` is the only *modern* node type that runs as a
single node (`rg.large` has a 2-node minimum, so it costs double).
`dc2.large` is cheaper still but is previous-generation and lacks managed
storage — it would teach storage behaviour the team will never meet again.

**The bucket is `nbs-raw-suren`, not `NBS_RAW_SUREN`.** S3 bucket names may
not contain uppercase letters or underscores; the requested name cannot be
created and CloudFormation rejects it at create time. See
[docs/NAMING.md](docs/NAMING.md).

**No NAT gateway.** An S3 gateway endpoint (free) plus a Glue interface
endpoint carry COPY, UNLOAD, and catalog traffic. A NAT gateway would add
roughly $32/month for no teaching value.

**No passwords in SQL.** `scripts/create_learners.sh` generates them
server-side and stores them in Secrets Manager. A `CREATE USER ... PASSWORD
'literal'` lands in git history *and* in `STL_QUERYTEXT`.

**Two live deprecations are taught explicitly.** Redshift Python UDFs
reached end of support on 2026-06-30 — already past — so the curriculum
teaches SQL and Lambda UDFs instead. MV auto-refresh changed priority on
2026-02-27. Most existing material is wrong about both.

## Cost

Your account, roughly **$0.25/hour** for the `ra3.large` node plus
**~$0.04/hour** for the Glue and KMS interface endpoints. Everything else is
negligible at this data volume.

**Five 8-hour days, paused overnight: roughly $13–17 on your bill.**

```bash
aws redshift pause-cluster  --cluster-identifier nbs-$USER_SLUG-dev
aws redshift resume-cluster --cluster-identifier nbs-$USER_SLUG-dev
```

Note that **interface endpoints keep billing while the cluster is paused**
(~$3.40 for a week of wall-clock). That is the price of running no NAT
gateway, which would cost ~$32/month. `cdk destroy` nightly instead of
pausing if that matters.

Modules `19`–`77` generate their own data, some of it at million-row scale.
On Serverless that is RPU-seconds; on a paused-overnight `ra3.large` it is
already inside the figure above.

Tear down with `cdk destroy --all -c user=$USER_SLUG`. Three things it will
not remove — see [SETUP.md §10](SETUP.md).

## Status

The platform half (`01`–`18`, CDK, Glue) was audited and corrected
2026-08-16 — see [docs/PRE_COURSE_AUDIT.md](docs/PRE_COURSE_AUDIT.md) for the
finding list and evidence, and
[docs/COVERAGE_AND_GAPS.md](docs/COVERAGE_AND_GAPS.md) for what the course
deliberately does not cover.

| | State |
|---|---|
| CDK synthesizes | **Verified.** 3 stacks, exit 0, zero CFN validation warnings |
| Per-learner isolation | **Verified.** `suren` vs `priya` synth, zero name overlap |
| `01`–`18` vs AWS docs | **Verified** against the Redshift Database Developer Guide |
| `19`–`77` | Written against AWS docs and linted by `scripts/audit_sql_files.py`; not runtime-proven end to end |
| Deployed to an account | **Never run.** The first deploy is a real first deploy |

`CURRICULUM.md` still covers the five-day plan over modules `01`–`18` only;
`19`–`77` are self-paced reference material and are not scheduled into it.

Budget half a day for one person to walk the deploy path end-to-end before
anyone else starts.
