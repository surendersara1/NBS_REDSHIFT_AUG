# Placeholders — the full contract

Every account-specific value in `sql/` is a `<PLACEHOLDER>`. Nothing is
hardcoded. After `cdk deploy`, one command resolves them for your account:

```bash
./scripts/render_sql.sh --user <your-slug> --region <your-region>
```

That reads your CloudFormation stack outputs and writes runnable copies to
`sql/_resolved/`. **Learners run `sql/_resolved/`, never `sql/`.**

---

## Class 1 — resolved automatically from your stack outputs

`render_sql.sh` substitutes all of these. If any survives the render, the
script **exits non-zero** and tells you — a half-rendered SQL set never
reaches a learner silently.

| Placeholder | Source | Example value |
|---|---|---|
| `<ACCOUNT_ID>` / `<ACCT>` | `sts get-caller-identity` | `111122223333` |
| `<REGION>` | `--region` argument | `us-east-1` |
| `<RAW_BUCKET>` | foundation → `RawBucketName` | `nbs-suren-raw-111122223333` |
| `<CURATED_BUCKET>` | foundation → `CuratedBucketName` | `nbs-suren-raw-111122223333-curated` |
| `<GLUE_DB>` | lakehouse → `GlueDatabaseName` | `nbs_suren_raw_dev` |
| `<TABLE_BUCKET_NAME>` | lakehouse → `TableBucketName` | `nbs-suren-tables-dev` |
| `<TABLE_BUCKET_ARN>` | lakehouse → `TableBucketArnOut` | `arn:aws:s3tables:...:bucket/nbs-suren-tables-dev` |
| `<NAMESPACE>` | lakehouse → `NamespaceName` | `coaching` |
| `<RESOURCE_LINK>` | lakehouse → `ResourceLinkName` | `nbs_suren_s3t_link` |
| `<SPECTRUM_ROLE_ARN>` / `<SPECTRUM_ROLE>` | redshift → `SpectrumRoleArn` | `arn:aws:iam::...:role/nbs-suren-rs-spectrum-dev` |
| `<S3TABLES_ROLE_ARN>` | redshift → `S3TablesRoleArn` | `arn:aws:iam::...:role/nbs-suren-rs-s3tables-dev` |
| `<CLUSTER_ID>` | redshift → `ClusterIdentifier` | `nbs-suren-dev` |
| `<MASTER_SECRET_ARN>` | redshift → `MasterSecretArn` | `arn:aws:secretsmanager:...` |

**`<SPECTRUM_ROLE_ARN>` is the general-purpose S3 role.** Every generic
COPY/UNLOAD example across all 76 modules points at it, because it is the one
role this platform creates with S3 read/write plus Glue catalog access. The
original files named six different invented roles (`RedshiftCopyRole`,
`RedshiftUnloadRole`, `RedshiftSpectrumLakehouseRole`, …) that existed in no
account.

---

## Class 2 — infrastructure this platform deliberately does NOT build

These **survive the render on purpose**. `render_sql.sh` lists them and does
not fail, because there is nothing in your stack to resolve them from.

The modules that use them are **concept modules, not runnable labs.** Read
and discuss them; do not expect them to execute.

| Placeholder | Needs | Used by |
|---|---|---|
| `<KINESIS_ROLE_ARN>`, `<KINESIS_STREAM_NAME>` | A Kinesis Data Stream + IAM role | `64` |
| `<MSK_ROLE_ARN>`, `<MSK_CLUSTER_ARN>`, `<MSK_TOPIC_NAME>` | An MSK cluster | `64` |
| `<SAGEMAKER_ROLE_ARN>`, `<ML_S3_BUCKET>` | SageMaker + an ML bucket | `59` |
| `<AURORA_CLUSTER_ARN>`, `<REDSHIFT_NAMESPACE_ARN>` | An Aurora cluster + Redshift Serverless namespace | `69` |
| `<DYNAMODB_TABLE_ARN>`, `<DYNAMODB_ROLE_ARN>` | A DynamoDB table | `69`, `75` |
| `<CONSUMER_NAMESPACE>`, `<CONSUMER_ACCOUNT_ID>`, `<PRODUCER_NAMESPACE>`, `<PRODUCER_ACCOUNT_ID>` | A second Redshift cluster or account | `63` |
| `<SCHEDULER_ROLE_ARN>` | An IAM role for Redshift scheduled actions | `67` |
| `<EMR_ROLE_ARN>`, `<SSH_ROLE_ARN>` | An EMR cluster / SSH host | `75` |
| `<QUERY_ID>` | Whichever query you are investigating | `06`, `74` |
| `<YOUR_IAM_ROLE_NAME>` | Your own IAM role, from `aws sts get-caller-identity` | `03` |

If a learner wants to run one of these for real, they provision the service
themselves and substitute by hand. The placeholder names tell them exactly
what to create.

---

## For an assistant resolving these on a learner's behalf

The reliable path is to run the script rather than hand-edit:

```bash
./scripts/render_sql.sh --user <slug> --region <region>
```

If you must resolve them manually, fetch the values first — do not guess, and
do not reuse another learner's values:

```bash
aws cloudformation describe-stacks --stack-name nbs-<slug>-foundation-<stage> \
  --query 'Stacks[0].Outputs' --output table
aws cloudformation describe-stacks --stack-name nbs-<slug>-lakehouse-<stage> \
  --query 'Stacks[0].Outputs' --output table
aws cloudformation describe-stacks --stack-name nbs-<slug>-redshift-<stage> \
  --query 'Stacks[0].Outputs' --output table
```

Rules:

1. **Substitute into `sql/_resolved/`, never into `sql/`.** `sql/` is the
   template and is committed; `sql/_resolved/` is gitignored because it
   contains a real account id.
2. **Never fill a Class 2 placeholder with a Class 1 value.** Pointing
   `<KINESIS_ROLE_ARN>` at the Spectrum role produces an
   `AccessDenied` that looks like a Redshift bug and is not one.
3. **Every learner has different values.** The slug is in every name.
