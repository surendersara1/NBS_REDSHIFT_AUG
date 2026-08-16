# Setup — from empty laptop to first query

**Every learner deploys their own copy.** Each person runs these steps with
their own AWS credentials and their own `user` slug. Nothing is shared except
the AWS account (if you are all in one) and the `s3tablescatalog` federated
catalog, which the first person to run the bootstrap script creates for
everyone.

Read this fully before running anything. Time to a working cluster: **about
45 minutes**, most of it waiting for Redshift to create.

---

## 0. Status — read this first

| | State |
|---|---|
| CDK synthesizes | **Verified 2026-08-16.** 3 stacks, exit 0, zero CFN validation warnings |
| Per-learner name isolation | **Verified.** Synthed `user=suren` vs `user=priya`, zero overlapping resource names |
| Shell scripts parse | **Verified.** `bash -n` clean on all 4 |
| Python parses | **Verified.** All 8 files |
| Sample data generates | **Verified.** Runs, produces the injected defects |
| SQL syntax vs AWS docs | **Verified 2026-08-16** against the Redshift Database Developer Guide |
| CDK deployed to AWS | **Never run.** No account has seen this |
| Glue jobs executed | **Never run.** |
| SQL executed on a cluster | **Never run.** |

The infrastructure code is structurally sound and the SQL is written against
verified AWS documentation, but **the first deploy is a real first deploy**.
One person should walk the whole path end-to-end before the other seven
start. Section 8 lists what is most likely to bite.

---

## 1. Prerequisites

| Tool | Version | Check |
|---|---|---|
| Python | 3.9+ | `python --version` |
| Node.js | 18+ | `node --version` |
| AWS CDK CLI | **2.1136.0+** | `cdk --version` |
| AWS CLI | v2 | `aws --version` |
| Git Bash / WSL | any | for the `.sh` scripts on Windows |

### The CDK CLI version is a hard floor, not a suggestion

`requirements.txt` floats `aws-cdk-lib` to the latest 2.x, which currently
emits cloud-assembly schema **54.0.0**. A CLI older than 2.1136.0 cannot read
it and fails with:

```
Cloud assembly schema version mismatch: Maximum schema version supported is
53.x.x, but found 54.0.0. You need at least CLI version 2.1136.0
```

Fix, before anything else:

```bash
npm install -g aws-cdk@latest
cdk --version          # must be >= 2.1136.0
```

### Check your AWS CLI actually works

A Python 3.9 install with a broken `awscli` module is common on Windows and
produces `ModuleNotFoundError: No module named 'awscli'`. Verify now, not at
step 5:

```bash
aws --version
aws sts get-caller-identity
```

If either fails, install AWS CLI v2 from the MSI installer — not via `pip`.

### Account requirements

- Permission to create VPC, S3, KMS, IAM roles, Redshift, Glue, S3 Tables.
- **Lake Formation data lake admin.** Required for the S3 Tables path.
  Lake Formation console → Administrative roles and tasks → add yourself.
- A region where **`ra3.large`** and **S3 Tables** are both available.
  `us-east-1` and `us-west-2` are safe:
  ```bash
  aws redshift describe-orderable-cluster-options \
    --node-type ra3.large --region us-east-1 --query 'OrderableClusterOptions[0]'
  aws s3tables list-table-buckets --region us-east-1
  ```
  `UnknownOperation` on the second means S3 Tables is not in that region.

### ⚠ VPC quota — raise this BEFORE the course, it takes hours to approve

The default limit is **5 VPCs per region per account**. Each learner's
FoundationStack creates one. **Eight learners in one account fail on the
sixth deploy** with `The maximum number of VPCs has been reached`, roughly
four minutes in, leaving a ROLLBACK_COMPLETE stack to delete by hand.

Either:

- **Raise the quota** — Service Quotas → Amazon VPC → "VPCs per Region" →
  request 15. Approval is usually fast but is not instant. Do it today.
- **Or give each learner their own AWS account.** No quota problem, and
  `s3tablescatalog` then has to be created once per account (the bootstrap
  script does it automatically either way).

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

## 4. Deploy — pick your slug first

**Choose a `user` slug and use the same one for every command in this file.**
2–12 characters, lowercase letters and digits, starts with a letter.
Examples: `suren`, `priya`, `amit2`.

