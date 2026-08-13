# Naming decisions, and one correction

## The raw bucket is `nbs-raw-suren`, not `NBS_RAW_SUREN`

The requested name cannot be created. S3 bucket naming rules require:

- lowercase letters, numbers, hyphens, and dots only — **no uppercase**
- **no underscores**
- 3–63 characters
- must begin and end with a letter or number

`NBS_RAW_SUREN` violates two of those rules. CloudFormation rejects it at
create time with `Bucket name should not contain uppercase characters`, so
this is not a style preference — the stack will not deploy.

The kebab-case equivalent is used throughout:

| Purpose | Bucket |
|---|---|
| Raw landing (CSV as received) | `nbs-raw-suren` |
| Curated / UNLOAD target | `nbs-raw-suren-curated` |
| Glue scripts + temp | `nbs-raw-suren-scripts` |
| S3 Tables (Iceberg bronze/silver) | `nbs-coaching-tables-dev` |

Bucket names are globally unique across all AWS accounts. If
`nbs-raw-suren` is already taken, override it at deploy time rather than
editing the stack:

```bash
cdk deploy --all -c raw_bucket=nbs-raw-suren-<account-id>
```

## Why the S3 Tables bucket is named separately

Table buckets are a distinct resource type (`AWS::S3Tables::TableBucket`)
with their own namespace and their own naming rules — 3–63 characters,
lowercase, and **no dots at all**. They do not collide with general-purpose
S3 bucket names, which is why the naming scheme differs.

## Redshift identifiers

Cluster identifiers must be lowercase alphanumeric with hyphens, so
`nbs-coaching-dev`. Database, schema, and table names use `snake_case`
throughout. Redshift folds unquoted identifiers to lowercase, so
`FctCustomerOrders` and `fctcustomerorders` are the same object — camelCase
in DDL is a trap, and the reason every object here is snake_case.
