# Redshift Hands-On Labs
### "Four days of AWS Redshift labs, mapped lesson by lesson"

**Companion to Module 01 · Redshift Deep Dive · 4 days · links verified 12 August 2026.**

> **How to use this.** Module 01 is 45 lessons of *why*. This is the *doing*. Each day
> pairs a block of lessons with a real AWS lab that provisions real infrastructure.
>
> Read the lessons first, then do the lab. The lab makes it stick; the lesson makes the
> lab make sense. Doing the labs cold is how people finish a workshop having clicked
> forty buttons and learned nothing.

---

## Link verification

Every URL below was fetched and confirmed live on **12 August 2026**. Two corrections to
note before you send anyone a link:

| Resource | Status | What I confirmed |
|---|---|---|
| **Redshift Immersion Day** | ⚠️ **use the canonical URL** | The old `redshift-immersion.workshop.aws` returns **301 Moved Permanently** to a UUID URL. Both work today, but cite [`catalog.workshops.aws/redshift-immersion/en-US`](https://catalog.workshops.aws/redshift-immersion/en-US) — the UUID form is a redirect *target* and can change |
| [**Data Engineering Immersion Day**](https://github.com/aws-samples/data-engineering-for-aws-immersion-day) | ✅ active · 198★ · 119 commits | Lab titles confirmed verbatim: **Lab 1** "Hydrating the data lake via DMS", **Lab 6** "Modernize Data Warehouse with Amazon Redshift Spectrum". Has an **AutoComplete DMS** shortcut if Lab 1 setup runs long |
| [**dbt + Redshift pipelines**](https://catalog.workshops.aws/opensource-with-redshift/en-US) | ✅ live | Full title: "Build and Deploy Data Pipelines with Amazon Redshift, dbt…". Uses dbt **and** MWAA |
| [**Redshift Streaming Workshop**](https://github.com/aws-samples/amazon-redshift-streaming-workshop) | ✅ active, but **13★ · 33 commits** | Smallest and least-trafficked of the four. CDK (Python) provisions Kinesis, Redshift, Lambda, Step Functions, SNS and **Managed Grafana**. Also includes a **Redshift ML** step |
| [**MSK streaming best practices**](https://aws.amazon.com/blogs/big-data/best-practices-to-implement-near-real-time-analytics-using-amazon-redshift-streaming-ingestion-with-amazon-msk/) | ✅ live · 11 Mar 2024 | Authors Poulomi Dasgupta, Adekunle Adedotun. Contains the IAM policies (incl. cross-account) and the `CREATE MATERIALIZED VIEW … WHERE CAN_JSON_PARSE(kafka_value)` pattern, plus an incremental-load stored procedure using Kafka partition/offset as the CDC marker |

### ⚠️ The 23-lab problem

Redshift Immersion Day contains **more than 23 labs**. It cannot be done in a day, and
attempting Levels 100–300 in two days means skimming. **Select deliberately** — the day
plans below name the topics to pick, not "do the workshop".

---

## The four-day plan

I have restructured this from the three days originally proposed, for two reasons: the
lab count above, and because **streaming ingestion is not Module 01 material** — it is
taught in Module 00. Day 4 is therefore an extension day, not a core day.

### Day 1 — Foundations and physical design
**Read first:** L01–L20 (Parts A, B, C) · **Lab:** [Redshift Immersion Day](https://catalog.workshops.aws/redshift-immersion/en-US)

Pick the labs covering: cluster/workgroup creation · loading with `COPY` · **table design
and distribution/sort keys** · compression.

The table-design lab is the single most valuable hour in the whole track. It is L14–L20
made physical: you build the same table two ways and watch the query time change.

> **Do this during the lab:** after each design change, run the `svv_table_info` query
> from L43 and record `size`, `skew_rows`, `unsorted` and `stats_off`. By the end of the
> day the team should read that view without prompting.

### Day 2 — Loading, and the lake
**Read first:** L21–L27 (Part D) + L12 · **Labs:** [Immersion Day](https://catalog.workshops.aws/redshift-immersion/en-US)
TPC benchmark load, then
[Data Engineering Immersion Day](https://github.com/aws-samples/data-engineering-for-aws-immersion-day)
**Lab 1** and **Lab 6**

The TPC load gives them `COPY` at a scale where design mistakes actually hurt. Lab 1
hydrates a data lake via **DMS** — which is exactly the Tamimi and Apparel Group source
pattern. Lab 6 is Spectrum, i.e. L12 made real.

> **Use the AutoComplete DMS shortcut** if Lab 1 setup overruns. Getting to Lab 6 matters
> more than watching DMS provision.

### Day 3 — Performance and operations
**Read first:** L28–L34 (Part E) + L41–L45 (Part G) · **Labs:**
[Immersion Day](https://catalog.workshops.aws/redshift-immersion/en-US) WLM /
performance labs, **plus the two custom labs below**

This is the day with the biggest gap in AWS's material, and the day that most changes how
the team works. See **the gap** section next.

### Day 4 — Code and pipelines *(extension)*
**Read first:** L35–L40 (Part F) · **Labs:**
[dbt + Redshift](https://catalog.workshops.aws/opensource-with-redshift/en-US), then
[Streaming](https://github.com/aws-samples/amazon-redshift-streaming-workshop)

Do **dbt** in the morning: it is SQL transformation with tests and lineage, and it maps
onto L31–L35. If MWAA cost or setup time is a concern, use
[dbt CLI and Amazon Redshift](https://catalog.workshops.aws/dbt-cli-and-amazon-redshift/en-US/introduction)
instead — same dbt, no orchestration layer.

Do **streaming** in the afternoon only if the team is ahead — it is Module 00 material and
provisions the most expensive stack in this document. Pair it with the
[MSK best-practices blog](https://aws.amazon.com/blogs/big-data/best-practices-to-implement-near-real-time-analytics-using-amazon-redshift-streaming-ingestion-with-amazon-msk/)
for the IAM policies and the materialized-view SQL.

---

## ⚠️ The gap: two lessons no AWS lab covers

I checked all four workshops against the 45 lessons. **The two lessons written
specifically for this team have no lab anywhere in AWS's catalogue:**

- **L39 · Calling Redshift From Node.js** — every workshop uses Query Editor v2. None of
  them writes application code against the Data API.
- **L44 · Diagnosing A Slow Query** — the workshops show you a fast query. None hands you
  a slow one and asks why.

These are the two most important lessons for three Node.js developers becoming warehouse
engineers, so they need purpose-built exercises. Both are already specified in the
take-homes; run them as timed labs on **Day 3**.

### Custom Lab A — the Node.js integration (≈2 hours)
*From L39 "Try it" · run against the Day 1 cluster*

1. Write the Data API client: `execute` with exponential backoff, `query` with `NextToken`
   pagination and typed-union unwrapping.
2. Return 5,000 rows and confirm you get all of them. **Then delete the `NextToken` loop
   and count what you get.** That silent truncation is the exercise.
3. Load 10,000 rows twice — a loop of `INSERT`s, and S3 + `COPY`. Time both, then compare
   `size` and `unsorted` in `svv_table_info`. **Put both block counts on the board.**
4. Move a three-statement job into one `CALL` and prove the failure rolls back cleanly.
5. Switch from a stored password to `GetCredentials` temporary credentials.

Step 3 is the one that permanently changes how they write load code.

### Custom Lab B — the six-question playbook (≈2 hours)
*From L44 · use the TPC tables from Day 2*

1. Deliberately break a good query four ways — skip the `ANALYZE`, set the small dimension
   to `DISTSTYLE EVEN`, widen a `VARCHAR` to 65535, wrap the sort column in `DATE_TRUNC`.
2. One person drives; everyone else works the six questions **in order** and writes down
   each answer before moving on.
3. **Whoever suggests rewriting the SQL before question 6 buys the coffee.**
4. Fix, re-measure with the result cache off, confirm with `EXPLAIN`.
5. Write the diagnosis in a one-paragraph note in the repo.

Four induced faults, six questions, four correct diagnoses. If the team can do this, they
can operate the warehouse.

---

## Lesson → lab coverage

Where each part of Module 01 gets hands-on reinforcement:

| Part | Lessons | Lab coverage |
|---|---|---|
| **A** · What Redshift is | L01–L07 | ✅ Immersion Day Level 100 |
| **B** · Objects and types | L08–L13 | 🟡 Partial — Spectrum well covered (Lab 6), `SUPER` only in the streaming lab |
| **C** · Physical design | L14–L20 | ✅ **Strong** — the table-design lab is the best in the track |
| **D** · Getting data in and out | L21–L27 | ✅ **Strong** — TPC load + DMS Lab 1 |
| **E** · SQL that performs | L28–L34 | 🟡 Partial — **Custom Lab B fills the diagnosis gap** |
| **F** · Programmability | L35–L40 | 🟡 dbt covers transformation · **Custom Lab A fills the Node.js gap** |
| **G** · Operating it | L41–L45 | 🟡 WLM covered · no cost or maintenance lab — use the L42/L45 queries on the live cluster |

**What the labs give you that Module 01 does not:** DMS hydration end to end, dbt's
testing and lineage model, Airflow orchestration, Kinesis streaming ingestion, Redshift
ML, and Managed Grafana dashboards. Worth knowing they are there.

---

## ⚠️ Cost and teardown

These labs provision **real, billable infrastructure**. Two of them are expensive and
easy to leave running:

| Lab | Watch out for |
|---|---|
| Streaming workshop | **Managed Grafana** and the Kinesis stream bill continuously. Run `cdk destroy` the same day — it is in the lab, do not skip it |
| dbt + MWAA | **MWAA is the most expensive component in this document** and does not auto-pause |
| Data Engineering Day | **DMS replication instances** keep running after the lab ends |
| Immersion Day | Use a **Serverless workgroup** where the lab allows it — it auto-pauses overnight; a provisioned cluster does not |

**Before Day 1:** set an AWS Budgets alarm on the training account. **After every day:**
one person is named teardown owner and confirms in writing. A forgotten MWAA environment
over a weekend costs more than the whole training.

---

## Prerequisites

- A **dedicated training AWS account** — never the Tamimi Dev account. These labs create
  and delete infrastructure freely.
- Elevated IAM privileges (the CDK and CloudFormation stacks need them).
- Locally: **CDK, Docker CLI, Python 3, Node 18+, `git`, `psql`** and the AWS CLI v2 with
  SSO configured.
- Access to Query Editor v2 in the console.
- Module 01 take-homes open in a second window. The SQL in them is the lab notebook.

---

## Every link, in one place

| # | Resource | URL |
|---|---|---|
| 1 | **Redshift Immersion Day** (canonical) | https://catalog.workshops.aws/redshift-immersion/en-US |
| 2 | Data Engineering Immersion Day (GitHub) | https://github.com/aws-samples/data-engineering-for-aws-immersion-day |
| 3 | Build and Deploy Data Pipelines with Redshift + dbt | https://catalog.workshops.aws/opensource-with-redshift/en-US |
| 4 | dbt CLI and Amazon Redshift *(gentler starting point)* | https://catalog.workshops.aws/dbt-cli-and-amazon-redshift/en-US/introduction |
| 5 | Amazon Redshift Streaming Workshop (GitHub) | https://github.com/aws-samples/amazon-redshift-streaming-workshop |
| 6 | Near-real-time analytics with MSK (blog) | https://aws.amazon.com/blogs/big-data/best-practices-to-implement-near-real-time-analytics-using-amazon-redshift-streaming-ingestion-with-amazon-msk/ |
| 7 | Awesome AWS Workshops (index) | https://awesome-aws-workshops.com/ |

**#4 is an addition** — a dbt CLI workshop without the MWAA layer. Start there if Day 4
runs short or if MWAA cost is a concern; it teaches dbt itself without the orchestration
infrastructure.

---

*Author: Surender Sara · Northbay Solutions · links verified 12 August 2026*
