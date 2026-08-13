# Setup — from empty machine to first query

Read this fully before running anything. Total time to a working cluster:
**about 45 minutes**, most of it waiting for the Redshift cluster to create.

---

## 0. Status — read this first

Be clear on what has and has not been proved, because it changes how you
approach the first hour.

| | State |
|---|---|
| CDK synthesizes | **Verified.** All three stacks, clean, template inspected |
| Python parses | **Verified.** All 8 files |
| Sample data generates | **Verified.** Runs, produces the injected defects |
| CDK deployed to AWS | **Never run.** No account has seen this |
| SQL executed on a cluster | **Never run.** Written against documented behaviour |
| Glue jobs executed | **Never run.** |

So: the infrastructure code is structurally sound and the SQL is written
against verified AWS documentation, but **the first deploy is a real first
deploy**. Budget half a day for one person to walk it through before the
other seven arrive. Section 7 lists exactly what is most likely to bite.

---

## 1. Prerequisites

| Tool | Version | Check |
|---|---|---|
| Python | 3.9+ | `python --version` |
| Node.js | 18+ | `node --version` |
| AWS CDK CLI | 2.x | `npm install -g aws-cdk && cdk --version` |
| AWS CLI | v2 | `aws --version` |
| Git Bash / WSL | any | for the `.sh` scripts on Windows |

AWS account requirements:

- Permission to create VPC, S3, KMS, IAM roles, Redshift, Glue, S3 Tables.
- A region where **`ra3.large`** and **S3 Tables** are both available.
  `us-east-1` and `us-west-2` are safe. Verify before deploying elsewhere:
  ```bash
  aws redshift describe-orderable-cluster-options \
    --node-type ra3.large --region us-east-1 --query 'OrderableClusterOptions[0]'
  aws s3tables list-table-buckets --region us-east-1
  ```
  The second command failing with `UnknownOperation` means S3 Tables is not
  available there — pick another region.

Confirm your identity before you start:

```bash
aws sts get-caller-identity
```

---

## 2. Clone and install

```bash
git clone <your-repo-url> NBS_Coaching_Redshift
cd NBS_Coaching_Redshift

cd infra
python -m venv .venv

# Windows (Git Bash)
source .venv/Scripts/activate
# macOS / Linux
source .venv/bin/activate

pip install -r requirements.txt
```

`aws-cdk-lib>=2.238.0` is a hard floor — the `aws_s3tables` L1 constructs
do not exist before it.

---

## 3. Generate the sample data

```bash
cd ../data
python generate_sample_data.py
```

Expect:

```
parent -> data/seed/parent/customers.csv  (505 rows, 5 dup + 5 null-name)
child  -> data/seed/child/orders.csv      (5000 rows, 50 orphan + 50 bad-qty)
```

Those defects are deliberate — the quarantine and orphan labs depend on
them. Do not "clean" the data.

Run this **before** `cdk deploy`: the deploy uploads `data/seed/` to the raw
bucket, and the asset must exist at synth time.

---

## 4. Deploy

```bash
cd ../infra
export CDK_DEFAULT_REGION=us-east-1     # or your chosen region

cdk bootstrap          # once per account+region, ever
cdk synth              # sanity check — should print three templates
cdk deploy --all --require-approval never
```

**Bucket name collision.** S3 bucket names are globally unique. If
`nbs-raw-suren` is taken, override rather than editing the stack:

```bash
cdk deploy --all -c raw_bucket=nbs-raw-suren-$(aws sts get-caller-identity --query Account --output text)
```

Cluster creation takes **10–15 minutes**. Save the outputs:

```bash
aws cloudformation describe-stacks --stack-name nbs-coaching-redshift-dev \
  --query 'Stacks[0].Outputs' --output table
```

You need `ClusterEndpoint`, `MasterSecretArn`, `SpectrumRoleArn`,
`S3TablesRoleArn`.

---

## 5. Two manual steps CDK cannot do

These are **not** optional, and they are not in the stack because neither
has CloudFormation support.

### 5.1 Integrate S3 Tables with the Glue Data Catalog

A one-time, per-account-and-region action. Without it, `sql/03` fails with
"database does not exist" — which reads like a typo rather than a missing
integration.

Console: **S3 → Table buckets → Enable integration with AWS analytics
services.**

Verify:

```bash
aws glue get-catalog --catalog-id s3tablescatalog --region us-east-1
```

### 5.2 Create the Glue resource link

Needed only for Method 2 in `sql/03` (the auto-mounted `awsdatacatalog`).
Method 1 works without it.

Console: **AWS Glue → Databases → Create → Resource link**, named
`coaching_link`, pointing at the `coaching` namespace under
`s3tablescatalog/<table-bucket-name>`.

---

## 6. Create the learner logins, then run the pipeline

```bash
cd ..
chmod +x scripts/*.sh

./scripts/create_learners.sh nbs-coaching-dev coaching <MasterSecretArn>
```

Eight logins, random passwords generated server-side and stored in Secrets
Manager as `nbs-coaching/learner01` … `learner08`. No password is ever
written to disk or to shell history. Hand each learner only their own:

