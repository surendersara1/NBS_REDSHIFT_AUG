# Tamimi Lakehouse — Forensic Architecture & Security Audit

> **Audit mode:** Principal/Distinguished-Engineer cold review (AWS Well-Architected lens)
> **Target:** `E:\NBS_Tamimi_Lakehouse\tamimi-lakehouse`
> **Branch audited:** `develop` (HEAD `bc989a1`) · **Region:** `eu-west-1` · **Account observed:** `633740007496`
> **Corpus:** 830 tracked files — 165 `.tf`, 158 `.py`, 44 `.sql`, 33 `.yaml`, plus dbt/Glue/Lambda/CI.
> **Method:** Direct inspection of the security-critical Terraform + five parallel layer-reader passes (IaC modules, IaC env/global, Lambdas, Glue/dbt, CI-CD/secrets). Every finding carries a real `file:line`. AWS-doc citations verified live against the AWS Documentation MCP server.
> **Verdict up front:** The *building blocks* are frequently competent — CloudTrail, DynamoDB, the state-bootstrap module, OIDC trust scoping, and several app-layer IAM roles are textbook. The *composition* is not. The repository ships **two mutually-incompatible topology models simultaneously** (shared-account vs per-account) under **two project slugs** (`tamimi-lakehouse` vs `tamimi-dlh`), and that schism is the root cause of most CRITICAL findings. Separately, the reporting layer emits **materially wrong numbers** to the executive Power BI dashboards.

---

## I. Executive Architectural Health Score

Scale 1–10, where 10 = AWS Well-Architected reference standard. These are cold scores, not encouragement.

| Pillar | Score | One-line justification |
|---|:--:|---|
| **Security** | **4 / 10** | Strong primitives (OIDC, CloudTrail, CMKs, PAB everywhere, no committed live keys) undermined by a **shared prod/non-prod state bucket**, a **privilege-escalation-capable deploy policy**, a Glue role holding `AmazonS3FullAccess`+`glue:*` on `*`, **unconditioned KMS service-principal grants**, **no VPC Flow Logs**, **TLS-disabled SAP HANA connectivity**, reversible "PII masking", and a **1Password Emergency Kit sitting in the working tree**. |
| **Reliability** | **3 / 10** | Per the project's own `CLAUDE.md`, the branch "will not synth, will not deploy, will not complete one ETL run." Confirmed drivers: **env-less resource names that collide across environments**, the **slug schism orphaning the OIDC + state modules**, **zero logging on every async Lambda** (operators are blind to dispatch/barrier failures), a **non-idempotent Gold barrier**, dbt **fan-out → MERGE runtime failures**, and `dim_sync` **breaking on every re-run**. |
| **Performance** | **4 / 10** | Billion-row SAP/HANA tables read on a **single JDBC partition**, source frames **re-read 3–4×** (no `.cache()`), **no Iceberg compaction/snapshot-expiry anywhere**, whole-workbook-into-memory Excel ingest, and per-row `PutItem`. Offset by genuinely good idempotent-MERGE and `_SUCCESS`-marker discipline. |
| **Cost Efficiency** | **5 / 10** | **No VPC interface endpoints** → all Secrets/KMS/Glue/STS API traffic egresses via NAT (data-processing $), redundant full-table DDB `Scan`s, unbounded snapshot growth, and an `athena-results` bucket for an explicitly out-of-scope service. Offset by PAY_PER_REQUEST DDB, Glacier tiering on the raw zone, and right-sized RPU. |
| **Overall** | **4 / 10** | Competent components, incoherent system. The gap between the two topology models must be closed before anything else is worth fixing. |

**The five things that must be fixed before this goes near production data:**
1. **CRIT-01** — Split the shared Terraform state backend; stop operating dev/qa/prod out of one bucket + one account.
2. **CRIT-02** — Resolve the `tamimi-lakehouse` vs `tamimi-dlh` slug schism and the env-less naming collisions.
3. **CRIT-03** — Remove the IAM privilege-escalation path in the deploy policy and the documented `AdministratorAccess` CI role.
4. **CRIT-04** — Fix the ≈2× sales double-count feeding every Area-Manager / store KPI in Power BI.
5. **CRIT-05** — Purge the 1Password Emergency Kit (and the committed customer architecture PDF) from the working tree/history.

---

## II. Layer-by-Layer Forensic Breakdown

For each layer: **Component/Path → Observed Pattern → The Anti-Pattern / Gap.**

### Layer 1 — Terraform State & Multi-Environment Topology
- **Component:** `infra/env/{dev,qa,prod}/backend.tf`, `global/tf_state_bootstrap/`, `global/oidc/`, `infra/env/README.md`.
- **Observed:** All three env backends point at `bucket = dynamodb_table = "tamimi-lakehouse-tfstate-633740007496"`; only the state `key` differs. A hardened, CMK-encrypted, PITR-enabled state-bootstrap module exists (`global/tf_state_bootstrap/`) but is built for slug `tamimi-dlh-tfstate-<env>-<region>`. `global/oidc` scopes every deploy permission to `tamimi-dlh-*`. The env README documents a *single shared account* and, separately, an `AdministratorAccess` CI role.
- **Anti-Pattern/Gap:** Two topology models coexist. The real infra (`tamimi-lakehouse-*`, one account) is governed by neither the bootstrap module nor the OIDC role that were written for it (`tamimi-dlh-*`). Result: **zero blast-radius isolation between prod and non-prod**, an **orphaned hardened state backend** (the real bucket was created out-of-band via raw CLI with SSE-S3, not the CMK module), and a deploy role that either cannot touch the real resources (AccessDeny everywhere) or — if slug-overridden — can escalate to admin.

### Layer 2 — Identity & Access (IAM / OIDC)
- **Component:** `infra/modules/iam/main.tf`, `global/oidc/permissions.tf`, `global/oidc/main.tf`.
- **Observed:** Per-service roles with `sts:AssumeRole` service-principal trust; the Glue role attaches `AWSGlueServiceRole` + `AmazonS3TablesFullAccess` + **`AmazonS3FullAccess`** and an inline `s3tables:*`,`glue:*` on `*`. The BitBucket OIDC trust is correctly scoped to `{repo_uuid}:<branch>:*` with `aud` pinned. The deploy policy grants `iam:AttachRolePolicy`/`iam:PutRolePolicy`/`iam:UpdateAssumeRolePolicy` on `role/tamimi-dlh-*`.
- **Anti-Pattern/Gap:** OIDC *trust* scoping is good; the *permission* set is not. The deploy role can attach the AWS-managed `AdministratorAccess` to any `tamimi-dlh-*` role (including itself) and `PassRole` it to Lambda → account admin. The Glue *workload* role is effectively data-plane admin (`s3:*` account-wide). No role carries a `permissions_boundary`. No service trust carries an `aws:SourceAccount` confused-deputy guard.

### Layer 3 — Encryption & Secrets (KMS / Secrets Manager / SSM)
- **Component:** `infra/modules/kms/main.tf`, `infra/modules/secrets/`, `infra/modules/ssm/main.tf`, `infra/modules/glue-connection/`.
- **Observed:** One CMK per layer (bronze/silver/redshift/state/artifacts/audit), rotation on by default. Secrets Manager stores metadata-only placeholders (no committed credentials). The KMS key policy grants ~13 AWS service principals `Encrypt/Decrypt/ReEncrypt*/GenerateDataKey*/DescribeKey` on `Resource:"*"`.
- **Anti-Pattern/Gap:** The broad service-principal grant has **no `kms:ViaService` / `aws:SourceAccount` / `aws:SourceArn` condition** — a textbook cross-service confused-deputy exposure. Secrets have **no rotation** configured. The `ssm` module is `String`-only (no `SecureString`), and `glue-connection` accepts inline `USERNAME`/`PASSWORD` that would land **in plaintext Terraform state**. All six buckets are encrypted with the single *audit* CMK — key separation collapses to one key.

