# L21 · Set Up Security and Governance

> **Module 2 · Lesson 21** · ~45 min
> **Slide:** [`_render/L21-security-and-governance.html`](_render/L21-security-and-governance.html)

## The decision

Who can read the data — and how narrow can you make that on day one?

Narrow is cheap now and expensive later. A broad grant takes one line to add; taking it back once a dozen jobs quietly depend on it takes a week and a change-freeze. Decide the shape before the first job runs.

## Do this

1. **One role per workload, scoped to that workload's resources.** A job role gets the buckets it reads, the buckets it writes, the catalog objects it owns, and nothing else.

   Never attach a full-access managed policy to a job role. `AmazonS3FullAccess` on an ETL role is an account-wide data-plane grant: that job can read or delete the Terraform state bucket and the audit-log bucket too.

   ```hcl
   resources = [
     "arn:aws:s3:::${local.prefix}-landing-${var.account_id}",
     "arn:aws:s3:::${local.prefix}-landing-${var.account_id}/*",
     "arn:aws:s3:::${local.prefix}-raw-${var.account_id}",
     "arn:aws:s3:::${local.prefix}-raw-${var.account_id}/*",
   ]
   ```

2. **Condition every service-principal grant in a key policy on the source account.** A key policy that lets a service principal use the key on `Resource: "*"` with no condition is the textbook confused-deputy hole — any resource, in any account, that can induce that service to call KMS could use your key.

   ```hcl
   condition {
     test = "StringEquals"; variable = "aws:SourceAccount"; values = [var.account_id]
   }
   ```

3. **One customer-managed key per data layer** — raw, bronze, silver, gold, secrets, audit — in each environment. The point of separate keys is that compromise of one does not decrypt the others, so **also narrow each key's trusted-service list to the services that layer actually uses**. Six keys sharing one fifteen-principal default list is six copies of the same key policy, not separation.

4. **Turn the catalog's default off, then grant explicitly.** Run the data catalog in strict mode: default permissions on a new database or table are NONE, and the "any IAM principal" fallback is disabled. IAM alone then opens nothing; access comes only from explicit, version-controlled grants.

5. **Grant on tags, not on names.** Define the vocabulary up front and grant against it:

   | Tag key | Values |
   |---|---|
   | `layer` | `bronze` · `silver` · `gold` |
   | `sensitivity` | `public` · `internal` · `confidential` · `pii` |
   | `domain` | `rms` · `sim` · `xstore` · `loyalty` · `ecommerce` · `shared` |

   A grant on `sensitivity = pii` keeps working when table 90 arrives. A grant on a list of table names does not.

6. **Secrets by reference only.** Terraform owns the secret's *name*, its key and its rotation policy — never its value. Write a placeholder once, then pin it:

   ```hcl
   lifecycle { ignore_changes = [secret_string] }
   ```

   Consumers receive an **ARN** and resolve the value at run time. Where the platform can own the credential entirely (a managed admin password, for instance), let it — then no password exists in code or state at all.

7. **Put a permissions boundary on any role that can create roles.** A deploy role that can create roles can create a role more powerful than itself unless a boundary caps it. That is a privilege-escalation path, and the boundary is the fix.

8. **Review rule: every wildcard needs a comment.** Some actions legitimately take no resource ARN. Those stay on `"*"` — with a line above saying why.

   ```hcl
   # lakeformation:GetDataAccess takes no resource ARN; scoping happens in LF grants.
   resources = ["*"]
   ```

## Why

Least privilege is not "zero wildcards". It is **every wildcard deliberate, and commented** — so a reviewer can tell the difference between a considered exception and an unconsidered one in five seconds.

> **What breaks if you don't:** a job role becomes an account-wide key.

## On Apparel Group

- **Epsilon loyalty data is PII, and so are MoEngage profiles.** Classify at the spec (`pii_class: pii` per column), mask or tokenise in Silver, and grant reporting on `sensitivity = pii` — not by naming tables. Do it before the first report is built, because a report is the hardest consumer to take access away from.
- **Five workload roles, not one.** Ingestion (Oracle JDBC), ingestion (SaaS API), transform, warehouse read, and orchestration. Each sees only its own buckets and catalog objects.
- **Source credentials for RMS, SIM, XStore, Epsilon, MoEngage and Magento are six secrets, six ARNs.** Jobs get the ARN; nobody gets the value.
- Footfall feeds (Vemco, Irisys) are per-store counts, `sensitivity = internal` — but classify them explicitly rather than by omission, so "unclassified" never becomes a permitted state.
- A permissions boundary goes on the deploy role from day one, because that role creates the workload roles.

**Worked example of the pattern:** the Tamimi `infra/modules/iam` (per-workload roles, bucket ARNs derived from a prefix, boundary attached) and `infra/modules/kms` (one key per layer, `aws:SourceAccount` on the service-principal statement).

## Checklist

- [ ] No full-access managed policy on any workload role
- [ ] Every key-policy service-principal statement carries `aws:SourceAccount`
- [ ] One CMK per data layer, each with a narrowed trusted-service list
- [ ] Catalog in strict mode; default permissions on new objects are NONE
- [ ] Tag vocabulary defined; data grants written against tags
- [ ] Secrets created by name only, values written out of band, consumers hold ARNs
- [ ] Permissions boundary on every role that can create roles
- [ ] Every `"*"` in an IAM policy has a comment explaining itself

## You've got it when you can…

- State the difference between scoping a role and scoping a key policy, and give the one condition key that fixes the confused-deputy case.
- Explain why strict catalog mode means an IAM grant alone opens nothing.
- Argue for tag-based grants over name-based grants in one sentence, using the table count at week 12 as the argument.
- Point at any `"*"` in your IAM code and say why it is there — or file it as a review finding.
- Say where Epsilon PII is classified, where it is masked, and what stops it reaching a report before either happens.
