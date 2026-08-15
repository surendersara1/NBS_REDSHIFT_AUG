# Plan — Operational & Monitoring Dashboard (Go-Live)

> **Goal:** an enterprise, **read-only** operations console where Tamimi/NBS ops staff log in and see, at a glance: today's daily runs, per-job run-time / status, the workflow pipeline (what ran, when, how long, how many rows), data freshness/SLA, reconciliation/DQ, alarms — **and traceability across every service** (source → Bronze → Silver → Gold → report).
> **Go-live:** ~10 days. **Region:** eu-west-1. **Branch:** `develop` @ current HEAD.
> **Acceptance anchor:** the client **UAT Criteria** doc, **§8.2 Pipeline Monitoring & Alerting** (there is no separate "SOW" file; the UAT criteria are the acceptance contract — see §1).

> ### ✅ Decisions locked (2026-07-24)
> - **Tier-2 tech:** **Amazon Managed Grafana** for go-live over the existing control-plane data; a **custom read-only Next.js console = V2 fast-follow**.
> - **Auth intent:** **Cognito** (native, read-only ops group) for a fast go-live; Azure-AD/Entra SAML deferred to V2.
> - ⚠️ **Auth nuance to resolve day 1:** *Amazon Managed Grafana does not authenticate via Cognito* — it supports **AWS IAM Identity Center (SSO)** or **SAML** only. So: for the **Grafana** go-live, authenticate the workspace via **IAM Identity Center** (fastest; grant ops the built-in **Viewer** role = read-only). Keep **Cognito** for the **V2 custom console's** read-API. If a single Cognito login across both is a hard requirement now, that argues for bringing the custom console forward (Option B) — flag at kickoff. **Default: IAM Identity Center for Grafana now, Cognito for the V2 console.**

---

## 1. Scope anchor — what the client signed up for

No standalone `SOW.*` exists; the acceptance contract is **`Analyze_status/8_15_2026/nd-TML _ Data Lakehouse - UAT Criteria….pdf`**. The monitoring line items:

| UAT ref | Requirement (verbatim intent) | Expected result |
|---|---|---|
| **§8.2** | CloudWatch alarms for **all** ingestion pipelines (Glue jobs, Lambda triggers) | — |
| §8.2 | Alert + email/SNS **within 15 min** of any pipeline failure | notification received |
| §8.2 | Alert if **daily data/partition missing by 07:00 KSA** | freshness alert fires |
| §8.2 | **CloudWatch dashboard shows pipeline run history for last 7 days** | dashboard visible |
| §8.2 | **Runbook** documented for common failures | runbook available |
| §8.1 | Daily **row-count reconciliation** + duplicate-key detection (Bronze/Silver) | recon job + zero-dup |

**Design decision already locked:** [`ADR-0015`](../design-reference/decisions/0015-monitoring-cloudwatch-vs-grafana.md) chose **Amazon CloudWatch (native)**; Grafana explicitly named as the "V2 layer if dashboard UX becomes a friction point," and Datadog "out of SOW."

> **Reading:** the *contractual* bar (§8.2) is a **CloudWatch dashboard + alarms + SNS + runbook**. What the user is describing (login, per-service ecosystem, charts, traceability) is a **richer enterprise layer on top**. We deliver both, in two tiers.

## 2. Current state — the data is already there, the UI is not

The hard part (capturing run history, lineage, live state) is **done**. The control plane already models everything a console needs:

| Data source (exists today) | What it gives the dashboard |
|---|---|
| **`runs` DDB** ([`runs.py`](../../src/shared/shared/control_plane/runs.py)) — per-stage run history, 90-day TTL. Fields: `stage` (source_download/bronze_pull/abap_transform/bronze_to_silver/silver_to_gold), `status`, `started_at`/`ended_at`, `rows_in`/`rows_out`, `error_message`, `cycle_id`, `source_id`, `job_name`, `attempt`, `run_kind`, `backfill_*`. GSIs: **by_table**, **by_cycle**. | *Daily runs · run-time (ended−started) · status · rows · retries · what ran when* |
| **`pipeline-state` DDB** ([`pipeline_state.py`](../../src/shared/shared/control_plane/pipeline_state.py)) — **built for the operator UI** ("polls every 10s"); polymorphic: `pipeline` (running/queued/idle/failed + age), `alarm` (severity/message/ack), `freshness` (last_success/expected_within/is_fresh), `reconciliation` (gold_table/drift_pct/passed). | *Live tiles: running pipelines · open alarms · freshness · recon* |
| **`lineage_edges` DDB** ([`lineage_edges.py`](../../src/shared/shared/control_plane/lineage_edges.py)) — DAG edges source→bronze→silver→gold→view + `transform_id` (dbt/Glue/Lambda). | ***Traceability*** *— the pipeline graph + drill from a node back to its code* |
| `watermarks` DDB · `source_catalog` · `bronze_mapping` | *CDC position per table · source inventory · routing* |
| **CloudWatch** metrics/logs — every Glue job, Step Function, and Lambda already emits. | *Native run status, duration, errors, log drill-down* |
| **Reconciliation harness** ([`src/reconciliation/`](../../src/reconciliation/)) → writes `reconciliation` state. | *Row-count/DQ pass-fail (UAT §8.1)* |
| SNS topics · `run_status` / `token_age` / `cycle_sweeper` Lambdas | *Alert routing · run capture · SLA/token safety nets* |