### Layer 4 — Network (VPC)
- **Component:** `infra/modules/vpc/main.tf`, `infra/env/*/main.tf` (Glue SGs), `infra/modules/redshift-serverless/main.tf`.
- **Observed:** Three-tier subnets (public/private/data), NAT (per-AZ in prod), one **S3 gateway endpoint**, and a comment claiming "keep S3 / Glue / Secrets Manager traffic on AWS backbone."
- **Anti-Pattern/Gap:** **No VPC Flow Logs anywhere in the repo** (verified: zero `aws_flow_log` resources). The comment is false — **only** the S3 gateway endpoint exists; Glue/Secrets/KMS/STS/Logs/SQS traffic egresses over NAT to public endpoints (security + NAT cost). Redshift Serverless has **no `enhanced_vpc_routing`**. TGW static routes cover the entire `172.16/12` + `192.168/16` RFC1918 space, not just the SAP subnet.

### Layer 5 — Storage (S3 / S3 Tables / Lifecycle)
- **Component:** `infra/modules/s3/main.tf`, `infra/modules/cloudtrail/main.tf`, `infra/modules/s3-data-lake/`.
- **Observed:** Every bucket has Public Access Block (all four), SSE-KMS, `BucketOwnerEnforced`, versioning on the stateful ones, and lifecycle rules; the audit + CloudTrail buckets use Object-Lock COMPLIANCE at 7 years.
- **Anti-Pattern/Gap:** **No bucket policy enforcing `aws:SecureTransport`** on the platform buckets, **no server access logging**, and the "deletion protection" is only a `force_destroy` toggle — **no `lifecycle { prevent_destroy = true }`** exists anywhere in the tree (verified). A `terraform destroy` still deletes the audit/artifacts/raw/state buckets and the CMKs.

### Layer 6 — Compute: Event Lambdas
- **Component:** `src/lambdas/{dispatcher,cycle_sweeper,download_barrier,silver_barrier,gold_barrier,transform_barrier,run_status,token_age,dim_excel_ingest,dim_history}/`.
- **Observed:** A single-flight barrier design using DynamoDB conditional writes (`attribute_not_exists`) — genuinely prevents double-Gold-build and cycle resurrection. But **no logging** — no `logger`, no `print`, no Powertools — in any async handler.
- **Anti-Pattern/Gap:** Because these run async (EventBridge/SFN-Event/S3), **AWS discards their return values**, so every `failures[]`, `start_failures[]`, swallowed validation error, and lock outcome is **invisible in CloudWatch**. Compounded by boto3 clients built per-invocation with no retry/timeout `Config`, string-lexical "latest run wins" ordering, a non-idempotent `glue.start_job_run` (double Gold build on post-submit timeout), and whole-workbook-into-memory Excel ingest despite a comment claiming it streams.

### Layer 7 — Compute: Glue / PySpark Engine
- **Component:** `src/glue/glue_engine/{sources,transforms,writers,jobs,abap}/`.
- **Observed:** A spec-driven engine (one wheel + N YAMLs) with strong JDBC-injection defenses (regex-validated identifiers, explicit column lists), MANDT productive-client filtering, and idempotent delete-aware Iceberg MERGE.
- **Anti-Pattern/Gap:** The giant SAP tables (ZHOCIDC 1.38B, S603 649M, S611 638M rows) can be read on a **single JDBC partition** (`partition_column` optional for `sap_hana`, mandatory for `rds_jdbc`), source frames are **re-read 3–4×** with no `.cache()`, and there is **no compaction/snapshot-expiry job at all**. `dim_sync` uses a `DROP` path that S3 Tables rejects (breaks on re-run). Customer mobile numbers are "masked" with **reversible Base64**, and the HANA password is materialized as a plaintext Spark JDBC option.

### Layer 8 — Transform: dbt (Silver → Gold → Reporting)
- **Component:** `src/dbt/models/marts/{gold,reporting}/`, `src/dbt/macros/`, `src/dbt/tests/`.
- **Observed:** `merge` incrementals with `unique_key`, `on_schema_change`, late-binding views, `store_failures`, `NULLIF` on every division.
- **Anti-Pattern/Gap:** **`unified_sales_by_am`, `vw_store_performance_bands`, and `vw_am_kam` sum over `unified_sales` without excluding the synthetic `'All Dept'` rows** — which are themselves the sum of the per-dept legs — so every Area-Manager and store KPI is **≈2× actual**. Fan-out on unenforced merge keys will raise "multiple matches to update the same tuple" at MERGE time. The 14-day incremental predicate **silently drops restatements older than 14 days**. There is **no composite-key uniqueness test** on any Gold fact — the one guard that would catch the fan-out before it errors.

### Layer 9 — Orchestration & Observability
- **Component:** `infra/modules/step-function/`, `infra/modules/eventbridge/`, `infra/env/*/*.tf` alarms, prod `terraform.tfvars`.
- **Observed:** Step Functions + EventBridge cron; CloudWatch alarms and a budget module exist.
- **Anti-Pattern/Gap:** Prod `alert_email_addresses = []` — **budget, cost-anomaly, and ops alarms fire into the void**. The Step Functions log group has **no `kms_key_id`** while logging execution data at `ALL`. Prod is **missing pipeline files** (`silver_barrier.tf`, `download_barrier.tf`, `token_age.tf`, etc.) that dev/qa have — a monitoring/coverage gap.

### Layer 10 — CI/CD & Supply Chain
- **Component:** `bitbucket-pipelines.yml`, `infra/Makefile`, `scripts/`, `discovery_scripts/`.
- **Observed:** OIDC-based, zero static AWS keys (a unit test asserts this), a manual gate on Prod deploy, and state encryption + DDB locking configured.
- **Anti-Pattern/Gap:** The Prod manual gate **reviews `plan A` but auto-applies a freshly recomputed `plan B`** (separate ephemeral containers; the `-out` plan file is never passed to the apply). QA `release/*` **auto-applies with no gate** — in the shared Prod account. `make tf-apply env=prod` **auto-approves**. Tools (`uv`, Terraform, AWS CLI) and the runtime `ngdbc.jar` JDBC driver are fetched via `curl | sh` / unpinned URLs with no checksum, and Lambda-layer deps are resolved unlocked at deploy time — a clean artifact-poisoning path into the Prod runtime.

### Layer 11 — Repository Hygiene
- **Component:** repo root, `docs/`.
- **Observed:** `1Password Emergency Kit A3-LN2VLF-northbaysolutions.pdf` present in the working tree (untracked); `docs/TAM-TAMIMI … Architecture & Technical Design ….pdf` **committed**; committed Glue `stderr`/`stdout` dumps, `bash.exe.stackdump`, and scratch JSON at root.
- **Anti-Pattern/Gap:** A 1Password Emergency Kit contains the account **Secret Key** and is one `git add -A` from entering history. The committed CI/Glue dumps leak account IDs (`633740007496`, `114602914991`, `100565136225`), internal S3 Tables ARNs, the managed-warehouse bucket id, and a Spark driver IP.

---

## III. Categorized Deep-Dive Findings Matrix

**Severity index (most severe first).** Full 6-field schema entries for CRITICAL/HIGH below; MEDIUM/LOW are consolidated in per-layer tables afterward (each still carrying location + fix) to keep the document actionable.

