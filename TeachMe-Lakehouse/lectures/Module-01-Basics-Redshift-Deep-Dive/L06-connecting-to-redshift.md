# L06 · Connecting To Redshift

> **Module 01 · Lesson 06** · ~40 min · **written for Node developers**

**Slide:** [`_render/L06-connecting-to-redshift.html`](_render/L06-connecting-to-redshift.html)

## What it is

Four ways in. Your instinct as a Node developer is a connection pool — and for most of what you will write here, that is the wrong one.

Connections are a **scarce, expensive resource** in a warehouse, and queries take seconds rather than milliseconds. Holding a pool open across a fleet of Lambdas is how you exhaust the connection limit and take the warehouse down for everyone.

## The four doors

### 1 · Redshift Data API — *use this from Node*
HTTPS, IAM-authenticated, **no connection to hold**. You submit a statement, get an ID back, poll for completion, then fetch results.

```js
import {
  RedshiftDataClient,
  ExecuteStatementCommand,
  DescribeStatementCommand,
  GetStatementResultCommand,
} from "@aws-sdk/client-redshift-data";

const client = new RedshiftDataClient({});

export async function runSql(sql, params = []) {
  const { Id } = await client.send(new ExecuteStatementCommand({
    WorkgroupName: process.env.REDSHIFT_WORKGROUP,
    Database:      process.env.REDSHIFT_DATABASE,
    Sql:           sql,
    Parameters:    params,          // [{ name: 'p1', value: '2026-01-01' }]
  }));

  // poll — the Data API is asynchronous, unlike `pg`
  for (;;) {
    const st = await client.send(new DescribeStatementCommand({ Id }));
    if (st.Status === "FINISHED") break;
    if (st.Status === "FAILED" || st.Status === "ABORTED") {
      throw new Error(`${st.Status}: ${st.Error}`);
    }
    await new Promise(r => setTimeout(r, 500));
  }

  const out = await client.send(new GetStatementResultCommand({ Id }));
  return out.Records ?? [];
}
```

Note `Parameters` — **use them**. It keeps you out of SQL-injection trouble and it reuses the compile cache (L05).

### 2 · JDBC / ODBC — *for long-lived services and BI*
Port **5439**. What Power BI and Tableau use. The `pg` driver from Node also works, and is correct for a long-running service that can hold a pool — **wrong for a Lambda that lives for 400ms**.

### 3 · Query Editor v2 — *where you will actually live*
Browser SQL in the console. Saved queries, result export, no local setup, no credentials on your laptop. Use it for everything while learning.

### 4 · psql
The Postgres CLI connects. Useful for scripting and for anyone who lives in a terminal.

## Data API vs `pg` — the decision

| | Data API | `pg` driver |
|---|---|---|
| Connection | none held | pooled, must be managed |
| Auth | IAM | username/password or IAM |
| Lambda | ✅ correct | ❌ leaks connections |
| Long-lived service | works | ✅ correct |
| Result size | paginated, modest | streams large results |
| Style | async submit + poll | blocking call |
| VPC needed | no | yes, for private clusters |

**Rule:** if the code is serverless or short-lived, use the Data API. If it is a long-running service that can own a pool properly, `pg` is fine.

## Try it

```bash
# from a shell with AWS credentials
aws redshift-data execute-statement \
  --workgroup-name my-workgroup \
  --database dev \
  --sql "select current_user, current_database()"

# then, with the Id it returned
aws redshift-data get-statement-result --id <statement-id>
```

## Gotchas

- **The Data API is asynchronous.** It does not block like `pg`. Code written expecting a synchronous return will silently get nothing.
- **A connection pool inside Lambda leaks.** Each concurrent invocation opens its own; scale to 200 concurrency and you have 200 connections.
- **There is a connection limit**, and hitting it locks out everyone including your ETL.
- **Data API results are paginated** and not meant for pulling millions of rows — use `UNLOAD` for that (L27).

## Checklist

- [ ] I know why a connection pool in Lambda is wrong
- [ ] I can write the submit → poll → fetch loop from memory
- [ ] I use `Parameters` rather than string concatenation
- [ ] I know when `pg` is the right choice instead
- [ ] I know large result sets belong in `UNLOAD`, not the Data API

## You've got it when you can…

…review a colleague's Lambda that opens a `pg` pool and explain — in terms of connection limits, not style — why it will work in test and fail under load.