**Not built yet:** (a) the CloudWatch dashboard-as-code module, (b) the operator web console. The design anticipated a **Next.js operator UI + Cognito** (referenced in the earlier design as "Phase 8"), but it is not in the current tree.

## 3. The plan — two tiers

### Tier 1 — UAT-minimum (contractual): CloudWatch dashboard + alarms  ·  ~2–3 days
Satisfies §8.2 exactly, aligns with ADR-0015, lowest risk. Build a new TF module **`infra/modules/monitoring-cw-dashboards/`** with dashboards-as-code JSON (per ADR-0015's stated follow-on) + alarms.

- **Dashboard widgets** (last 7 days): Glue job run status & duration per job; Step Function execution success/fail; Lambda errors/throttles; a **run-history table** (from CloudWatch Logs Insights or a DDB-backed widget over `runs`); freshness-per-source; daily cycle timeline.
- **Alarms** → existing SNS (email within 15 min): any Glue job `FAILED`; SFN execution failed; barrier Lambda error; **freshness alarm** — a scheduled check that fires if a source's `runs`/`pipeline-state` shows no success by **07:00 KSA** (the `token_age`/`cycle_sweeper` pattern already exists to build on).
- **Runbook:** extend the existing [`docs/OPERATIONS-RUNBOOK.md`](../OPERATIONS-RUNBOOK.md) + [`RUNBOOK-test-pipeline-stepfunctions.md`](RUNBOOK-test-pipeline-stepfunctions.md) with the common-failure recovery steps (rerun/backfill via dispatcher).

### Tier 2 — the enterprise ops console (what you're describing): read-only Operator Console  ·  ~5–8 days
A login-gated, read-only web app over the **existing** control-plane data. Two build options — pick per the auth/time trade-off in §5:

**Architecture (both options share the read API):**
```
Ops user ──login──▶ Cognito (read-only "ops-viewer" group)
                        │
                        ▼
                 API Gateway (HTTP API)  ──▶  read-only Lambda(s)
                        │                         │  (query-only; NO run/mutate)
                        ▼                         ▼
                 Web console (SPA)        DynamoDB: runs (by_cycle/by_table GSI),
                                          pipeline-state, lineage_edges, watermarks,
                                          reconciliation   +   CloudWatch GetMetricData
                                          +   Glue/StepFunctions Get*/List* (status)
```

**Screens (map 1:1 to your ask):**
| # | Screen | Powered by | Answers |
|---|---|---|---|
| 1 | **Today's Cycle Overview** — RAG tile per pipeline, overall health | `pipeline-state` + `runs` by_cycle | "what's going on right now" |
| 2 | **Daily Runs / Job History** — table + timeline per table×stage: start, **duration**, status, rows, attempts, error | `runs` (by_table / by_cycle GSI) | "daily runs · run-time · status · what ran when" |
| 3 | **Workflow / Pipeline Graph** — the medallion DAG, live status per node (source→Bronze→Silver→Gold→view) | `lineage_edges` + `runs` | "workflow pipelines · performance" |
| 4 | **Service Ecosystem** — health per service: Glue, Step Functions, Lambda, Redshift, S3 Tables, DDB | CloudWatch + Glue/SFN APIs | "comprehensive ecosystem for every service" |
| 5 | **Data Freshness / SLA** — per-table last-success vs 07:00 KSA target | `freshness` state + `watermarks` | UAT §8.2 freshness |
| 6 | **Reconciliation & DQ** — row-count drift, dup-key, pass/fail | `reconciliation` state + harness | UAT §8.1 |
| 7 | **Alarms Feed** — open alarms, severity, ack status | `alarm` state + CloudWatch | "status · alerts" |
| 8 | **Trends / Charts** — run-duration trend, success-rate %, rows processed, freshness-over-time | `runs` history (90-day) | "stats · charts" |
| 9 | **Traceability drill-down** — pick any table → upstream/downstream lineage → the `transform_id` (dbt model / Glue job / Lambda) that produced it → its runs → its logs | `lineage_edges` + `runs` + CW Logs | "traceability first" |

**Read-only guarantee:** the API Lambda holds only `dynamodb:Query/GetItem`, `cloudwatch:GetMetricData`, `glue:GetJobRun(s)`, `states:DescribeExecution`, `logs:GetLogEvents` — **no** `StartJobRun`/`PutItem`/mutate. Operators observe; they don't run. (Run/rerun stays with engineers via the dispatcher, a later phase.)

## 4. Data-need → existing-source map (grounding, no new capture needed)

| Dashboard need | Existing source | Notes |
|---|---|---|
| what ran, when, status | `runs` (status, started_at, ended_at) | already written by every Glue/Lambda stage |
| run time / duration | `ended_at − started_at` | compute in the read API |
| rows processed | `runs.rows_in/rows_out` | per stage |
| retries / attempts | `runs.attempt`, `run_kind` | rerun/backfill visible |
| daily cycle roll-up | `runs` **by_cycle** GSI | the gold barrier already uses this |
| live "is it running" | `pipeline-state` (pipeline kind) | 10s poll designed-in |
| freshness / 07:00 SLA | `pipeline-state` (freshness) + `watermarks` | |
| recon / DQ | `pipeline-state` (reconciliation) + harness | UAT §8.1 |
| pipeline graph + code trace | `lineage_edges` (+ `transform_id`) | the traceability spine |
| service health / logs | CloudWatch, Glue/SFN Get* APIs | native |

## 5. Recommendation (given 10 days + go-live risk)

1. **Do Tier 1 first (days 1–3).** It *is* the contractual UAT bar (§8.2) and de-risks go-live. Ship the CloudWatch dashboard + alarms + freshness alarm + runbook. If nothing else lands, UAT still passes.
2. **Tier 2 build option — pick one:**
   - **Option A — Amazon Managed Grafana** over CloudWatch + a DDB/Athena data source. *Fastest* rich dashboards, ADR-0015's own named "V2." Login via Grafana/SAML. Less bespoke UX; ~3–4 days for screens 1–8.
   - **Option B — custom read-only Next.js console** (matches the design's planned operator_ui) + API Gateway + Cognito. *Richest, on-brand,* full traceability drill-down (screen 9). ~6–8 days; tighter for 10 days alongside go-live.
   - **Recommendation:** **Tier 1 CloudWatch now + Option A (Managed Grafana) for the enterprise view for go-live**, with **Option B (custom console) as the fast-follow V2** — because a bespoke web app + auth hardening in 10 days *during* go-live is the main schedule risk, and Grafana reaches 80% of the value on the existing data in a fraction of the time. Revisit ADR-0015 with a short addendum recording the Grafana-for-ops decision.

## 6. 10-day delivery sketch

| Day | Work |
|---|---|
| 1 | Confirm decisions (§7); scaffold `infra/modules/monitoring-cw-dashboards/`; enumerate Glue jobs/SFNs/Lambdas + metric names |
| 2–3 | CloudWatch dashboard JSON (7-day run history, per-job status/duration) + alarms + **07:00 KSA freshness alarm** → SNS; extend runbook. **← UAT §8.2 met** |
| 3 | Read-only API: Lambda(s) over `runs`/`pipeline-state`/`lineage_edges` + IAM read-only role + Cognito `ops-viewer` group |
| 4–5 | (Grafana path) data sources + screens 1,2,5,7,8; or (custom path) app shell + screens 1,2 |
| 6–7 | Screens 3 (pipeline graph), 4 (ecosystem), 6 (recon), 9 (traceability drill-down) |
| 8 | Wire freshness/recon widgets to live data; verify against a real daily cycle |
| 9 | Hardening: read-only IAM audit, login test, load a full cycle, UAT dry-run vs §8.1/§8.2 |
| 10 | UAT walkthrough + runbook sign-off; buffer |

## 7. Decisions to confirm before day 1

1. **Auth:** Cognito user pool (native) for a fast go-live, or Azure-AD/Entra SAML (the design's Phase-8 target)? *(Recommend Cognito now, SAML V2.)*
2. **Tier-2 tech:** Managed Grafana (fast) vs custom Next.js console (rich)? *(Recommend Grafana for go-live.)*
3. **Audience/access:** which ops group logs in, and is it strictly read-only for v1? *(Assume yes — "first read only".)*
4. **Scope of "every service":** confirm the ecosystem list = Glue, Step Functions, Lambda, Redshift, S3 Tables, DynamoDB, EventBridge, SNS (+ SAP-connectivity health?).
5. **ADR:** add an ADR-0015 addendum recording "Grafana (or custom console) as the ops-facing layer over CloudWatch" so it's governed.

## 8. Why this is low-risk
The expensive, error-prone part — *capturing* every run's status/duration/rows/lineage — is already implemented and running in the control plane. This plan is a **serving + visualization layer** over data that exists, plus the CloudWatch dashboard ADR-0015 already called for. Nothing here changes the pipeline; it's read-only observability.

---
*Prepared from the UAT Criteria (§8.1/§8.2), ADR-0015, and the live control-plane data model (`runs`, `pipeline-state`, `lineage_edges`).*