| ID | Sev | Category | Finding | Primary location |
|---|---|---|---|---|
| CRIT-01 | CRITICAL | Best-Practice / Security | dev/qa/prod share one state bucket + lock table | `infra/env/*/backend.tf` |
| CRIT-02 | CRITICAL | Operational Fragility | `tamimi-lakehouse` vs `tamimi-dlh` slug schism + env-less name collisions | `global/oidc/variables.tf:55`, `infra/env/*/**` |
| CRIT-03 | CRITICAL | Security Vulnerability | Deploy-role IAM privilege escalation + documented `AdministratorAccess` CI role | `global/oidc/permissions.tf:234-281`, `infra/env/README.md:86-100` |
| CRIT-04 | CRITICAL | Operational Fragility (data correctness) | ≈2× sales double-count into AM/store/KAM KPIs | `src/dbt/models/marts/gold/unified_sales_by_am.sql:34-63` |
| CRIT-05 | CRITICAL | Security Vulnerability | 1Password Emergency Kit in working tree; customer arch PDF committed | repo root; `docs/…pdf` |
| HIGH-06 | HIGH | Security Vulnerability | Glue role: `AmazonS3FullAccess` + `glue:*`/`s3tables:*` on `*` | `infra/modules/iam/main.tf:46-60` |
| HIGH-07 | HIGH | Security Vulnerability | KMS key policy: 13 service principals, `Resource:"*"`, no condition | `infra/modules/kms/main.tf:21-55` |
| HIGH-08 | HIGH | Security Vulnerability | No VPC Flow Logs anywhere | `infra/modules/vpc/main.tf` |
| HIGH-09 | HIGH | Security Vulnerability | SAP HANA connectivity TLS-disabled (code default + dev/qa tfvars) | `scripts/sap_hana_to_s3.py:118-119`; `infra/env/dev/sap_hana_source_download.tf:90` |
| HIGH-10 | HIGH | Operational Fragility | Zero logging on all async Lambdas → failures invisible | `src/lambdas/*/handler.py` |
| HIGH-11 | HIGH | Security Vulnerability | Prod plan≠apply gate; QA auto-apply; Makefile auto-approve prod | `bitbucket-pipelines.yml:405/479`, `:264-283`; `infra/Makefile:47-53` |
| HIGH-12 | HIGH | Best-Practice Violation | No provider version pinning in any module | `infra/modules/**` |
| HIGH-13 | HIGH | Performance Bottleneck | Whole-workbook-in-memory + per-row PutItem in Excel ingest | `src/lambdas/dim_excel_ingest/handler.py:171-281` |
| HIGH-14 | HIGH | Performance Bottleneck | Single-partition billion-row JDBC read + uncached 3–4× re-read | `src/glue/glue_engine/sources/sap_hana.py:222-248,513-515` |
| HIGH-15 | HIGH | Operational Fragility | Non-idempotent Gold barrier → double Gold build | `src/lambdas/gold_barrier/handler.py:155-165` |
| HIGH-16 | HIGH | Operational Fragility | dbt fan-out → MERGE "multiple matches" runtime failure | `src/dbt/models/marts/gold/unified_sales.sql:156-210` |
| HIGH-17 | HIGH | Operational Fragility | Illusory deletion protection (no `prevent_destroy` anywhere) | `infra/modules/{s3,kms}/*` |
| HIGH-18 | HIGH | Security Vulnerability | Supply-chain: `curl\|sh`, unpinned tools + `ngdbc.jar` + unlocked Lambda deps | `bitbucket-pipelines.yml:55,165,186,467` |
| HIGH-19 | HIGH | Security Vulnerability | TGW routes entire RFC1918 space to on-prem | `infra/env/dev/terraform.tfvars:45-50` |

---

### CRIT-01 — Shared Terraform state bucket + lock across all environments
- **Category:** AWS Best Practice Violation / Security Vulnerability
- **Severity:** CRITICAL
- **Location:** `infra/env/dev/backend.tf:11-14`, `infra/env/qa/backend.tf:3-6`, `infra/env/prod/backend.tf:3-6` — all three: `bucket = "tamimi-lakehouse-tfstate-633740007496"`, `dynamodb_table = "tamimi-lakehouse-tfstate-633740007496"`; only `key` differs.
- **Justification & Impact:** dev/qa/prod state lives in one bucket, one lock table, one account. A compromised, buggy, or malicious **dev** apply (which runs unattended per HIGH-11) has full `s3:GetObject`/`s3:PutObject`/`s3:DeleteObject` on **prod** state. Corrupting or deleting `tamimi-lakehouse/prod/terraform.tfstate` detaches Terraform from every live prod resource; a subsequent apply proposes to recreate the entire prod estate (Redshift, S3 Tables, KMS). The DDB lock name equal to the bucket name (`infra/env/*/backend.tf`) is a further copy-paste smell (expected a `-lock` suffix). This is the single largest blast-radius defect in the repo.
- **Proof / AWS evidence:** AWS prescriptive guidance — separate environments into separate accounts (Organizations multi-account strategy) and isolate Terraform state per environment. AWS IAM least-privilege / blast-radius guidance: https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html . Well-Architected Security Pillar SEC01 (separate workloads using accounts).
- **Exact Remediation Blueprint:**
  1. Decide the target topology (see CRIT-02). If staying single-account short-term, at minimum create **three separate state buckets** (`…-tfstate-{dev,qa,prod}-eu-west-1`) and **three lock tables** with a `-lock` suffix, each CMK-encrypted, via the existing `global/tf_state_bootstrap` module — not raw CLI.
  2. Give each env's CI role `s3:*Object` on **only its own** state prefix/bucket and `dynamodb:*Item` on **only its own** lock table.
  3. Migrate state: `terraform init -migrate-state -backend-config=…` per env, verify `terraform plan` is a no-op post-migration, then delete the shared keys.
  4. Target end-state: dev/qa/prod in **separate AWS accounts** under one Organization; prod CI credentials must not exist in the dev account.

### CRIT-02 — Project-slug + topology schism (`tamimi-lakehouse` vs `tamimi-dlh`), env-less names collide
- **Category:** Operational Fragility
- **Severity:** CRITICAL
- **Location:** `global/oidc/variables.tf:52-56` (`project_slug` default `"tamimi-dlh"`, never overridden by `global/oidc/env/dev/terraform.tfvars.example`); `global/tf_state_bootstrap/main.tf:102,149` (`tamimi-dlh-tfstate-*`); vs `infra/env/*/backend.tf` + `infra/env/*/*.tf` using `tamimi-lakehouse-*` and `resource_prefix = var.project` **without `-<env>`** (e.g. `infra/env/{dev,qa,prod}/gold_barrier.tf:32`, `token_age.tf:37`, `silver_barrier.tf:31`, `cycle_sweeper.tf:29`, and ~30 more).
- **Justification & Impact:** Two irreconcilable models are wired in at once. (a) The hardened, CMK/PITR state-bootstrap module builds `tamimi-dlh-tfstate-*` — which **no env backend references** — so it is dead code and the real state bucket was created out-of-band with weaker SSE-S3. (b) The OIDC deploy role scopes every ARN to `tamimi-dlh-*`, but the real resources are `tamimi-lakehouse-*`; as shipped, the CI role **cannot manage the real infra or reach the real state bucket** → AccessDenied across the board. (c) Resource names omit `-<env>`, so in the shared account the second environment's apply either errors on name-in-use or adopts/overwrites the first environment's IAM roles, Glue jobs, SFNs, and alarms. This is why the branch "will not deploy."
- **Proof / AWS evidence:** IAM identifiers and resource-name uniqueness are per-account global for IAM/S3; AWS naming + tagging best practices (Well-Architected OPS). https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html
- **Exact Remediation Blueprint:**
  1. Pick **one** slug (recommend `tamimi-lakehouse` to match live resources) and set it explicitly in every `global/oidc/env/*/terraform.tfvars` and the bootstrap tfvars; delete the divergent default.
  2. Introduce `-<env>` into `resource_prefix` (`local.name_prefix = "${var.project}-${var.environment}"`) and thread it through every module call in `infra/env/*`.
  3. Re-point `infra/env/*/backend.tf` at the bootstrap-module-managed buckets; import or recreate so IaC owns the backend.
  4. Reconcile `infra/env/README.md` (shared-account) against the app-layer file comments (per-account) — one documented source of truth.

