# Phase → Source-Code → Terraform Traceability Map

> **What this is:** a phase-by-phase index of *which application code* and *which Terraform (IaC)* implement each stage of the SAP → Lakehouse pipeline. Use it to jump from "Phase B CDC" straight to the connector code **and** the infra that runs it.
> **Branch:** `develop` @ `991646c` · **Companion:** [LEARNING-glue-ingestion-and-abap-to-glue.md](LEARNING-glue-ingestion-and-abap-to-glue.md) (the deep walkthrough).
> **Legend:** SRC = `src/…` application code (+ `src/glue/specs/…` YAML config, `config/…`). TF = `infra/…` HCL Terraform. Paths are repo-relative; env TF shown for `dev` (qa/prod mirror it).

---

## 1. Pipeline phases (the data path)

| Phase | Source code (`src/…`, specs, config) | Terraform (`infra/…`) |
|---|---|---|
| **Phase A — Full Load** (P1 download → RAW; initial + full-only masters) | `src/glue/glue_engine/jobs/source_download.py` · `sources/sap_hana.py` (JDBC) · `sources/rds_jdbc.py` · `driver_select.py` · `writers/raw_landing.py` · `src/glue/specs/download/*.yaml` | `env/dev/source_download.tf` · `env/dev/sap_hana_source_download.tf` · `env/dev/per_source_ingestion.tf` · `env/dev/glue_sources.tf` · `modules/glue-job/` · `modules/step-function/` · `modules/glue-connection/` · `modules/s3-data-lake/` |
| **Phase B — CDC / Incremental** (P1 delta + P2 Bronze upsert) | `jobs/source_download.py` (incremental) · `jobs/bronze_pull.py` · `sources/sap_hana.py` (JDBC-CDC) · `sources/sap_odata.py` (ODP) · `sources/protocol.py` · `sources/landed_files.py` · `writers/s3_tables.py` (`merge_into`) · `spec.py` (`merge_key`) · `src/glue/specs/bronze/*.yaml` · `config/ingestion_tables.yaml` (`driver_by_mode`) | `env/dev/per_source_ingestion.tf` · `env/dev/source_download.tf` · `env/dev/download_barrier.tf` (P1→P2 gate) · `env/dev/glue_sources.tf` · `modules/glue-job/` · `modules/glue-connection/` (SAP OData) · `modules/control_plane/` (watermarks/runs DDB) |
| **Bronze → Silver conform** (P2b: cleanse/standardise base tables) | `jobs/bronze_to_silver.py` · `transforms/*.py` · `src/glue/specs/silver/*.yaml` | `env/dev/silver_conform.tf` · `env/dev/silver_barrier.tf` · `env/dev/glue_sources.tf` · `modules/glue-job/` |
| **Phase 3 — ABAP → Glue Transform** (Silver *derived* tables; the 9 rebuilds) | `jobs/abap_transform.py` · `abap/ops.py` · `abap/baskets.py` · `abap/helpers.py` · `src/glue/specs/transform/*.yaml` | `env/dev/transform_ingestion.tf` (transform SFN + Glue job) · `env/dev/transform_barrier.tf` · `env/dev/glue_sources.tf` · `modules/glue-job/` · `modules/step-function/` |
| **Dimensions** (conformed dims + Excel upload) | `jobs/dim_sync.py` · `src/lambdas/dim_excel_ingest/handler.py` · `src/lambdas/dim_history/handler.py` · `src/glue/specs/bronze/dim_*.yaml` | `modules/customer_dims/` · `modules/dim_upload/` · `env/dev/main.tf` (module wiring) |
| **Silver → Gold** (dbt on Redshift) | `src/dbt/**` — `models/marts/{gold,reporting,dims}/`, `models/staging/`, `macros/`, `tests/`, `dbt_project.yml`, `sources.yml` · `jobs/_scripts/run_dbt.py` (runner) | `modules/dbt_silver_to_gold/` · `env/dev/gold_barrier.tf` · `modules/redshift-serverless/` |
| **Serving / BI / Governance** (Redshift Spectrum + reporting views + PBI DirectQuery) | `src/dbt/models/marts/reporting/vw_*.sql` · `mv_*.sql` | `modules/redshift-serverless/` · `modules/catalog_federation/` (`s3tablescatalog`) · `modules/lake-formation/` |