```bash
aws secretsmanager get-secret-value --secret-id nbs-coaching/learner01 \
  --query SecretString --output text
```

Run the Glue jobs, in this order:

```bash
aws glue start-job-run --job-name nbs-coaching-raw-to-bronze-dev
# wait for SUCCEEDED before starting the next
aws glue get-job-run --job-name nbs-coaching-raw-to-bronze-dev --run-id <id> \
  --query 'JobRun.JobRunState'

aws glue start-job-run --job-name nbs-coaching-bronze-to-silver-dev
```

Then resolve the SQL placeholders:

```bash
./scripts/render_sql.sh nbs-coaching dev us-east-1
```

This reads the stack outputs and writes runnable copies to `sql/_resolved/`.
**Learners use `sql/_resolved/`, not `sql/`.** Hand-substituting 47
placeholders across 16 files, eight times over, is how a Monday gets lost.

---

## 7. Run the SQL — and the order matters

Open **Redshift Query Editor v2** in the console. No VPN, no security group,
no psql: the cluster has no public endpoint by design and Query Editor v2
reaches it over the Data API.

Work through `sql/_resolved/` **in numeric order**. The dependency chain:

| File | Requires |
|---|---|
| `01` | nothing |
| `02` | `01` |
| `03` | §5.1 integration done |
| `04` | `03` and both Glue jobs |
| `05` | `04` |
| `06` | `04` |
| `07` | `04` |
| `08` | `02` |
| `09` | `01`, `07` |
| `10`, `11` | `04`, `07` |
| `12`, `15` | `11` (both read `analytics.fct_retail_sales`) |
| `13` | `05` (uses `analytics.dq_results`) |
| `15` | `13` (calls `sp_assert_unique`) |
| `16` | `02` |

Running `15` before `11` fails with *relation "fct_retail_sales" does not
exist*. That is the one out-of-order failure worth warning the room about.

---

## 8. What is most likely to bite on first deploy

Ranked by how likely, and each with the actual fix:

1. **S3 Tables not integrated with Glue** → `sql/03` fails with "database
   does not exist". Do §5.1.
2. **`CATALOG_ID` format in `sql/03`.** It is
   `'<account>:s3tablescatalog/<table-bucket-name>'`, not just the account.
   Wrong value produces "database does not exist", not a permissions error.
3. **Glue job Iceberg config.** The `--conf` string in
   `lakehouse_stack.py` wires the Iceberg REST catalog. If the job fails on
   `NoSuchCatalog`, check the `warehouse` and `uri` values against
   `aws s3tables list-table-buckets`.
4. **RLS in `sql/09`.** `CREATE RLS POLICY` needs the right cluster version
   and `sys:secadmin`. If it errors, skip §9.4 — nothing downstream depends
   on it.
5. **`ANALYZE COMPRESSION` on an empty staging copy** (`sql/12` §12.4)
   returns nothing useful. The file already widens the date window; widen
   further if your data lands outside it.
6. **`stl_load_commits` empty** in `sql/16` if you have not run a COPY in
   that session. Run the `sql/02` COPY first.
7. **Learner visibility.** A learner seeing one row where you see hundreds
   in `sql/06` means `SYSLOG ACCESS UNRESTRICTED` did not apply. Re-run the
   `CREATE USER` for that learner.

---

## 9. Cost, and pausing

The `ra3.large` node is roughly **$0.24–0.30/hour** — confirm against
current pricing for your region, as this is the one figure in this repo not
verified against a published table. Everything else is negligible at this
volume.

**Pause every evening.** A paused cluster bills storage only:

```bash
aws redshift pause-cluster  --cluster-identifier nbs-coaching-dev
aws redshift resume-cluster --cluster-identifier nbs-coaching-dev
```

Resume takes a few minutes — start it before the room arrives.

A week of 8-hour days, paused overnight, is roughly $10–15 of compute.

---

## 10. Teardown

```bash
cd infra
cdk destroy --all
```

Buckets auto-delete in `dev`, so the destroy will not hang on non-empty
buckets. Two things `cdk destroy` will **not** remove — clean them up
yourself:

```bash
# learner secrets (they have a 7-day recovery window by default)
for i in 01 02 03 04 05 06 07 08; do
  aws secretsmanager delete-secret --secret-id "nbs-coaching/learner${i}" \
    --force-delete-without-recovery
done

# the S3 Tables namespace/tables, if the table bucket refuses to delete
aws s3tables list-tables --table-bucket-arn <TableBucketArn>
```

---

## 11. Handing it to the room

Give each learner:

1. Console access to the Redshift and Glue consoles, read-only elsewhere.
2. Their own Secrets Manager retrieval command from §6.
3. [CURRICULUM.md](CURRICULUM.md) — the five-day plan.
4. `sql/_resolved/` — the runnable SQL.

Keep for yourself: the `nbsadmin` secret, and the ability to pause/resume.

The one instruction worth repeating on day one: **run the files in order,
and read the comments.** The comments carry the teaching; the SQL is just
what makes it measurable.
