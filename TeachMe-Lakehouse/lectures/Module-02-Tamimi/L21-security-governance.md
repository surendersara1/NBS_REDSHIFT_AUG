# L21 · Least Privilege, For Real

**Slide:** [`_render/L21-security-governance.html`](_render/L21-security-governance.html)

## The point

This lesson is taught from our own security audit, because the honest version teaches better than the tidy one. Two HIGH findings, the code as it was, the code as it is now:

- **HIGH-06** — the Glue execution role carried the AWS-managed `AmazonS3FullAccess` plus `s3tables:*` and `glue:*` on `Resource: "*"`. Every Glue job could read or delete **any object in the account**, including the Terraform state bucket and the 7-year Object-Lock CloudTrail bucket.
- **HIGH-07** — all six KMS CMKs granted 13–15 AWS service principals `Encrypt/Decrypt/ReEncrypt*/GenerateDataKey*/DescribeKey` on `Resource: "*"` **with no `Condition`**. That is the textbook cross-service confused deputy: any resource in any account that can induce one of those services to call KMS could use our keys.

Both are fixed. Neither fix is "add a policy" — both are diffs you can read.

## Key ideas

- **What "scoped" means.** After HIGH-06 the Glue role's raw S3 access is three named buckets (`-landing-`, `-raw-`, `-artifacts-`, each `${resource_prefix}-…-${account_id}`); `s3tables:Get*/Put*/List*` is bounded to `arn:aws:s3tables:<region>:<account>:bucket/*`; the Glue catalog actions are bounded to `database/${resource_prefix}_*`, `table/${resource_prefix}_*/*` and `job/${resource_prefix}-*`. Every one of the five workload roles also carries a `permissions_boundary`.
- **What "scoped" does *not* mean.** Some AWS actions accept no resource ARN and legitimately stay on `"*"`: `lakeformation:GetDataAccess` (with an in-code comment saying exactly that), `ec2:Describe*`, `glue:GetCatalog`-style catalog reads. Least privilege is not "zero stars" — it is "every star is deliberate and commented". When you review IAM here, your job is to check that each `"*"` has a reason next to it.
- **The confused-deputy fix is one `Condition`.** `aws:SourceAccount = <this account>` on the `AllowAwsServiceUse` statement. The CloudWatch Logs statement immediately below had always been correctly scoped by encryption context (`ArnLike` on `kms:EncryptionContext:aws:logs:arn`) — the audit's remediation was literally "copy the pattern that is already in this file".
- **Six CMKs, one per layer** — `bronze`, `silver`, `redshift`, `secrets`, `audit`, `lambda` — in each of Dev, QA and Prod. The point of six keys is that a compromise of one does not decrypt the others. **Open gap:** the module ships `var.service_principals_by_layer` to narrow each key's trusted-service list (redshift key → `redshift.amazonaws.com` only, audit key → CloudTrail/SNS/SQS), but **no environment passes it**, so all six still share the 15-principal default. The confused-deputy hole is closed; the six-key separation is not yet honoured.
- **Lake Formation is the door, not IAM.** LF runs in **strict mode**: `create_database_default_permissions = []` and `create_table_default_permissions = []`, i.e. the `IAMAllowedPrincipals` fallback is off and the default permission on anything new is NONE. IAM alone opens nothing. Access comes from explicit `aws_lakeformation_permissions` grants, codified in Terraform so all three envs stay reproducible.
- **The two principals that actually hold grants.** The Glue role gets `CREATE_TABLE / ALTER / DROP / DESCRIBE` on the `bronze_<env>` and `silver_<env>` mirror databases plus `ALL` on their tables (wildcard) — it deletes and recreates the mirror table on every write. The Redshift role gets `DESCRIBE` on the silver mirror DB and `SELECT / DESCRIBE` on its tables, which is what lets Spectrum read `silver_external.<table>` from dbt.
- **LF-TBAC** — the tag vocabulary exists as three LF tag keys with fixed value sets: `layer` (bronze/silver/gold), `sensitivity` (public/internal/confidential/pii), `domain` (sap/ncr/ecommerce/shared). Today the grants in `lf_grants.tf` are **resource-scoped, not tag-scoped**; the tags are provisioned and ready for tag-based grants as the table count grows. Say that plainly rather than claiming TBAC is in force.
- **Secrets by reference, always.** Terraform creates the secret's *name*, its CMK and its rotation config — never its value. A placeholder version is written once and then pinned with `lifecycle { ignore_changes = [secret_string] }`, so a real credential set out-of-band is never reverted and never enters state. Consumers pass an **ARN**: the SAP Glue connection sets `SECRET_ID = module.secrets.secret_arns["sap-db"]` and Glue resolves username/password at run time. Redshift goes further — `manage_admin_password = true` means AWS owns the admin secret and no password touches Terraform at all.
- **The audit's own headline is worth repeating to the team:** the things the coding team was allowed to touch are done to a high standard. The three that remain (CRIT-01 Prod state isolation, CRIT-02 the `tamimi-lakehouse` vs `tamimi-dlh` slug schism, CRIT-03 the deploy-role privilege-escalation path) all need a human decision, not a commit.

