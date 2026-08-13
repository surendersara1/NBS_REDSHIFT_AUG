# External AWS material — what to clone, and what each is actually good for

Verified 2026-08-13. Clone these into a sibling directory, not into this
repo, so their licences and histories stay separate:

```bash
mkdir -p D:/NBS_Coaching_Redshift_external && cd D:/NBS_Coaching_Redshift_external
git clone https://github.com/awslabs/amazon-redshift-utils
git clone https://github.com/aws-samples/redshift-immersionday-labs
git clone https://github.com/aws/awesome-redshift
```

## 1. awslabs/amazon-redshift-utils — clone this one first

<https://github.com/awslabs/amazon-redshift-utils>

The highest-value external asset for this coaching. Two directories matter:

| Path | What it is |
|---|---|
| `src/AdminViews/` | ~40 SQL views over the system catalog. Install into the `admin` schema created in `sql/01`. |
| `src/AdminScripts/` | Tuning and troubleshooting scripts, runnable with `psql -f`. |

All views assume a schema named `admin` exists — `sql/01_setup_and_objects.sql`
creates it for exactly this reason.

The ones to install on day 5:

- `v_generate_tbl_ddl` — Redshift has **no** `SHOW CREATE TABLE`. This view
  is the substitute, and it alone justifies the clone.
- `v_object_dependency` — what breaks if I drop this.
- `v_get_obj_priv_by_user`, `v_generate_user_object_permissions` — the
  access-audit answer.
- `v_check_data_distribution` — skew per slice.
- `v_space_used_per_tbl` — storage by table.
- `v_open_session` — who is connected.

Maps directly onto **Day 5, exercise 5**.

## 2. aws-samples/redshift-immersionday-labs

<https://github.com/aws-samples/redshift-immersionday-labs>

Eight labs covering ELT, materialized views, data sharing, and Redshift ML.
Note that AWS has moved the canonical content to the hosted workshop at
<https://redshift-immersion.workshop.aws/> — the GitHub repo still carries
the SQL and CloudFormation, which is what you want for offline work.

Use it as a **supplement, not a replacement**. Its data model (TPC-H-ish
retail) is larger than ours and is genuinely better for demonstrating scale
effects on day 4. Its provisioning is CloudFormation and overlaps what our
CDK already builds — do not run both into one account without changing
stack names.

Worth lifting: the data sharing and Redshift ML labs, neither of which this
curriculum covers.

## 3. aws/awesome-redshift

<https://github.com/aws/awesome-redshift>

Curated index of Redshift tooling, blog posts, and workshops. Use it to find
material on topics as they come up, not as a teaching asset in itself.

## 4. aws-samples/amazon-redshift-streaming-workshop

<https://github.com/aws-samples/amazon-redshift-streaming-workshop>

Only relevant if the target project ingests from Kinesis or MSK. Streaming
ingestion is deliberately out of scope for the five days.

## 5. aws-samples/data-engineering-for-aws-immersion-day

<https://github.com/aws-samples/data-engineering-for-aws-immersion-day>

Broader than Redshift — Glue, Athena, EMR, Lake Formation. Its Glue labs are
a reasonable follow-on for anyone who wants more Spark than day 3 provides.

---

## AWS documentation that is worth reading directly

| Topic | URL |
|---|---|
| Node type details (the spec table) | <https://docs.aws.amazon.com/redshift/latest/mgmt/working-with-clusters.html> |
| Query S3 Tables from Redshift | <https://docs.aws.amazon.com/redshift/latest/dg/querying-s3Tables.html> |
| Integrating S3 Tables with Glue | <https://docs.aws.amazon.com/glue/latest/dg/glue-federation-s3tables.html> |
| MVs on external tables | <https://docs.aws.amazon.com/redshift/latest/dg/materialized-view-external-table.html> |
| CREATE MATERIALIZED VIEW limits | <https://docs.aws.amazon.com/redshift/latest/dg/materialized-view-create-sql-command.html> |
| Catalog federation | <https://docs.aws.amazon.com/lake-formation/latest/dg/catalog-federation.html> |
| Querying your data lake | <https://docs.aws.amazon.com/redshift/latest/gsg/data-lake.html> |

## Two deprecations to teach explicitly

1. **Python UDFs — end of support 2026-06-30, already past.** Enforcement is
   phased. Any tutorial demonstrating `LANGUAGE plpythonu` is teaching a
   dead feature. Use SQL UDFs, or Lambda UDFs for procedural logic.
   Announcement: <https://aws.amazon.com/blogs/big-data/amazon-redshift-python-user-defined-functions-will-reach-end-of-support-after-june-30-2026/>

2. **MV auto-refresh priority changed 2026-02-27.** On provisioned clusters
   on track P198 and newer, auto-refresh queries now run as *user* queries
   rather than background processes, so they compete with the workload.
   Relevant the moment someone asks why a refresh is queueing.

Both are recent enough that older internal material and most blog posts are
wrong about them.