### CRIT-03 — Deploy-role IAM privilege escalation + documented AdministratorAccess CI role
- **Category:** Security Vulnerability
- **Severity:** CRITICAL (HIGH if the OIDC stack is confirmed un-deployed due to CRIT-02)
- **Location:** `global/oidc/permissions.tf:234-241` (`iam:AttachRolePolicy`,`iam:PutRolePolicy`,`iam:UpdateAssumeRolePolicy` on `role/tamimi-dlh-*`), `:266-281` (`iam:PassRole` → lambda/glue/states), `:105-122` (`kms:PutKeyPolicy`,`kms:ScheduleKeyDeletion` on `Resource:"*"`), `:435-449` (`lakeformation:PutDataLakeSettings` on `*`); and `infra/env/README.md:86-100` documenting a single shared OIDC role with `AdministratorAccess`.
- **Justification & Impact:** The deploy role can attach the AWS-managed `arn:aws:iam::aws:policy/AdministratorAccess` to **any `tamimi-dlh-*` role, including the deploy role itself** (its own name matches the glob), or create a new role and `PassRole` it to Lambda → **full account admin from a CI token**. There is no `permissions_boundary` gating this. Independently, `PutKeyPolicy`/`ScheduleKeyDeletion` on `*` lets the role rewrite or delete the **state CMK** (lockout/data-destruction), and `PutDataLakeSettings` on `*` lets it self-grant Lake-Formation data-lake-admin. The README's "greenfield AdministratorAccess" role, if real, is that exposure without even needing the escalation.
- **Proof / AWS evidence:** IAM privilege-escalation via `AttachRolePolicy`/`PassRole` is a documented anti-pattern; grant least privilege and use permissions boundaries — https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html . `AmazonS3FullAccess`/managed-policy over-grant guidance — https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-iam-awsmanpol.html
- **Exact Remediation Blueprint:**
  1. Attach a **permissions boundary** to the deploy role that denies `iam:*` except on a narrow allow-list, and **deny attaching AWS-managed policies** (condition `iam:PolicyARN` `StringNotLike` `arn:aws:iam::aws:policy/*` on `AttachRolePolicy`).
  2. Constrain `PassRole` with `iam:PassedToService` (already present) **and** a resource list of the specific workload roles, not the `*-*` glob.
  3. Scope KMS `PutKeyPolicy`/`ScheduleKeyDeletion` to project key ARNs (tag-condition `aws:ResourceTag/project`), never `Resource:"*"`.
  4. Delete/replace the `AdministratorAccess` CI role in `infra/env/README.md`; the only sanctioned CI identity is the scoped OIDC deploy role.

### CRIT-04 — dbt reporting double-counts sales ≈2× into every AM / store / KAM KPI
- **Category:** Operational Fragility (data correctness) — highest *business* impact
- **Severity:** CRITICAL
- **Location:** `src/dbt/models/marts/gold/unified_sales_by_am.sql:34-63` (`am_rollup` sums `sale`/`cc` over `unified_sales` with **no `dept != 'All Dept'` filter**); propagated by `src/dbt/models/marts/reporting/vw_store_performance_bands.sql:31-41` and `vw_am_kam.sql:30-32,63`. The synthetic All-Dept rows are defined at `unified_sales.sql:135-181`.
- **Justification & Impact:** `unified_sales` deliberately carries **both** the per-department legs **and** a synthetic `'All Dept'` row per (site, date) equal to the SUM of that day's per-dept sales (the ADR-approved "Option A" shape). Any downstream aggregate that sums across the dept axis without excluding `'All Dept'` therefore counts every sale twice. `sale_total`, `cc_total`, `achievement_pct_site`, the performance-band buckets, and the Positive/Negative flags are all ≈2×. These feed the executive Power BI dashboards via `reporting.vw_*` — leadership is looking at doubled revenue by Area Manager and store. This is silent: no error, just wrong numbers.
- **Proof / AWS evidence:** N/A (application data-modeling defect). Guard is standard dbt testing — `dbt_utils.unique_combination_of_columns` / relationship tests.
- **Exact Remediation Blueprint:**
  1. Add `WHERE dept != 'All Dept'` (or `WHERE aagm != '__ALL__'`, matching the sentinel used in `unified_sales.sql`) to `am_rollup` in `unified_sales_by_am.sql` and to the site rollup in `vw_store_performance_bands.sql`.
  2. Re-validate `vw_am_kam` against a hand-computed control total for one AM/one day before/after.
  3. Add a `dbt` singular test asserting `SUM(all-dept legs) == SUM(per-dept legs)` per (site, date) so the invariant is enforced, not assumed.
  4. Backfill: after the fix, `--full-refresh` the affected gold facts and reporting views.

### CRIT-05 — 1Password Emergency Kit in working tree; customer architecture PDF committed
- **Category:** Security Vulnerability (secret/data exposure)
- **Severity:** CRITICAL
- **Location:** `1Password Emergency Kit A3-LN2VLF-northbaysolutions.pdf` (repo root, currently untracked); `docs/TAM-TAMIMI _ Phase 1 Extension 2 _ Architecture & Technical Design-040626-105250.pdf` (committed, tracked).
- **Justification & Impact:** A 1Password Emergency Kit embeds the account **Secret Key** (and the sign-in QR). It sits in the repo directory and is **one `git add -A` away** from entering history and being pushed to BitBucket/GitHub mirrors — at which point the NorthBay 1Password account is compromised and the kit must be rotated org-wide. The `.gitignore` ignores `*.pbix/*.xlsx/*.docx` but **not `*.pdf`**, so the customer's confidential architecture/technical-design PDF is already committed against the stated "customer-confidential artefacts" intent.
- **Proof / AWS evidence:** N/A (repo hygiene / secret management). Aligns with Well-Architected Security SEC02 (protect secrets) and secret-scanning guidance.
- **Exact Remediation Blueprint:**
  1. **Move the 1Password Emergency Kit out of the repo tree immediately** (to secure offline storage); if it was ever committed on any branch, treat the account Secret Key as exposed and re-provision the kit.
  2. `git rm --cached "docs/TAM-TAMIMI … .pdf"`; if the repo is shared/mirrored, scrub it from history (`git filter-repo`) and force-update mirrors.
  3. Add `*.pdf` and `*Emergency Kit*` to `.gitignore`; add a `pre-commit` secret-scan hook (gitleaks/trufflehog) so kits/keys can't be committed.

---

### HIGH-06 — Glue workload role holds account-wide S3 + Glue admin
- **Category:** Security Vulnerability · **Severity:** HIGH
- **Location:** `infra/modules/iam/main.tf:46-49` (`AmazonS3FullAccess`), `:51-60` (inline `s3tables:*`,`glue:*`,`lakeformation:GetDataAccess` on `resources=["*"]`).
- **Justification & Impact:** The Glue job role gets `s3:*` on **every bucket in the account** — including the shared tfstate bucket, the CloudTrail/audit Object-Lock bucket, and landing/raw. A bug or a hostile YAML spec running in Glue can read/exfiltrate or delete any object account-wide. `glue:*` on `*` additionally lets the job create/modify/delete any Glue job or catalog object (lateral movement). The code comment justifies S3 access for the S3 Tables managed bucket, but the managed-bucket requirement does **not** justify `s3:*` on `*`.
- **Proof / AWS evidence:** https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-iam-awsmanpol.html (AmazonS3FullAccess scope); https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html (grant least privilege). S3 Tables + Glue prerequisites: https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-integrating-glue.html
- **Exact Remediation Blueprint:** Replace `AmazonS3FullAccess` with an inline policy granting `s3:GetObject`/`s3:PutObject`/`s3:ListBucket` scoped to the S3 Tables managed-bucket ARN pattern for the project + the specific landing/raw/artifacts buckets. Replace `s3tables:*`/`glue:*` on `*` with the specific `s3tables:Get*/Put*/List*/*TableData` and `glue:Get*/*Job*` actions on project-prefixed ARNs. Add a `permissions_boundary`.