This slug goes into every resource name that must be unique. The app refuses
to synthesize without it:

```
ERROR: -c user=<yourname> is required.
```

That guard is deliberate. Without it, the second person to deploy into a
shared account collides on the bucket names, the three IAM role names, the
KMS alias, the Glue database, the S3 Tables bucket and the cluster
identifier — and fails *midway*, not at the start.

```bash
cd ../infra
export CDK_DEFAULT_REGION=us-east-1
export USER_SLUG=suren                  # <-- yours

cdk bootstrap                           # once per account+region, ever
cdk synth -c user=$USER_SLUG            # sanity check: 3 templates, exit 0
cdk deploy --all -c user=$USER_SLUG --require-approval never
```

Everything you own is then named `nbs-<slug>-*`:

| Resource | Name |
|---|---|
| Stacks | `nbs-suren-foundation-dev`, `-lakehouse-`, `-redshift-` |
| Buckets | `nbs-suren-raw-<account>` + `-curated` + `-scripts` |
| Cluster | `nbs-suren-dev` |
| S3 Tables bucket | `nbs-suren-tables-dev` |
| Glue database | `nbs_suren_raw_dev` |
| Glue jobs | `nbs-suren-raw-to-bronze-dev`, `nbs-suren-bronze-to-silver-dev` |
| IAM roles | `nbs-suren-glue-dev`, `nbs-suren-rs-spectrum-dev`, `nbs-suren-rs-s3tables-dev` |
| Resource link | `nbs_suren_s3t_link` |

Cluster creation takes **10–15 minutes**. Then:

```bash
aws cloudformation describe-stacks --stack-name nbs-$USER_SLUG-redshift-dev \
  --query 'Stacks[0].Outputs' --output table
```

---

## 5. Wire S3 Tables to Redshift

This replaces what used to be two manual console steps. It is **three**
prerequisites, not two, and the third (Lake Formation) was previously
undocumented — it is the one that makes `sql/03` return an empty table list
with no error at all.

```bash
cd ..
chmod +x scripts/*.sh

./scripts/bootstrap_s3tables.sh --user $USER_SLUG --region us-east-1
```

It is idempotent, and it does:

1. **Creates the `s3tablescatalog` federated catalog** — once per account +
   region. If a colleague already ran it, this is a no-op. Waits for your
   table bucket to mount as a child catalog.
2. **Creates your Glue resource link** (`nbs_<slug>_s3t_link`) — per learner.
   Redshift cannot point an external schema at a federated catalog path; it
   can only point at a resource link that targets one.
3. **Grants Lake Formation permissions** to your `nbs-<slug>-rs-s3tables-dev`
   role at all three levels — resource link, target database, and tables.
4. **Verifies all of it**, and names the fix for anything that failed.

Re-check at any time without changing anything:

```bash
./scripts/bootstrap_s3tables.sh --user $USER_SLUG --verify
```

If it reports `no Lake Formation grants`, you are not a data lake admin.
Lake Formation console → Administrative roles and tasks → add yourself, then:

```bash
./scripts/bootstrap_s3tables.sh --user $USER_SLUG --grants-only
```

---

## 6. Run the pipeline, then resolve the SQL

```bash
aws glue start-job-run --job-name nbs-$USER_SLUG-raw-to-bronze-dev
# wait for SUCCEEDED before starting the next
aws glue get-job-run --job-name nbs-$USER_SLUG-raw-to-bronze-dev --run-id <id> \
  --query 'JobRun.JobRunState'

aws glue start-job-run --job-name nbs-$USER_SLUG-bronze-to-silver-dev
```

Then substitute your own ARNs and bucket names into the SQL:

```bash
./scripts/render_sql.sh --user $USER_SLUG --region us-east-1
```

**Learners use `sql/_resolved/`, not `sql/`.** The script exits non-zero if
any placeholder it should have substituted is still there, so a silent
half-render cannot reach the room. Two placeholders are left on purpose:
`<QUERY_ID>` and `<YOUR_IAM_ROLE_NAME>`.

### `scripts/create_learners.sh` — not needed in this model

That script creates eight logins on **one shared cluster**. Since each
learner now deploys their own cluster and is its `nbsadmin`, it is unused.
Keep it only if you later consolidate onto a shared cluster.

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
| `03` | §5 bootstrap completed |
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

