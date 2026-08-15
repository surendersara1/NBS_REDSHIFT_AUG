# L19 · How the Infrastructure Is Built

**Slide:** [`_render/L19-terraform-architecture.html`](_render/L19-terraform-architecture.html)

## The point

Every AWS resource in this platform — the VPC, the six KMS keys, the Redshift namespace, all of it — is declared in Terraform under `infra/`. There is no console-clicked infrastructure that matters, and the whole estate is built from exactly two kinds of file.

- **A module** (`infra/modules/<name>/`) is a reusable building block. It takes inputs. It knows no environment name, no account id, no CIDR. **28 of them today.**
- **An environment root** (`infra/env/{dev,qa,prod}/`) is a *composition* — a list of module calls plus a `terraform.tfvars` of values. `infra/env/dev/main.tf` alone contains **24 `module` blocks**; the three env roots hold 21 / 21 / 20 `.tf` files.
- Everything that differs between Dev, QA and Prod is a **value**, not code. Dev's VPC is `10.248.4.0/24`, QA's `10.248.6.0/24`, Prod's `10.248.8.0/24` — same `modules/vpc`.

## Key ideas

- **The module/env boundary is the whole design.** If a file under `infra/modules/` contains the word `dev`, an account id, or a live subnet id, it has stopped being a module. That is not style — it is why one bug fix in `modules/kms` lands in three environments at once.
- **A module is four files:** `main.tf` (resources), `variables.tf` (the inputs it accepts), `outputs.tf` (what it hands back), `versions.tf` (what it needs to build). Every one of the 28 has all four.
- **Env roots wire modules to each other, not to AWS.** `module.iam` receives `module.kms.key_arns["bronze"]`; `module.redshift` receives `module.vpc.data_subnet_ids`. Terraform derives the apply order from those references — nobody writes a dependency graph by hand.
- **Guard rail 1 — pin the provider.** `aws = "~> 6.28"`, `required_version >= 1.9`, declared in the env root *and* in all 28 modules. Without it, an AWS provider release between your plan and your colleague's plan silently changes what "no change" means.
- **Guard rail 2 — `prevent_destroy` on anything stateful.** KMS keys, every S3 bucket, the CloudTrail bucket, and the Redshift Serverless namespace carry `lifecycle { prevent_destroy = true }`. Terraform requires that to be a **literal**, so it cannot be toggled by a variable — the code comments spell out that `var.deletion_protection` controls something else entirely (the KMS deletion *window*, the S3 `force_destroy` flag). Read the resource, not the variable name.
- **Guard rail 3 — state isolation, and what it actually is today.** Each env has its own `backend.tf` and its own state **key**. But all three still name the *same* bucket and the *same* DynamoDB lock table (`tamimi-lakehouse-tfstate-633740007496`); only `key` differs. The audit calls this **CRIT-01** — a Dev apply has `s3:DeleteObject` on Prod state. The `dev`/`qa` backend files carry a long comment describing the per-env split as if it were done. **It is not done in the values.** Read the value, not the comment.
- **Two smaller safeties worth copying:** `allowed_account_ids` on the provider (fail the plan if the assumed identity is in the wrong account), and `-lock-timeout=30m` on every CI plan/apply so a second push queues behind the first instead of dying on `ConditionalCheckFailedException`.

## Words you'll hear

| Word | What it means here |
|---|---|
| Module | Reusable block under `infra/modules/<name>/`; env-blind by rule |
| Composition / env root | `infra/env/<env>/` — the file that calls modules and passes values |
| `tfvars` | The per-environment value file; the only place an env is allowed to differ |
| State | Terraform's record of what it built; lives in S3, locked by DynamoDB |
| `prevent_destroy` | A literal lifecycle guard that makes `terraform destroy` fail on that resource |
| Provider pinning | `aws = "~> 6.28"` — the plan you produce is the plan a colleague reproduces |
| Blast radius | How much a single bad apply can damage. CRIT-01 is a blast-radius finding |

## In this repo

- [`infra/modules/`](../../../tamimi-lakehouse/infra/modules) — the shelf: `vpc`, `vpc-peering`, `tgw-route`, `iam`, `kms`, `secrets`, `s3`, `s3-data-lake`, `ssm`, `cloudtrail`, `lake-formation`, `glue-job`, `glue-connection`, `glue-catalog`, `lambda`, `step-function`, `eventbridge`, `redshift-serverless`, `mwaa`, `sns`, `sqs`, `budgets`, `control_plane`, `customer_dims`, `dispatcher_lambda`, `dbt_silver_to_gold`, `dim_upload`, `catalog_federation` — **28 directories, 28 `versions.tf`**.
- [`infra/env/dev/main.tf:11-22`](../../../tamimi-lakehouse/infra/env/dev/main.tf) — `module "vpc"`, the shape every other block follows; `:27-40` the KMS block that lists the six layers; `:45-55` IAM receiving KMS outputs.
- [`infra/env/dev/versions.tf:1-22`](../../../tamimi-lakehouse/infra/env/dev/versions.tf) — `required_version >= 1.8.0`, `aws ~> 6.28.0`, plus `archive`/`null`/`random`. Compare `infra/modules/kms/versions.tf` — same pins, module-side.
- [`infra/env/dev/backend.tf:18-26`](../../../tamimi-lakehouse/infra/env/dev/backend.tf) — the S3 backend. Read lines 20 and 23 against the comment at lines 3-16.
- [`infra/modules/kms/main.tf:45-50`](../../../tamimi-lakehouse/infra/modules/kms/main.tf) — `prevent_destroy` with the HIGH-17 comment explaining why it cannot be variable-driven. Same pattern in `modules/s3/main.tf:71-83`, `modules/redshift-serverless/main.tf:72-76`, `modules/cloudtrail/main.tf:76-79`.
- [`infra/env/dev/providers.tf:1-10`](../../../tamimi-lakehouse/infra/env/dev/providers.tf) — `allowed_account_ids` (M-36) and `default_tags`.
- [`docs/handoff/audit_deep_analysis.md:122-133`](../../../tamimi-lakehouse/docs/handoff/audit_deep_analysis.md) — CRIT-01 in full, with the remediation blueprint.

## Do this

1. Open `infra/modules/vpc/variables.tf` and `infra/env/dev/main.tf:11-22` side by side. Every variable the module declares is either passed here or defaulted. Now find where `10.248.4.0/24` is written — it is in `terraform.tfvars`, and nowhere else.
2. Grep the modules directory for an environment name: `grep -rn "\"dev\"\|633740007496" infra/modules/`. Anything you find is a bug in the making.
3. Compare `infra/env/dev/main.tf` and `infra/env/prod/main.tf`. Find the one `module` block whose *arguments* genuinely differ (hint: `sap_tgw_route` — Prod passes `data_route_table_ids`, Dev passes `private_route_table_ids`). Ask why. That is L22's story.
4. Add `prevent_destroy` in your head to the DynamoDB control-plane tables and predict what breaks. (Answer: any `for_each` key removal is blocked at plan time — the same trade-off the `s3` module documents at `main.tf:71-83`.)

## You've got it when you can…

…draw the two-layer picture — **28 env-blind modules on the shelf, three env roots that call them with different values** — name the three guard rails (`versions.tf` pinning, `prevent_destroy`, per-env state), and then say honestly what the third one *actually* is today: one bucket, one lock table, three keys — which is CRIT-01, not isolation.