### HIGH-07 — KMS key policy grants 13 service principals broad crypto on `Resource:"*"` with no condition
- **Category:** Security Vulnerability · **Severity:** HIGH
- **Location:** `infra/modules/kms/main.tf:21-55` (`AllowAwsServiceUse` — `s3/glue/redshift/lambda/states/events/scheduler/sns/sqs/airflow/secretsmanager/cloudtrail/maintenance.s3tables/lakeformation` → `Encrypt/Decrypt/ReEncrypt*/GenerateDataKey*/DescribeKey` on `Resource:"*"`, no `Condition`).
- **Justification & Impact:** Service-principal grants with no `kms:ViaService` / `aws:SourceAccount` / `aws:SourceArn` are the canonical cross-service **confused-deputy** exposure: any resource in any account that can induce one of these services to call KMS may use these CMKs. It also collapses the six-CMK separation design — every key trusts every service. (The CloudWatch-Logs statement directly below, `:60-76`, is correctly scoped by encryption-context `ArnLike` — copy that pattern.)
- **Proof / AWS evidence:** https://docs.aws.amazon.com/kms/latest/developerguide/least-privilege.html — "Using `aws:SourceArn` or `aws:SourceAccount` condition keys" for service-principal KMS grants (confused-deputy prevention).
- **Exact Remediation Blueprint:** Add `Condition = { StringEquals = { "aws:SourceAccount" = <account_id> } }` (and `aws:SourceArn`/`kms:ViaService` where the service supports it) to the `AllowAwsServiceUse` statement. Narrow each CMK's principal list to the services that actually use *that* layer (bronze key: glue/s3/lambda; redshift key: redshift; audit key: cloudtrail/sns/sqs) instead of the shared 13-principal block.

### HIGH-08 — No VPC Flow Logs anywhere
- **Category:** Security Vulnerability · **Severity:** HIGH
- **Location:** `infra/modules/vpc/main.tf` (entire module — zero `aws_flow_log` resources; verified repo-wide).
- **Justification & Impact:** A data-lake VPC processing SAP ERP + customer PII has **no network-traffic record**. Exfiltration, lateral movement, and misconfigured egress are undetectable and un-forensicable after the fact. Fails CIS AWS Foundations 3.9 and the Well-Architected network-monitoring baseline.
- **Proof / AWS evidence:** https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-best-practices.html (Security best practices for your VPC — enable flow logs). AWS Config rule `vpc-flow-logs-enabled`.
- **Exact Remediation Blueprint:** Add `aws_flow_log` at VPC scope (`traffic_type = "ALL"`) delivering to a CMK-encrypted CloudWatch Log group or an S3 flow-logs bucket with lifecycle; add the IAM role for CWL delivery. Wire it into the `vpc` module so all three envs get it.

### HIGH-09 — SAP HANA connectivity ships with TLS + cert validation disabled
- **Category:** Security Vulnerability · **Severity:** HIGH
- **Location:** `scripts/sap_hana_to_s3.py:118-119` (`encrypt=_env_bool("SAP_HANA_ENCRYPT", False)`, `sslValidateCertificate=…, False`); `infra/env/dev/sap_hana_source_download.tf:90` + `dev/terraform.tfvars:77-78` (`sap_hana_jdbc_url = "jdbc:sap://<HOST>:<PORT>?encrypt=false"`, `JDBC_ENFORCE_SSL="false"`); `infra/env/qa/sap_hana_source_download.tf:62`.
- **Justification & Impact:** The bulk HANA→S3 extractor **defaults to cleartext, unauthenticated-server** connections, and the Glue JDBC connection is deployed with TLS off. SAP ERP credentials and full table extracts (sales, customer data) traverse the Transit Gateway in plaintext — MITM/eavesdrop on production data in transit. Inconsistent with the sibling `scripts/sample_sap_hana.py:112-115`, which correctly defaults both to `True`.
- **Proof / AWS evidence:** Well-Architected Security SEC09 (protect data in transit). SAP HANA client `encrypt`/`sslValidateCertificate` = TLS.
- **Exact Remediation Blueprint:** Flip both defaults to `True` in `sap_hana_to_s3.py`; set `?encrypt=true&validateCertificate=true` in the JDBC URLs and `JDBC_ENFORCE_SSL="true"`; provision the HANA server cert into the Glue connection truststore. Add a startup assertion that refuses to run if `encrypt` is false against a non-localhost host.

### HIGH-10 — Every async Lambda is unobservable (no logging)
- **Category:** Operational Fragility · **Severity:** HIGH
- **Location:** `src/lambdas/{dispatcher,cycle_sweeper,download_barrier,gold_barrier,transform_barrier,run_status,token_age}/handler.py` (no `logger`/`print`/Powertools anywhere); swallow-and-continue at e.g. `dispatcher/handler.py:80-82,239-240,503-505`; `download_barrier/handler.py:100-104`.
- **Justification & Impact:** These handlers are invoked async (EventBridge/SFN-`Event`/S3), so **AWS discards the return value**. `failures[]`, `gate0_blocked[]`, `start_failures[]`, swallowed malformed-row `except: continue`, and lock-contention outcomes never reach CloudWatch. When (not if) a barrier hangs or a dispatch is dropped, operators have **no signal and no trace** — the pipeline fails silently. This is the biggest reliability gap in the code.
- **Proof / AWS evidence:** AWS Lambda operational best practices — structured logging (Powertools for AWS Lambda). Well-Architected Reliability REL06 (monitor workload).
- **Exact Remediation Blueprint:** Add `aws_lambda_powertools.Logger` at module scope to every handler; log at INFO on entry/exit with a correlation id (cycle_id/run_id) and at ERROR in every `except` before `continue`. Emit an EMF metric or SNS alert on non-empty `failures[]`. Set `AWS_LAMBDA_LOG_LEVEL`/log-format in the Lambda config.

### HIGH-11 — Prod approval reviews a plan that is never applied; QA/Makefile auto-approve
- **Category:** Security Vulnerability / Operational Fragility · **Severity:** HIGH
- **Location:** `bitbucket-pipelines.yml:405` (`plan -out=/tmp/prod.tfplan`) vs `:479` (`apply -auto-approve`, separate container — the plan file is unreachable) and `:435` (`apply -auto-approve -target=module.kms -target=module.s3` with no in-step plan); `:264-283` (QA `release/*` → `apply -auto-approve`, no `trigger: manual`); `infra/Makefile:47-53` (`apply -auto-approve` fallback for any env incl. prod).
- **Justification & Impact:** The human approves `plan A`; the gated deploy computes and auto-approves a **fresh `plan B`** against whatever is in `main`/state at click-time. Drift or a new push between plan and apply changes what actually lands in prod — the manual gate is theater. QA applies with **no gate at all**, inside the shared prod account (CRIT-01). `make tf-apply env=prod` auto-approves locally.
- **Proof / AWS evidence:** Terraform saved-plan workflow (`plan -out` → `apply <planfile>`); AWS deployment-safety / change-management guidance (Well-Architected OPS).
- **Exact Remediation Blueprint:** Persist `plan -out=prod.tfplan` as a **pipeline artifact**, pass it into the gated deploy step, and run `terraform apply prod.tfplan` (no `-auto-approve`, no re-plan). Add `trigger: manual` + `deployment: qa` gating to QA. Make the Makefile `apply` require an explicit typed confirmation and hard-block `env=prod`.

### HIGH-12 — No Terraform provider version pinning in any module
- **Category:** AWS Best Practice Violation · **Severity:** HIGH
- **Location:** `infra/modules/**` — zero `versions.tf`, only 1 stray `required_providers` across 30 modules (verified). Env roots pin `aws ~> 6.28` while `global/oidc` + bootstrap pin `~> 5.0`.
- **Justification & Impact:** Unpinned modules resolve `hashicorp/aws` at each `init`, so plans are non-reproducible and a new provider major (v5→v6 behavioral changes) can silently alter or destroy resources. The two coexisting majors (5.x for state backend, 6.x for workloads sharing that state) invite drift between the layer that manages state and the layers that use it.
- **Proof / AWS evidence:** Terraform provider version-constraint guidance; AWS IaC reproducibility (Well-Architected OPS05).
- **Exact Remediation Blueprint:** Add a `versions.tf` with `required_providers { aws = { source = "hashicorp/aws", version = "~> 6.28" } }` and `required_version = ">= 1.9"` to every module and to `global/*`; unify on one AWS major; commit `.terraform.lock.hcl` per root.

