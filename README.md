# NBS Redshift Coaching Platform

A deployable Redshift teaching environment plus a five-day curriculum, for
eight application developers with no Redshift experience who are joining a
data warehouse project.

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

Everything the brief asked for is in that loop: raw → bronze → Glue join →
Redshift database and schema → materialized view → compute → written back to
a silver dump → read again through Spectrum, with the federated catalog and
S3 Tables wired throughout.

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
sql/
  01_setup_and_objects.sql     databases, schemas, roles, every object type
  02_spectrum_copy_unload.sql  external schema, COPY, UNLOAD, load errors
  03_s3tables_federated_catalog.sql   S3 Tables from Redshift, three methods
  04_modeling_matviews_compute.sql    DISTKEY/SORTKEY/ENCODE, MVs, the compute
  05_procedures.sql            five stored procedures
  06_svv_sys_deep_dive.sql     SVV / SYS / STL / STV / SVL, EXPLAIN
  07_views_and_bi_layer.sql    bound vs late-binding vs MV; the rpt/ BI layer
  08_external_schemas_two_kinds.sql   Spectrum vs FEDERATED (Postgres/MySQL),
                                      Lake Formation boundary, scan proof
  09_security_roles_rls_cls.sql       roles, ALTER DEFAULT PRIVILEGES,
                                      column- and row-level security
  10_four_mechanisms.sql       zone maps / collocation / columnar / stats,
                               each measured, then driven from a procedure
  11_sortkey_design.sql        sort-key design + the function-in-WHERE trap
  12_compression_encodings.sql az64/zstd/bytedict/runlength/raw, ANALYZE
                               COMPRESSION, and why CTAS tables end up huge
  13_constraints_are_hints.sql proves PK/UNIQUE are not enforced, and the
                               four tests you run instead
  14_auto_optimization.sql     what DISTSTYLE/SORTKEY/ENCODE AUTO really do
  15_fact_dimension_design.sql grain -> columns -> distkey -> sortkey ->
                               dimensions -> tests, with the 4 post-load checks
  16_copy_in_depth.sql         slice count, file count, manifests, and
                               proving parallelism from stl_load_commits
  17_dialect_for_mysql_mssql_devs.sql   READ FIRST — porting traps, SUPER/JSON,
                               habits to unlearn
  18_applications_transactions_wlm.sql  Data API vs JDBC, serialization
                               retries, WLM, the 6-step tuning runbook
scripts/bootstrap_s3tables.sh  s3tablescatalog + resource link + Lake Formation
                               grants; idempotent, with --verify
scripts/render_sql.sh          resolves placeholders -> sql/_resolved/
scripts/create_learners.sh     eight logins on ONE shared cluster; unused in the
                               per-learner-deploy model, kept for reference
docs/PRE_COURSE_AUDIT.md       what was broken before the course, and the proof
docs/NAMING.md                 why the bucket is nbs-<slug>-raw-<account>
docs/AWS_LABS_REFERENCES.md    what to clone from AWS and what it is good for
CURRICULUM.md                  the five-day plan
```

## Deploy

**Every learner deploys their own copy.** Pick a slug (2–12 lowercase chars)
and use it everywhere — it is what keeps eight deployments from colliding in
one account. `cdk` refuses to synthesize without it.

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

**One AWS account per learner.** Each person deploys into their own account
with their own VPC, so nothing is shared and nothing can collide. The 5-VPC
default limit is per account and one VPC per account is nowhere near it —
**there is no quota to raise.** Each learner runs `cdk bootstrap` once in
their own account and adds themselves as Lake Formation data lake admin; both
are self-serve. See [SETUP.md §1](SETUP.md).

Open **Redshift Query Editor v2** in the console and work through `sql/`
**in numeric order** — the files build on each other's objects:

| File | Needs |
|---|---|
| `04` | the Glue jobs to have run (silver Iceberg table) |
| `07` | `04` — builds `dim_date` on top of `fct_customer_orders` |
| `10`, `11` | `04` and `07` |
| `12`, `15` | `11` — both read `analytics.fct_retail_sales` |
| `15` | `13` — calls `sp_assert_unique` |

Running `15` before `11` fails with "relation fct_retail_sales does not
exist", which is the one out-of-order failure worth warning the room about. The cluster has no public endpoint deliberately — Query Editor v2
reaches it through the Data API, so eight people can connect on day one
without VPN, security-group, or psql setup.

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

Per learner: roughly **$0.25/hour** for the `ra3.large` node plus
**~$0.04/hour** for the Glue and KMS interface endpoints. Everything else is
negligible at this data volume.

**Eight learners, five 8-hour days, paused overnight: roughly $100–130.**

```bash
aws redshift pause-cluster  --cluster-identifier nbs-$USER_SLUG-dev
aws redshift resume-cluster --cluster-identifier nbs-$USER_SLUG-dev
```

Note that **interface endpoints keep billing while the cluster is paused**
(~$27 across eight learners for a week of wall-clock). That is the price of
running no NAT gateway, which would cost ~$32/month each. `cdk destroy`
nightly instead of pausing if that matters.

Tear down with `cdk destroy --all -c user=$USER_SLUG`. Three things it will
not remove — see [SETUP.md §10](SETUP.md).

## Status

Audited and corrected 2026-08-16 — see
[docs/PRE_COURSE_AUDIT.md](docs/PRE_COURSE_AUDIT.md) for the full finding
list and evidence.

| | State |
|---|---|
| CDK synthesizes | **Verified.** 3 stacks, exit 0, zero CFN validation warnings |
| Per-learner isolation | **Verified.** `suren` vs `priya` synth, zero name overlap |
| SQL vs AWS docs | **Verified** against the Redshift Database Developer Guide |
| Deployed to an account | **Never run.** The first deploy is a real first deploy |

Budget half a day for one person to walk the path end-to-end before the other
seven start.
