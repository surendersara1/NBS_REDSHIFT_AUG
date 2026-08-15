# `ui/` — Lakehouse Operations Console

The **read-only, per-environment** operations & monitoring console for Tamimi ops/IT staff (go-live requirement, UAT **§8.2**). Plan of record: [`docs/handoff/PLAN-ops-monitoring-dashboard.md`](../docs/handoff/PLAN-ops-monitoring-dashboard.md).

## Status

| Step | Artifact | Status |
|---|---|---|
| **1. Look & feel** | [`ops-console-mockup.html`](ops-console-mockup.html) — self-contained, 8 screens, light+dark. **Demo asset.** | ✅ built |
| 2. React SPA | `ui/ops-console/` (Vite + React + TS) | ⏭️ next |
| 3. Read-only API | API Gateway (HTTP) + Lambda over the control plane + Cognito | ⏭️ |
| 4. Hosting | S3 + CloudFront (per env) | ⏭️ |
| 5. CI/CD | build+deploy step per env in `bitbucket-pipelines.yml` | ⏭️ |

Open the mockup by double-clicking it — no build, works offline.

## ⚠️ This console is deployed PER ENVIRONMENT — it is not a global dashboard

The platform ships as three independent deployments (see `bitbucket-pipelines.yml`), so the console does too. **There is no environment switcher** — each instance shows only its own environment, and that is enforced by IAM, not by a UI filter.

| Env | Branch | OIDC role | Gate | Console URL (proposed) |
|---|---|---|---|---|
| **DEV** | `develop` | `AWS_ROLE_DEV_ARN` | auto | `ops-dev.tamimi-lakehouse.internal` |
| **QA** | `release/*` | `AWS_ROLE_QA_ARN` | manual | `ops-qa.tamimi-lakehouse.internal` |
| **PROD** | `main` | `AWS_ROLE_PROD_ARN` | manual approval | `ops.tamimi-lakehouse.internal` |

