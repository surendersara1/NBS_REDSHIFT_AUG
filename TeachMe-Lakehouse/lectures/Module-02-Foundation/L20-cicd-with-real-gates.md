# L20 · Set Up CI/CD With Real Gates

> **Module 2 · Lesson 20** · ~45 min
> **Slide:** [`_render/L20-cicd-with-real-gates.html`](_render/L20-cicd-with-real-gates.html)

## The decision

A merge has to become infrastructure. Two things must be true along the way, and both are choices you make in week one:

1. **The pipeline needs AWS credentials it can never store.**
2. **Someone must be able to stop it — and their approval has to mean something.**

A gate that approves one plan and then applies a different one is decoration. Build the gate so that cannot happen.

## Do this

1. **Federate with OIDC. Never issue the pipeline a static access key.**
   The CI system mints a short-lived signed token per step; AWS trades it for a one-hour role session. No secret is stored anywhere, and there is nothing to rotate or leak.

   ```yaml
   # the whole exchange — four lines, no credentials
   - export AWS_REGION=me-central-1
   - export AWS_ROLE_ARN=$AWS_ROLE_PROD_ARN
   - echo "$CI_STEP_OIDC_TOKEN" > /tmp/web-identity-token
   - export AWS_WEB_IDENTITY_TOKEN_FILE=/tmp/web-identity-token
   ```

2. **Write the trust policy as the real gatekeeper, and keep it in sync with the pipeline.**
   The trust policy decides which branch may assume which role — the pipeline YAML has no say. Condition on the audience *and* the subject claim, and cap the session:

   ```hcl
   condition {
     test = "StringEquals"; variable = "<provider>:aud"; values = [var.workspace_id]
   }
   condition {
     test = "StringLike";   variable = "<provider>:sub"; values = ["{${var.repo_uuid}}:${var.branch_pattern}:*"]
   }
   max_session_duration = 3600
   ```

   **Make `branch_pattern` match the branch the pipeline actually deploys from.** Put the two lists side by side — one per environment — and check them. A mismatch shows up as `AccessDenied` on assume-role, which reads like a permissions bug and is not one.

3. **One deploy role per environment.** `…-deploy-dev`, `…-deploy-qa`, `…-deploy-prod`. Never one shared role with three sets of permissions: the whole point is that a Dev pipeline cannot reach QA or Prod even if someone edits the YAML.

4. **Plan to a file, then apply that file.**

   ```bash
   terraform plan -out=/tmp/prod.tfplan -lock-timeout=30m
   terraform show  /tmp/prod.tfplan          # this is what the human reads
   # ── manual gate ──
   terraform apply /tmp/prod.tfplan -lock-timeout=30m
   ```

   Generate the plan **inside** the gated step and apply that same artifact. A saved plan fails closed if state moved since it was written — which is exactly the protection you want. `apply -auto-approve` computes a *fresh* plan and rubber-stamps it.

5. **Put a manual gate on QA and Prod.** Dev may auto-apply; it is the environment whose job is to be broken. Everything above Dev waits for a person to click.

6. **Deploy in the order the dependencies require.** Artifacts before the apply that references them:

   ```
   targeted apply (KMS + S3)  →  upload wheels / scripts / specs / zips
                              →  full plan  →  gate  →  full apply
                              →  seed the control plane
   ```

7. **Pin and checksum everything the runner downloads.** The runner holds cloud credentials, so nothing unversioned may land on it: exact versions for the CLI and build tools, exact versions for Lambda-layer dependencies, and a SHA-256 comparison on every JDBC driver jar before it is uploaded.

   ```bash
   computed=$(sha256sum ojdbc11.jar | cut -d' ' -f1)
   test "$computed" = "$OJDBC_SHA256" || { echo "driver checksum mismatch"; exit 1; }
   ```

8. **Fail closed on missing configuration.** Write required pipeline variables as `${VAR:?message}` so the step dies rather than silently downloading or deploying something unverified.

## Why

OIDC removes the thing you would otherwise have to protect forever: there is no long-lived key, so there is nothing to steal, rotate or accidentally print into a log.

The saved plan is what makes approval real. Approval is not "I agree with this change in principle" — it is "I agree with *these* resource diffs".

> **What breaks if you don't:** the human approved a plan that never ran.

## On Apparel Group

- Three environments, three deploy roles, three branch patterns. Write the branch↔role table on the wall in week one and check it the first time a deploy fails to see AWS.
- **Dev auto-applies; QA and Prod wait for a person.** With four workstreams (Data Foundation, Price Optimization, Inter-store Transfer, Amazon Quick) pushing in parallel over 12 weeks, the gate is the only thing keeping an in-progress model out of a client demo.
- The **Oracle JDBC driver** is a third-party binary that ends up on a credentialed runner and then in every Glue job. Pin the version and verify the checksum before upload.
- The Epsilon and MoEngage SDKs go in a Lambda layer — pin them exactly, and build them for the CPU architecture the functions actually run on.
- Concurrent pushes from four workstreams will collide on the state lock. Set `-lock-timeout=30m` so the second run queues instead of failing.

**Worked example of the pattern:** the Tamimi `bitbucket-pipelines.yml` — OIDC exchange, targeted bootstrap apply, artifact upload, gated `plan -out` → `apply <file>`, then the control-plane seed.

## Checklist

- [ ] No `AWS_ACCESS_KEY_ID` anywhere in the pipeline definition or its variables
- [ ] Trust policy conditions on both `aud` and `sub`; session capped at 1 hour
- [ ] Branch patterns in the trust policy match the pipeline's deploy branches, environment by environment
- [ ] One deploy role per environment, no sharing
- [ ] `plan -out=<file>` generated inside the gated step; `apply <file>` uses that artifact
- [ ] Manual gate on QA and Prod
- [ ] Every downloaded tool, driver and dependency pinned; drivers checksummed
- [ ] `-lock-timeout` set on every plan/apply

## You've got it when you can…

- Explain, without notes, that CI never holds an AWS key — it presents a per-step signed token and receives a one-hour session for exactly one environment.
- Name the three things standing between a merge and production: **a human on the gate, a saved plan that fails closed, and a checksum on every binary the runner fetches.**
- Say what happens if the trust policy's branch pattern and the pipeline's deploy branch disagree — and which of the two you check first.
- Describe the failure mode of `apply -auto-approve` after a manual gate in one sentence.