## Words you'll hear

| Word | What it means here |
|---|---|
| Confused deputy | Service A is tricked into using your key on someone else's behalf |
| `aws:SourceAccount` | Condition key that pins a service-principal grant to one account |
| CMK | Customer-managed KMS key — one per layer, six per environment |
| Permissions boundary | A ceiling policy; the role can never exceed it, whatever is attached |
| LF strict mode | Default catalog permission is NONE; `IAMAllowedPrincipals` disabled |
| LF-TBAC | Tag-based access control — grant on `sensitivity=pii`, not on table names |
| Mirror database | `bronze_<env>` / `silver_<env>` in the default Glue catalog, for Spectrum |
| Secret by reference | Code holds the ARN; the value is fetched at run time and never stored |

## In this repo

- [`infra/modules/iam/main.tf:58-62`](../../../tamimi-lakehouse/infra/modules/iam/main.tf) — the HIGH-06 comment recording that `AmazonS3FullAccess` was removed and why the managed `AmazonS3TablesFullAccess` covers the Iceberg writer's data plane; `:64-79` the narrowed `s3tables` statement; `:80-100` the narrowed `glue` statement; `:101-105` the `lakeformation:GetDataAccess` `"*"` with its justification; `:106-116` the scoped bucket access; `:13-20` the bucket-ARN derivation; `:39` the `permissions_boundary`.
- [`infra/modules/iam/main.tf:309-317`](../../../tamimi-lakehouse/infra/modules/iam/main.tf) — the Redshift role comment: Spectrum uses `s3tables:GetTableData`, "so we do NOT need `s3:*` on this role". Two different doors into the same bytes (see M1 L13).
- [`infra/modules/kms/main.tf:74-82`](../../../tamimi-lakehouse/infra/modules/kms/main.tf) — the HIGH-07 `Condition` with the AWS least-privilege doc link; `:5-31` the shared 15-principal default list; `:33-35` the per-layer lookup; `:85-104` the CloudWatch Logs statement that was already correct.
- [`infra/modules/kms/variables.tf:22-31`](../../../tamimi-lakehouse/infra/modules/kms/variables.tf) — `service_principals_by_layer`, with a worked example in the comment. Grep the env roots: nothing passes it.
- [`infra/modules/lake-formation/main.tf:25-44`](../../../tamimi-lakehouse/infra/modules/lake-formation/main.tf) — strict mode, and the `aws_iam_session_context` trick that resolves the assumed-role session back to its role ARN so the Bitbucket OIDC identity counts as a data-lake admin; `:71-80` the LF tags; `variables.tf:22-30` the tag vocabulary.
- [`infra/modules/catalog_federation/lf_grants.tf:28-91`](../../../tamimi-lakehouse/infra/modules/catalog_federation/lf_grants.tf) — the six grants, with a header explaining that under strict mode the writer's `glue:CreateTable` and Spectrum's read both fail without them.
- [`infra/modules/secrets/main.tf:7-31`](../../../tamimi-lakehouse/infra/modules/secrets/main.tf) — metadata-only ownership and `ignore_changes`; [`infra/env/dev/main.tf:84-102`](../../../tamimi-lakehouse/infra/env/dev/main.tf) — the five secret names and the comment forbidding table/schema names in secrets.
- [`infra/env/dev/sap_hana_source_download.tf:75-95`](../../../tamimi-lakehouse/infra/env/dev/sap_hana_source_download.tf) — `SECRET_ID` wired from the module output, "keeps creds out of Terraform state".
- [`docs/handoff/audit_deep_analysis.md:183-195`](../../../tamimi-lakehouse/docs/handoff/audit_deep_analysis.md) — HIGH-06 and HIGH-07 in full; [`docs/handoff/audit-remediation-verification.md:40-41`](../../../tamimi-lakehouse/docs/handoff/audit-remediation-verification.md) — the verified-fixed evidence.

## Do this

1. `git log -p -- infra/modules/kms/main.tf` and find the commit that adds the `Condition` block. That four-line diff is the whole HIGH-07 fix. Read it, then write down in one sentence what an attacker could have done before it.
2. In `infra/modules/iam/main.tf`, list every statement whose `resources` is `["*"]`. For each, decide from the comment whether it is deliberate. If a comment is missing, that is your review finding.
3. Set `service_principals_by_layer = { redshift = ["redshift.amazonaws.com"] }` on the Dev `module "kms"` block and run `terraform plan`. Read which key policies change and predict what would break if you narrowed the `audit` key the same way (hint: CloudWatch alarms publishing to a CMK-encrypted SNS topic).
4. Try to find a credential value in the repo or in state. You should fail — and be able to say exactly which two mechanisms guarantee that (`ignore_changes` on the placeholder, and `manage_admin_password` for Redshift).

## You've got it when you can…

…take a reviewer through both diffs from memory — **`AmazonS3FullAccess` → three named buckets**, and **service-principal grant → the same grant plus `aws:SourceAccount`** — say which `"*"`s are legitimate and why, explain that Lake Formation strict mode means IAM alone opens nothing, and name the one governance gap still open (the six CMKs still share one 15-service principal list).