### HIGH-13 — Excel ingest loads whole workbook into memory + per-row PutItem
- **Category:** Performance Bottleneck · **Severity:** HIGH
- **Location:** `src/lambdas/dim_excel_ingest/handler.py:171-173` (`s3.get_object(...)["Body"].read()` then `io.BytesIO`, despite a "Stream download — keeps memory bounded" comment), `:129` (boto3 clients built per S3 record in the loop), `:281` (`ddb.put_item` per row).
- **Justification & Impact:** A large customer dimension workbook is fully materialized in Lambda memory (OOM risk at the 10 GB ceiling, and cost at high memory tiers), and each row is a separate synchronous `PutItem` — thousands of round-trips = latency + throttling. The reassuring comment is actively false.
- **Proof / AWS evidence:** DynamoDB `BatchWriteItem` / `batch_writer` guidance; Lambda memory/streaming best practices.
- **Exact Remediation Blueprint:** Hoist boto3 clients to module scope; use `openpyxl read_only=True` iterating row-by-row; write with `table.batch_writer()` (25-item batches); if workbooks are large, offload to a Glue job. Wrap `_process_one` in try/except with logging so a corrupt workbook is a logged failure, not an unlogged crash after partial DDB writes.

### HIGH-14 — Billion-row SAP tables read on a single JDBC partition; source re-read 3–4×
- **Category:** Performance Bottleneck · **Severity:** HIGH
- **Location:** `src/glue/glue_engine/sources/sap_hana.py:222-248` (`partition_column`/`num_partitions` optional; `_read:462-475` issues one unpartitioned `dbtable`), `:513-515` (`df.count()` then `df.agg(max).first()` — two more full passes); `rds_jdbc.py:408-412` (same, no `.cache()`).
- **Justification & Impact:** For ZHOCIDC (1.38B), S603 (649M), S611 (638M) rows, an unpartitioned JDBC read runs on a single executor — the connector's own docstring calls this "fatal for the giants" (driver/executor OOM or multi-hour timeout). With no `.cache()`, the `count → agg(max) → write` sequence re-executes the entire JDBC pull 3–4×: 3–4× the SAP load, 3–4× the cost, and non-determinism if the source moves between passes. `rds_jdbc` correctly *requires* a hash partition; `sap_hana` does not.
- **Proof / AWS evidence:** AWS Glue Spark JDBC partitioning (`partitionColumn`/`lowerBound`/`upperBound`/`numPartitions`); Spark caching for multi-action DAGs.
- **Exact Remediation Blueprint:** Make `partition_column` + bounds **mandatory** for `sap_hana` above a row-count threshold (mirror `rds_jdbc.py:164-172`). `.cache()`/`.persist(DISK)` the source frame before the `count`/`agg`/`write` sequence, or compute count+max in one `agg`. Set `numPartitions` from DPU capacity.