The mockup renders the **QA** instance. The env is expressed as a coloured top strip + a `Deployment` screen (account, region, build #, commit, deployed-at, approver, pipeline stages). Change `data-env` on `#envstrip` to `dev` / `qa` / `prod` to preview the other environments' colouring — grey/charcoal for Dev, amber for QA, **Tamimi red for Prod**.

## Brand — sourced from tamimimarkets.com

Sampled live from the client's own site so the console reads as Tamimi, not generic AWS:

| Token | Value | Use |
|---|---|---|
| Tamimi red | `#E3000E` | brand mark, active nav, primary accents, Prod env, critical state |
| Charcoal | `#283034` | navigation rail, headings, body text |
| Slate | `#343A40` | secondary chrome |
| Wash / greys | `#F8F9FA` `#757575` | surfaces, muted text |
| Type | **Asap** (headings) · **Cabin** (body) · **IBM Plex Mono** (all data) | matches tamimimarkets.com |

Semantic status colours (success green, warning amber, running blue) are deliberately **separate** from the brand accent so state reads independently of branding. Mono + tabular figures are used for every timestamp, duration and row count.

## The 8 screens

| # | Screen | Purpose | Key content |
|---|---|---|---|
| 1 | **Overview** (landing) | Team-lead executive view | health banner, 8 KPI tiles w/ sparklines, 5-stage pipeline lane w/ per-stage timings, source-system table, needs-attention list, 14-day cycle-duration trend |
| 2 | **Daily Cycle** | What ran when, and how long | **gantt timeline of all 5 stages** (start→end, time spent), 4 barrier gates, per-table step detail w/ queue wait + time spent |
| 3 | **Job Runs** | Full history | 90-day run table: stage · kind · status · started · ended · time spent · rows · attempts · run ID |
| 4 | **Pipeline & Lineage** | Traceability | live medallion DAG w/ node timings + upstream/transform/downstream drill-down |
| 5 | **Service Health** | Every AWS service | Glue, Step Functions, Lambda, Redshift, S3 Tables, DynamoDB, EventBridge, SNS + SAP connectivity (TGW, JDBC, Secrets) |
| 6 | **Data Quality** | UAT §8.1 | Bronze↔SAP row-count reconciliation w/ drift + duplicate keys + dbt test results |
| 7 | **Alarms** | UAT §8.2 | alarm feed w/ full timestamps + open duration, and the configured alarm-rule table |
| 8 | **Deployment** | Env identity | this env, build/release detail, all three environments, and the delivery-pipeline stages |

**Time discipline throughout:** every timestamp is `YYYY-MM-DD HH:MM:SS` in **Asia/Riyadh (+03)**, every step shows **time spent**, and queue wait is separated from execution time.

## Data sources — all already exist (no new capture)

| Screen need | Source |
|---|---|
| runs · status · duration · rows · attempts | DDB `runs` (`by_cycle`/`by_table` GSI) — [`runs.py`](../src/shared/shared/control_plane/runs.py) |
| live tiles (running / alarm / freshness / recon) | DDB `pipeline-state` — [`pipeline_state.py`](../src/shared/shared/control_plane/pipeline_state.py) |
| pipeline graph + traceability | DDB `lineage_edges` (+ `transform_id`) — [`lineage_edges.py`](../src/shared/shared/control_plane/lineage_edges.py) |
| service health / logs | CloudWatch `GetMetricData` + Glue/StepFunctions `Get*`/`Describe*` |
| freshness / CDC position | `pipeline-state` (freshness) + `watermarks` |
| reconciliation / DQ | recon harness → `pipeline-state` (reconciliation); dbt `run_results` |

## Step 2 — React SPA (proposed shape)
```
ui/ops-console/
├── package.json          # vite · react · typescript · recharts · aws-amplify (Cognito)
├── src/
│   ├── theme/tokens.css  # the token block from the mockup, verbatim
│   ├── components/       # StatTile · StatusPill · StageLane · Gantt · RunsTable · Dag · ServiceCard · SevRow · Sparkline
│   ├── screens/          # Overview · Cycle · Runs · Pipeline · Services · DataQuality · Alarms · Deployment
│   ├── api/              # typed read client; 10s poll for live tiles
│   └── config/env.ts     # ENV, account, region injected at build time per environment
```
Every CSS token and block in the mockup maps 1:1 to a component — port `--tokens` into `theme/tokens.css`, then `.card` / `.pill` / `.stat` / `.stg` / `.gantt` / `.node` / `table` into components.

**Fonts:** the mockup links Google Fonts (Asap/Cabin/IBM Plex Mono). For the deployed SPA, **self-host the woff2 files** in the bundle — no external CDN at runtime.

## Step 3 — Read-only API (least privilege)
API Gateway (HTTP) → Lambda with **only** `dynamodb:Query/GetItem` (runs, pipeline-state, lineage_edges, watermarks), `cloudwatch:GetMetricData`, `glue:GetJobRun(s)`, `states:DescribeExecution`, `logs:GetLogEvents`. **No** `StartJobRun` / `PutItem` / mutate — operators observe, never run. Auth: **Cognito** user pool per env, `ops-viewer` group.

New Terraform: `infra/modules/ops-console-api/` + `infra/modules/ops-console-site/`, instantiated **once per env** in `infra/env/{dev,qa,prod}/`.

## Step 5 — CI/CD (into the existing pipeline)
Add one step per environment, mirroring the existing OIDC pattern and gates:
```yaml
- step:
    name: Build & deploy ops-console (QA)
    image: node:20
    caches: [node]
    trigger: manual            # same gate discipline as the QA terraform apply
    deployment: qa
    script:
      - cd ui/ops-console
      - npm ci
      - VITE_ENV=qa VITE_API_BASE="$OPS_API_BASE" npm run build
      - export AWS_ROLE_ARN=$AWS_ROLE_QA_ARN     # reuse the pipeline's OIDC step
      - aws s3 sync dist "s3://${OPS_CONSOLE_BUCKET}" --delete
      - aws cloudfront create-invalidation --distribution-id "${OPS_CONSOLE_CF_ID}" --paths "/*"
```
`OPS_CONSOLE_BUCKET` / `OPS_CONSOLE_CF_ID` / `OPS_API_BASE` come from the `ops-console-site` Terraform outputs **per environment**. Prod keeps its manual-approval gate.

## Order of work
1. Review the mockup (demo). 2. Approve look → port to React. 3. Read API + Cognito. 4. Terraform hosting per env. 5. Wire the three CI/CD steps. The Grafana track (see plan §5) runs in parallel for immediate go-live dashboards.