**`sql/03` §3.3 needs an IAM login, not a database login.** The auto-mounted
`awsdatacatalog` requires Federated Access to Spectrum. In Query Editor v2
choose *Temporary credentials using your IAM identity*, not *Database user
name and password*. Connected as `nbsadmin`, `awsdatacatalog` looks empty and
reads like a broken permission. It is not — it is the wrong login type.

---

## 8. What is most likely to bite

Ranked by likelihood, each with the actual fix:

1. **CDK CLI too old** → schema 54.0.0 mismatch at `cdk synth`.
   `npm install -g aws-cdk@latest`. See §1.
2. **VPC quota** → sixth learner's deploy fails four minutes in. See §1.
3. **Not a Lake Formation admin** → bootstrap reports grant failures,
   `sql/03` returns an empty table list with no error. See §5.
4. **`sql/03` §3.3 connected as a database user** → empty `awsdatacatalog`.
   Reconnect with your IAM identity. See §7.
5. **Glue job Iceberg config.** The `--conf` string in `lakehouse_stack.py`
   wires the Iceberg REST catalog. On `NoSuchCatalog`, check `warehouse` and
   `uri` against `aws s3tables list-table-buckets`.
6. **RLS in `sql/09`** needs the right cluster version and `sys:secadmin`.
   If it errors, skip §9.4 — nothing downstream depends on it.
7. **`ANALYZE COMPRESSION` on an empty staging copy** (`sql/12` §12.4)
   returns nothing useful. Widen the date window.
8. **`stl_load_commits` empty** in `sql/16` if no COPY ran in that session.
   Run the `sql/02` COPY first.

---

## 9. Cost — this is 8× what it used to be

Per learner, roughly:

| Item | Rate | 8-hour day |
|---|---|---|
| `ra3.large` × 1 node | ~$0.25/hr | ~$2.00 |
| Glue + KMS interface endpoints (2 AZ each) | ~$0.04/hr | ~$0.96 |
| Glue jobs, S3, S3 Tables | negligible at this volume | <$0.10 |

**Eight learners, five 8-hour days, paused overnight: roughly $100–130.**

Confirm `ra3.large` against current pricing for your region — it is the one
number here not verified against a published table.

### Two things that bill while you sleep

**Pause the cluster every evening.** A paused cluster bills storage only:

```bash
aws redshift pause-cluster  --cluster-identifier nbs-$USER_SLUG-dev
aws redshift resume-cluster --cluster-identifier nbs-$USER_SLUG-dev
```

Resume takes a few minutes — start it before the room arrives.

**Interface endpoints do NOT stop when the cluster pauses.** The Glue and KMS
endpoints bill ~$0.04/hr per learner continuously — about $27 across eight
learners for a week of wall-clock time. That is the price of not running a
NAT gateway (which would be ~$32/month *each*). Accept it, or `cdk destroy`
nightly rather than pausing.

---

## 10. Teardown

Each learner tears down their own:

```bash
cd infra
cdk destroy --all -c user=$USER_SLUG
```

Buckets auto-delete in `dev`, so the destroy will not hang on non-empty
buckets. Three things `cdk destroy` will **not** remove:

```bash
# 1. Your Glue resource link
aws glue delete-database --name nbs_${USER_SLUG}_s3t_link --region us-east-1

# 2. S3 Tables namespace/tables, if the table bucket refuses to delete
aws s3tables list-tables --table-bucket-arn <TableBucketArn>

# 3. The shared s3tablescatalog — LEAVE IT unless you are the last one out.
#    Deleting it breaks every other learner in the account.
#    aws glue delete-catalog --catalog-id s3tablescatalog
```

---

## 11. Handing it to the room

Give each learner:

1. Their own AWS credentials, with the permissions in §1.
2. **Their own `user` slug**, assigned by you so no two clash.
3. This file, and [CURRICULUM.md](CURRICULUM.md) — the five-day plan.

Do centrally, before day one:

- Raise the VPC quota (§1) — this is the one that cannot be fixed on the day.
- Confirm every learner is a Lake Formation data lake admin (§1).
- Have one person deploy end-to-end and run `sql/01` through `sql/04`.

The one instruction worth repeating on day one: **run the files in order,
and read the comments.** The comments carry the teaching; the SQL is just
what makes it measurable.