---

## 2. Cross-cutting layers (run across all phases)

| Layer | Source code (`src/…`) | Terraform (`infra/…`) |
|---|---|---|
| **Platform / Foundation** (network, crypto, storage, identity, audit) | — *(no application code)* | `modules/vpc/` · `modules/kms/` · `modules/iam/` · `modules/s3/` · `modules/s3-data-lake/` · `modules/secrets/` · `modules/ssm/` · `modules/cloudtrail/` · `modules/vpc-peering/` · `modules/tgw-route/` · `env/dev/main.tf` |
| **Orchestration / Dispatch** (cycle kickoff, per-source SFN fan-out) | `src/lambdas/dispatcher/handler.py` · `src/shared/control_plane/**` (models) | `modules/dispatcher_lambda/{lambda.tf,eventbridge.tf,iam.tf,locals.tf}` · `modules/control_plane/` · `env/dev/per_source_ingestion.tf` |
| **Phase gating** (barriers between P1→P2→conform→transform→gold) | `src/lambdas/download_barrier/handler.py` · `silver_barrier/handler.py` · `transform_barrier/handler.py` · `gold_barrier/handler.py` · `src/shared/control_plane/coordination.py` (single-flight locks) | `env/dev/download_barrier.tf` · `env/dev/silver_barrier.tf` · `env/dev/transform_barrier.tf` · `env/dev/gold_barrier.tf` · `modules/lambda/` |
| **Observability / Safety nets** (cycle sweeper, run status, token age, alerts, budgets) | `src/lambdas/cycle_sweeper/handler.py` · `src/lambdas/run_status/handler.py` · `src/lambdas/token_age/handler.py` · `src/reconciliation/reconciliation/harness.py` | `env/dev/cycle_sweeper.tf` · `env/dev/run_status.tf` · `env/dev/token_age.tf` · `modules/sns/` · `modules/sqs/` (DLQ) · `modules/budgets/` |
| **CI/CD** (build, package, deploy) | `pyproject.toml` · wheel packaging | `bitbucket-pipelines.yml` (repo root) · `global/oidc/` (deploy roles) · `global/tf_state_bootstrap/` (state) · `infra/Makefile` |

---

## 3. How the phases chain (execution order)

```
EventBridge cron
  └─▶ dispatcher (Lambda)                         [Orchestration]
        └─▶ per-source Step Function
              ├─ Phase A/B: source_download (P1)  → RAW      [glue-job]
              │     └─ download_barrier            (P1→P2 gate)
              ├─ P2: bronze_pull (merge upsert)   → BRONZE   [glue-job]
              │     └─ silver_barrier
              ├─ conform: bronze_to_silver        → SILVER   [glue-job]
              ├─ Phase 3: abap_transform          → SILVER (derived) [transform SFN]
              │     └─ transform_barrier
              └─ gold_barrier
                    └─ dbt (run_dbt)              → GOLD + reporting [dbt_silver_to_gold → Redshift]
  cycle_sweeper / run_status / token_age          [safety nets, every cycle]
```

**Quick rules of thumb**
- Every **Glue job** (`source_download`, `bronze_pull`, `bronze_to_silver`, `abap_transform`, `dim_sync`) is defined via `modules/glue-job/` and instantiated in `env/dev/glue_sources.tf`.
- Every **Step Function** (per-source ingestion SFN, transform SFN) uses `modules/step-function/`; the SAP connection uses `modules/glue-connection/`.
- Every **barrier / dispatch / safety-net Lambda** is `src/lambdas/<name>/handler.py` ↔ `env/dev/<name>.tf` (same base name — the fastest way to jump code↔infra).
- **Watermarks, runs, cycle state** (the control plane the barriers read) = `src/shared/control_plane/**` ↔ `modules/control_plane/` (DynamoDB).
