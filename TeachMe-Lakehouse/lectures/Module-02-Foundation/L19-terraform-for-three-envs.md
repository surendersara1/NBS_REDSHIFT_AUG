# L19 · Structure Terraform for Three Environments

> **Module 2 · Lesson 19** · ~45 min
> **Slide:** [`_render/L19-terraform-for-three-envs.html`](_render/L19-terraform-for-three-envs.html)

## The decision

You need Dev, QA and Prod. You can copy the whole stack three times, or you can build **one shelf of reusable modules** and write three thin compositions that call them with different values.

Choose the shelf. Then answer the harder question, the one that sets your blast radius: **what does Dev still share with Prod?** Sharing modules is the point. Sharing *state* is the danger.

## Do this

1. **Split the tree in two, and keep the halves honest.**

   ```
   infra/
     modules/<name>/     main.tf · variables.tf · outputs.tf · versions.tf
     env/dev/            main.tf · backend.tf · providers.tf · terraform.tfvars
     env/qa/
     env/prod/
   ```

   A module takes inputs and knows nothing else. If a file under `modules/` contains an environment name, an account id, a live subnet id or a CIDR, it has stopped being a module. Make that a review rule and grep for it:

   ```bash
   grep -rniE '"(dev|qa|prod)"|[0-9]{12}|10\.[0-9]+\.[0-9]+\.[0-9]+' infra/modules/
   ```

2. **Let the env root wire modules to each other, not to AWS.** Pass `module.kms.key_arns["bronze"]` into `module.iam`; pass `module.vpc.data_subnet_ids` into the warehouse. Terraform derives the apply order from those references, so nobody maintains a dependency graph by hand.

3. **Pin the provider in every module *and* every env root**, not just at the top:

   ```hcl
   terraform {
     required_version = ">= 1.9"
     required_providers { aws = { source = "hashicorp/aws", version = "~> 6.28" } }
   }
   ```

   Unpinned, a provider release between your plan and a colleague's plan changes what "no changes" means.

4. **Isolate state per environment — bucket, lock table and key.** Three keys in one bucket is not isolation; it means a Dev apply holds `s3:DeleteObject` on the Prod state object.

   ```hcl
   # infra/env/prod/backend.tf
   terraform {
     backend "s3" {
       bucket         = "ag-lakehouse-tfstate-prod-<prod-account-id>"
       key            = "prod/terraform.tfstate"
       dynamodb_table = "ag-lakehouse-tflock-prod"
       region         = "me-central-1"
       encrypt        = true
     }
   }
   ```

   **Verify the values, not the comment.** A header block describing per-environment isolation proves nothing; read `bucket` and `dynamodb_table` on all three and confirm the three strings differ.

5. **`prevent_destroy` on everything stateful** — data buckets, KMS keys, the warehouse namespace, the state bucket itself:

   ```hcl
   lifecycle { prevent_destroy = true }
   ```

   Terraform requires a literal here, so it cannot be driven by a variable. Read the resource, not a variable whose name sounds protective.

6. **Put the environment in every resource name** — `ag-lakehouse-raw-prod-<account>` — so a mis-targeted console action is obvious at a glance, and so a copy-paste between envs collides instead of silently succeeding.

7. **Two cheap safeties worth adding on day one.**
   - `allowed_account_ids` on the provider, so a plan run with the wrong identity fails before it touches anything.
   - `-lock-timeout=30m` on every plan and apply, so a second pipeline run queues behind the first instead of dying on the lock.

## Why

Modules exist so one fix lands in all three environments. That is the benefit, and it is real.

State isolation exists so a *mistake* does **not** land in all three. Those are opposite requirements, and the layout has to serve both: share the code, never share the state.

> **What breaks if you don't:** a dev mistake can destroy production.

## On Apparel Group

- One `modules/` shelf covers all 8 sources. The Oracle sources (RMS, SIM, XStore) reuse the same VPC, KMS, IAM and Glue-job modules as the SaaS sources (Epsilon, MoEngage, Magento) and the footfall feeds (Vemco, Irisys).
- Everything that differs is a **value in `terraform.tfvars`**: the Oracle source CIDRs, the Epsilon and MoEngage endpoints, the per-environment VPC range, the secret names.
- Three environments × three Oracle sources means nine JDBC connection definitions generated from one module — not nine hand-written blocks.
- Name the state buckets before you write a single resource. It is a ten-minute decision on day one and a migration project in week ten.

**Worked example of the pattern:** the Tamimi repo's `infra/modules/` (29 modules, each with all four files) beside `infra/env/{dev,qa,prod}/`, where the only per-environment difference is the tfvars.

## Checklist

- [ ] `infra/modules/` contains no environment name, account id or CIDR
- [ ] Every module and every env root has a `versions.tf` with a pinned provider
- [ ] The three `backend.tf` files name three different buckets **and** three different lock tables
- [ ] `prevent_destroy = true` on every bucket, key and warehouse namespace
- [ ] Every resource name carries the environment
- [ ] `allowed_account_ids` set on each env's provider
- [ ] `-lock-timeout` set on every backend-touching command

## You've got it when you can…

- Draw the two-layer picture — env-blind modules on a shelf, three thin compositions calling them — without looking.
- Say which single value you would change to give QA a different VPC range, and name the one file it lives in.
- Open any `backend.tf` and state, from the values alone, whether that environment's state is genuinely isolated.
- Explain in one sentence why `prevent_destroy` cannot be a variable, and what that implies for how you review it.