### HIGH-15 — Non-idempotent Gold barrier can trigger a double Gold build
- **Category:** Operational Fragility · **Severity:** HIGH
- **Location:** `src/lambdas/gold_barrier/handler.py:155-165` (`glue.start_job_run` with no client token; the `except` releases the lock and re-raises), `:166-173` (death between `start_job_run` success and `set_cycle_state("gold_built")` strands the cycle `running` with the lock held).
- **Justification & Impact:** On an ambiguous failure — network timeout **after** Glue accepted the run — the barrier releases the lock and re-raises; the SFN Task retry re-claims the lock and **starts a second Gold build**, double-processing the day (cost + potential duplicate writes if the dbt run isn't fully idempotent). The alternate death-window permanently mislabels cycle state and makes the sweeper do perpetual no-op work until the 90-day TTL.
- **Proof / AWS evidence:** Idempotency for AWS job submission; Step Functions retry semantics (at-least-once Task execution).
- **Exact Remediation Blueprint:** Check for an in-flight/most-recent `JobRun` for the cycle (`glue.get_job_runs` filtered by a cycle argument) before starting; treat "already running for this cycle" as success. Persist `gold_built` **before** returning, or record the started `JobRunId` in the lock item so a retry reconciles instead of re-launching.

### HIGH-16 — dbt fan-out on unenforced merge keys → runtime MERGE failure
- **Category:** Operational Fragility · **Severity:** HIGH
- **Location:** `src/dbt/models/marts/gold/unified_sales.sql:156-158` (join `all_dept_cy` × `stg_sap_zscc`, a pass-through with no GROUP BY — `stg_sap_zscc.sql:14-23`), `:196-210` + `stg_budget_upload.sql:14-24` (budget CTE, no dedup) feeding `unique_key=['site','date','aagm','scenario']`.
- **Justification & Impact:** The "already deduplicated by SAP" assumption is asserted, not enforced. A single duplicate `(site,date)` or budget row fans out to duplicate merge keys, and Redshift MERGE raises `Found multiple matches to update the same tuple` — the entire Gold build fails at run time, with the exact failure depending on upstream data the team doesn't control.
- **Proof / AWS evidence:** Redshift MERGE one-match constraint; dbt incremental `unique_key` uniqueness requirement.
- **Exact Remediation Blueprint:** `GROUP BY`/`QUALIFY row_number()=1` the staging inputs to guarantee one row per merge key; add `dbt_utils.unique_combination_of_columns` tests on each Gold fact's `unique_key` (see HIGH-16 pairs with the missing-test finding) so fan-out is caught in `dbt test` before the MERGE.

### HIGH-17 — "Deletion protection" is illusory (no `prevent_destroy` anywhere)
- **Category:** Operational Fragility · **Severity:** HIGH
- **Location:** `infra/modules/kms/main.tf` + `variables.tf:11-14`, `infra/modules/s3/main.tf:64-75` + `variables.tf:16-20` (descriptions promise `prevent_destroy`); verified repo-wide: `prevent_destroy` appears only in a comment (`redshift-serverless/main.tf:100`) and a variable description (`s3/variables.tf:18`), never as a real `lifecycle` block. `global/tf_state_bootstrap/main.tf:101` also lacks it on the state bucket.
- **Justification & Impact:** Variable descriptions claim deletion protection, but the modules only flip `force_destroy` and the KMS deletion window. A `terraform destroy` (or the Makefile's `tf-destroy`, HIGH-11 sibling) will still delete the audit/CloudTrail Object-Lock buckets, the raw 7-year zone, the CMKs, and the shared state bucket. Operators trusting the description will be surprised at the worst time.
- **Proof / AWS evidence:** Terraform `lifecycle { prevent_destroy = true }`; Well-Architected Reliability (protect stateful resources).
- **Exact Remediation Blueprint:** Add `lifecycle { prevent_destroy = var.deletion_protection }` — note Terraform requires a literal, so gate via a `count`/module split or a hard `prevent_destroy = true` on stateful resources (state bucket, audit/cloudtrail buckets, CMKs, Redshift namespace, control-plane DDB). Add `env=prod` guards to the Makefile destroy target.

### HIGH-18 — Supply-chain: `curl | sh`, unpinned tools + runtime JDBC driver + unlocked Lambda deps
- **Category:** Security Vulnerability · **Severity:** HIGH
- **Location:** `bitbucket-pipelines.yml:55,141,251,293,377,418` (`curl -LsSf https://astral.sh/uv/install.sh | sh`), `:58` (Terraform), `:142-143` (AWS CLI), `:165,315,449` (`ngdbc.jar` fetched then uploaded to the artifacts bucket Glue loads at runtime), `:186,333,467` (`uv pip install pydantic==2.* … boto3 openpyxl` — no lockfile/hashes, Prod included).
- **Justification & Impact:** Deploy steps run privileged (they hold the OIDC deploy token) and pull executables over the network with no checksum/signature. A compromise or MITM of astral.sh, releases.hashicorp.com, or repo1.maven.org injects code into the deploy runner and — via the uploaded `ngdbc.jar` and the unlocked Lambda layer — into the **Prod Lambda/Glue runtime**. Builds are non-reproducible.
- **Proof / AWS evidence:** Software supply-chain integrity (SLSA / AWS artifact-signing guidance); pin + verify dependencies.
- **Exact Remediation Blueprint:** Pin every tool to a version + verify a SHA256 checksum (or use a vetted base image with them preinstalled). Verify `ngdbc.jar` against SAP's published checksum before staging. Resolve Lambda deps from the committed `uv.lock` with `--require-hashes`. Fetch the OIDC token to `/tmp`, not `$(pwd)` (`:124-125`).

### HIGH-19 — Transit Gateway routes the entire RFC1918 space to on-prem
- **Category:** Security Vulnerability · **Severity:** HIGH
- **Location:** `infra/env/dev/terraform.tfvars:45-50` — `routes = [{cidr="172.30.0.0/16"…},{cidr="172.16.0.0/12"…},{cidr="192.168.0.0/16"…}]`.
- **Justification & Impact:** Routing all of `172.16/12` and `192.168/16` to the on-prem TGW gives the lakehouse VPC far broader reachability into corporate/on-prem networks than the single SAP subnet it needs — widening lateral-movement surface in both directions and risking route overlap with the VPC/peers.
- **Proof / AWS evidence:** Least-privilege network routing; https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-best-practices.html
- **Exact Remediation Blueprint:** Replace the broad supernets with the specific SAP HANA host/subnet CIDR(s); pair with security-group and (recommended) NACL scoping so only the Glue connection ENIs reach the SAP endpoint on the SAP port.

---

### MEDIUM findings (consolidated — location + fix)

**IAM / KMS / Secrets**
| ID | Location | Issue | Fix |
|---|---|---|---|
| M-01 | `infra/modules/iam/main.tf:166-171` | SFN `InvokeWorkloads` `glue:StartJobRun`,`lambda:InvokeFunction` on `*` | Scope to `${resource_prefix}-*` ARNs (as sibling SNS/SQS stmt already does) |
| M-02 | `infra/modules/iam/main.tf:186-199` | SFN `logs:PutResourcePolicy`/`CreateLogDelivery` on `*` | Scope to the project log-group ARNs |
| M-03 | `infra/modules/iam` (all roles) | No `permissions_boundary` on glue/lambda/sfn/redshift/mwaa | Attach a project boundary capping privilege |
| M-04 | `infra/modules/kms/main.tf` + `variables.tf` | `deletion_protection` only changes the deletion window, not a real guard | See HIGH-17 |
| M-05 | `infra/modules/secrets/main.tf` | No `aws_secretsmanager_secret_rotation` (SAP creds never rotate) | Configure rotation — https://docs.aws.amazon.com/secretsmanager/latest/userguide/best-practices.html |
| M-06 | `infra/modules/ssm/main.tf:1-11` | `String`-only params (no `SecureString`/KMS) | Support `SecureString` + `key_id` |
| M-07 | `infra/modules/glue-connection/main.tf:22` | Inline JDBC `USERNAME`/`PASSWORD` land in TF state | Force credentials via `secret_arn`; forbid inline |
| M-08 | `src/glue/glue_engine/sources/sap_hana.py:415-460` | HANA password materialized as a Spark JDBC option | Use `useConnectionProperties=true` like `rds_jdbc.py:339-341` |

**Network / Storage / Encryption-at-rest**
| ID | Location | Issue | Fix |
|---|---|---|---|
| M-09 | `infra/modules/vpc/main.tf:150-165` | Only S3 gateway endpoint; no interface endpoints (Secrets/KMS/Glue/STS/Logs/SQS) | Add interface endpoints — security + NAT-cost win |
| M-10 | `infra/modules/redshift-serverless/main.tf:64-97` | No `enhanced_vpc_routing` | Enable it — https://docs.aws.amazon.com/securityhub/latest/userguide/redshiftserverless-controls.html (RedshiftServerless.1) |
| M-11 | `infra/modules/s3/main.tf` | No `aws:SecureTransport` deny; no access logging; all buckets use the *audit* CMK | Add TLS-deny bucket policy (https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingEncryptionInTransit.html), access logging, per-layer CMK |
| M-12 | `infra/modules/glue-job/main.tf:25-69` | Log group has no `kms_key_id`; job has no `security_configuration` | Add CMK + Glue SecurityConfiguration (as `dbt_silver_to_gold` does) |
| M-13 | `infra/modules/step-function/main.tf:10-21` | Log group no `kms_key_id` while `include_execution_data=true` at `ALL` | CMK-encrypt the log group |
| M-14 | `infra/modules/cloudtrail/main.tf:18-32` | Trail bucket policy lacks `aws:SourceArn` + TLS-deny | Add both conditions |
| M-15 | `infra/modules/glue-catalog/main.tf:29-43` | Catalog encryption uses `alias/aws/glue`, not a CMK | Use a project CMK for consistency |

**Compute / Data correctness / Cost**
| ID | Location | Issue | Fix |
|---|---|---|---|
| M-16 | `infra/modules/lambda/main.tf:105-126` | `audit_daily` has no DLQ / no X-Ray / no env-var CMK | Add `dead_letter_config`, `tracing_config`, `kms_key_arn` |
| M-17 | `src/lambdas/dim_excel_ingest/handler.py:200-281` | `KeyError` on `AUDIT_CMK_ARN` after DDB rows written → partial side effect | Validate env at import; wrap `_process_one` |
| M-18 | `src/lambdas/download_barrier/handler.py:223-250` | Partial P2-start failure silently dropped (no unlock/SNS) | Alert + release lock on partial failure |
| M-19 | `src/lambdas/run_status/handler.py:67` | No `source_download` (P1) stage case → crash mislabeled | Add P1/gold stage mapping |
| M-20 | `src/lambdas/transform_barrier/handler.py:135-146` | Deterministic exec name, no `ExecutionAlreadyExists` catch → rerun deadlock | Catch it like `silver_barrier.py:212` |
| M-21 | `src/reconciliation/harness.py:145-197` | Redshift connection never closed → connection leak | `with`/`try-finally` close |
| M-22 | `src/glue/glue_engine/abap/helpers.py:12-21` | Reversible Base64 "masking" of customer mobile (PII) | Use SHA-256 `pii_redact` (`transforms/standard.py:136-154`) |
| M-23 | `src/glue/glue_engine/writers/s3_tables.py` | No `rewrite_data_files`/`expire_snapshots` (small files + metadata bloat) | Add a scheduled compaction/expiry job |
| M-24 | `src/glue/glue_engine/jobs/dim_sync.py:104` → `s3_tables.py:302-327` | `DROP` path S3 Tables rejects → breaks on re-run | Use PURGE/`create_or_replace` supported path |
| M-25 | `src/glue/glue_engine/jobs/_scripts/run_dbt.py:55-65` | `pip install boto3` at job runtime (network/supply-chain hang) | Bake into the image/layer |
| M-26 | `src/dbt/macros/scenario_helpers.sql:48-55` | 14-day incremental predicate drops older restatements | Widen window or add a full-refresh cadence |
| M-27 | `src/dbt/models/marts/gold/_gold.yml` | No composite-key uniqueness test on any Gold fact | Add `dbt_utils.unique_combination_of_columns` on each `unique_key` |
| M-28 | `src/dbt/models/marts/gold/unified_customer_count.sql:63-73` | Type-widening under `on_schema_change='fail'` forces manual `--full-refresh` | Pre-cast to NUMERIC or handle schema change |

**CI/CD / Env / Repo**
| ID | Location | Issue | Fix |
|---|---|---|---|
| M-29 | prod `terraform.tfvars:41` | `alert_email_addresses = []` — alarms fire nowhere | Populate the ops distribution list |
| M-30 | `infra/env/prod/` | Missing `silver_barrier.tf`/`download_barrier.tf`/`token_age.tf` etc. that dev/qa have | Reconcile prod pipeline + monitoring parity |
| M-31 | `infra/env/dev/sap_hana_source_download.tf:44-54` (qa `:26-36`) | Live subnet/SG IDs hardcoded as var defaults | Source from `module.vpc` outputs |
| M-32 | `bitbucket-pipelines.yml:484` (`:262,385`) | `seed_control_plane.py --prune --commit` auto-prunes prod after one gate | Dry-run + diff before prune; separate approval |
| M-33 | `discovery_scripts/sap/connection.py:49-50` | `trust_server_cert` default `yes` (verify=False) to SAP RDS | Default `no`; pin the RDS CA |
| M-34 | root: `b2s-stderr.txt`,`b2s-stdout.txt`,`target.json`,`bash.exe.stackdump`,… | Committed CI/Glue scratch leaks account IDs/ARNs/IPs | `git rm` + gitignore `*.stackdump`/`b2s-*`/scratch |
| M-35 | `scripts/export_redshift_to_excel.py:15` | Hardcoded Redshift endpoint + account ID + dev's Windows path | Parameterize via env |
| M-36 | provider blocks `infra/env/*/providers.tf` | No `allowed_account_ids` guard | Add the account guard (bootstrap/oidc already do) |

### LOW findings (abridged)
- `infra/modules/vpc` — no custom NACLs (default allow-all); `single_nat_gateway` default `true` (AZ SPOF). — Add NACLs; per-AZ NAT for prod (already set).
- `infra/modules/{redshift-serverless,mwaa}/main.tf`, `infra/env/*/main.tf` Glue SG — egress `0.0.0.0/0 -1`. — Scope egress.
- `infra/modules/{sns,sqs}` — no TLS-deny resource policy. — Add `aws:SecureTransport` deny.
- `infra/modules/s3` — `athena-results` bucket for an out-of-scope service. — Remove.
- `infra/modules/mwaa` — DAGs bucket duplicates the `s3` module `mwaa` bucket (state-drift). — De-dup.
- `src/lambdas/*` — string-lexical "latest run wins" ordering (`gold_barrier:94`, etc.); ULID substituted by `uuid4().hex[:26]` (`silver_barrier:199`). — Compare parsed timestamps; use a real ULID.
- `src/lambdas/token_age/handler.py:105-106` — metric chunking by count not 40 KB payload; `Unit="None"` for hours. — Fix chunking/unit.
- `src/dbt/models/staging/stg_sap_distress_603.sql:18` — `LTRIM(dept_code,'0')` key collision; `_staging.yml` missing `not_null` on join keys; `recon_*` invariants at `severity=warn`; `sources.yml` no `freshness`. — Tighten tests.
- `src/glue/glue_engine/sources/sap_odata.py:264` — hardcoded `region_name="eu-west-1"`. — Use session region.
- Multiple f-string SQL/DDL from trusted YAML/vars (`transforms/standard.py:59-61`, `splits.py:83-96`, `writers/s3_tables.py:160-166`, `macros/scenario_helpers.sql:15-25`). — Parameterize/escape even though inputs are Git-controlled.
- `infra/env/*/locals.tf` — only 3 default tags vs the 7-tag standard. — Align to the standard.
- `global/oidc/main.tf:33` — hardcoded BitBucket thumbprint (refresh runbook noted). — Acceptable; document rotation.

---

## IV. What Is Done Well (do not regress these)

The audit is ruthless because the stakes are high, not because the work is uniformly poor. The following are genuinely strong and should be the template for fixing the rest:

- **CloudTrail** (`infra/modules/cloudtrail/`): multi-region, `enable_log_file_validation`, KMS-encrypted, Object-Lock **COMPLIANCE** 7-year bucket, CloudWatch delivery with a scoped role, management + S3 Tables data events. Textbook.
- **`global/tf_state_bootstrap/`**: CMK + rotation, versioning, all-four PAB, noncurrent-version lifecycle, DDB SSE + PITR + deletion-protection, and an account-guard `precondition`. Exactly right — it just isn't wired in (CRIT-02).
- **OIDC trust scoping** (`global/oidc/main.tf:41-58`): `aud` pinned, `sub` bound to `{repo_uuid}:<branch>:*`, `max_session_duration=3600`. The *trust* half is correct.
- **DynamoDB** (control-plane + customer_dims): CMK SSE, PITR, deletion protection, PAY_PER_REQUEST, scoped streams.
- **Single-flight barrier locks** (`coordination.py:365-475`): conditional `PutItem attribute_not_exists` genuinely prevents double-Gold-build and cycle resurrection; barriers resolve latest-status-per-table rather than counting — no double-count race.
- **JDBC injection defense** (`rds_jdbc.py`, `sap_hana.py`): regex-validated identifiers, explicit column lists, watermark-in-projection fail-fast, MANDT productive-client filter, `describe_secret` pre-checks.
- **Idempotent ETL**: delete-aware Iceberg MERGE, in-place `full_refresh` (no DROP), `_SUCCESS`-marker discipline, spec-hash drift guard, Pydantic validation at every boundary; no `eval`/`exec`; strict op allow-list.
- **Secrets hygiene**: no committed live AWS keys (a unit test asserts it — `tests/unit/test_phase7a_deploy_ready.py:203-206`), Secrets-Manager-by-reference only, `.env`/`*.pem`/`*.key`/`*.tfstate`/`*.tfvars`/customer `*.xlsx`/`*.pbix` gitignored, typed `YES IMPORT TO PROD` confirmation on prod dim imports.
- **App-layer IAM** (`dim_upload`, `dispatcher_lambda`, `customer_dims`, `dbt_silver_to_gold`, `token_age`): least-privilege ARN-scoped, CMK env-var encryption, X-Ray, `source_arn`-locked Lambda permissions (confused-deputy prevention). This is the standard the Glue/SFN/deploy roles fail to meet.

---

## V. Remediation Sequencing (hand-off order for the execution session)

Fix in this order — earlier items unblock or dissolve later ones.

1. **Topology first (CRIT-01, CRIT-02, CRIT-03).** Decide single-account-with-isolation vs multi-account; pick one slug; split state buckets/locks; add `-<env>` to names; kill the privesc + AdministratorAccess role. *Most collision/AccessDeny/blast-radius findings collapse out of this.*
2. **Stop the bleeding (CRIT-05, HIGH-09, HIGH-11, HIGH-18).** Purge the 1Password kit + customer PDF; enable TLS on SAP; make prod apply the reviewed plan and gate QA; pin+verify the supply chain.
3. **Correctness (CRIT-04, HIGH-16, M-27).** Fix the ≈2× double-count, dedup the merge inputs, add uniqueness tests. *Numbers in the executive dashboards are wrong until this lands.*
4. **Least privilege + crypto (HIGH-06, HIGH-07, M-01..M-08).** Scope the Glue/SFN roles, condition the KMS grants, add permissions boundaries, rotate secrets.
5. **Observability + reliability (HIGH-08, HIGH-10, HIGH-15, M-16..M-21, M-29).** Flow logs, Lambda logging, idempotent Gold barrier, DLQs, populate alert emails.
6. **Performance + cost (HIGH-13, HIGH-14, M-09, M-10, M-23).** Partition the giants, cache, interface endpoints, enhanced VPC routing, Iceberg compaction.
7. **Hardening tail (HIGH-12, HIGH-17, MEDIUM/LOW remainder).** Pin providers, real `prevent_destroy`, TLS-deny policies, access logging, tag standard.

> **Discrepancy for the execution team to resolve before touching IaC:** the repo asserts *both* "Dev/QA/Prod are separate AWS accounts" (app-layer file comments) *and* "all three share one account/state bucket/OIDC role" (`infra/env/README.md:6`), under *two* project slugs (`tamimi-lakehouse` in `infra/env`, `tamimi-dlh` in `global/`). Every CRITICAL flows from this. Do not begin remediation until an architect ratifies one model in `docs/decision-log.md`.

*End of report.*
