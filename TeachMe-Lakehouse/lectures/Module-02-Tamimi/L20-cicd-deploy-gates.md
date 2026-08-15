# L20 · How Code Reaches Production

**Slide:** [`_render/L20-cicd-deploy-gates.html`](_render/L20-cicd-deploy-gates.html)

## The point

Search `bitbucket-pipelines.yml` for `AWS_ACCESS_KEY_ID`. It is not there, and it never was. The pipeline authenticates to AWS with a **short-lived OIDC web-identity token** that Bitbucket mints per step, and every deploy to QA or Prod stops and waits for a human.

Three questions answer the whole lesson:

1. **How does CI prove who it is?** OIDC — a signed JWT swapped at STS for a one-hour role session.
2. **Which account does it land in?** The branch decides, via one of three role ARNs.
3. **What stops a bad change?** A manual gate, a saved plan file, and version pins on everything the runner downloads.

## Key ideas

- **`oidc: true` on a step** makes Bitbucket mint a JWT into `$BITBUCKET_STEP_OIDC_TOKEN`, scoped to that step. The pipeline writes it to a file, points `AWS_WEB_IDENTITY_TOKEN_FILE` at it, sets `AWS_ROLE_ARN`, and the AWS SDK does the rest — `sts:AssumeRoleWithWebIdentity`, no credential ever stored.
- **The trust policy is what actually decides.** `global/oidc/main.tf:41-58` allows the exchange only when the token's `aud` equals the workspace ARI *and* its `sub` matches `{<repo-uuid>}:<branch-pattern>:*`. The role's `max_session_duration` is **3600 s**. If the branch does not match, the exchange fails — the pipeline YAML has no say.
- **Read that pair together, because they can drift.** `global/oidc/locals.tf:23-27` maps `dev = "main"`, `qa = "qa-*"`, `prod = "prod-*"`; `bitbucket-pipelines.yml` deploys Dev from **`develop`**, QA from `release/*`, Prod from `main` and `prod-deploy`. Those two lists must agree or the assume-role fails with `InvalidIdentityToken` / `AccessDenied`. Always check the trust policy first when a deploy step cannot see AWS.
- **One role per environment, no sharing.** `AWS_ROLE_DEV_ARN` (Repository variable), `AWS_ROLE_QA_ARN` and `AWS_ROLE_PROD_ARN` (Deployment variables). Each role carries three managed policies, split only because a managed policy version caps at **6,144 bytes**: `-deploy-data-<env>`, `-deploy-compute-core-<env>`, `-deploy-compute-services-<env>`.
- **The deploy order is artifacts-first, and it is not optional.** `aws_lambda_function` fails at apply if its zip is not already in S3, so every pipeline runs: targeted `apply -target=module.kms -target=module.s3` → build and upload wheels/scripts/specs/layer/Lambda zips → full plan → full apply → seed the DynamoDB control plane. The seed step exists because `bronze_pull` aborts on "Spec hash drift" if `bronze_mapping.spec_hash` is stale against the specs just uploaded.
- **The gate.** `trigger: manual` blocks the step until a person clicks: QA's "Apply full QA composition", Prod's "Deploy to Prod (MANUAL APPROVAL REQUIRED)", and `prod-deploy`'s "Apply full Prod composition". Only Dev auto-applies (the import-window gate was retired once the planned imports finished).
- **A gate is theatre unless the approved plan is the applied plan.** The audit's HIGH-11 was exactly this: the human approved `plan A` in one container, and a later step ran `apply -auto-approve` — which computes and rubber-stamps a *fresh* `plan B`. The fix on `main` generates `plan -out=/tmp/prod-full.tfplan` **inside the gated step**, prints it, and applies that file. A saved plan fails closed if state moved since it was written.
- **Supply chain: pin or fail closed.** The runner holds cloud credentials, so nothing unversioned may land on it. `uv` installed via `pip install "uv==${UV_VERSION:-0.10.0}"` (no `curl | sh`); AWS CLI version + `sha256sum -c`; the SAP JDBC driver `ngdbc-2.20.11.jar` downloaded then compared byte-for-byte against `NGDBC_SHA256` before it is uploaded to the artifacts bucket Glue loads at runtime; Lambda-layer deps pinned exactly (`pydantic==2.13.4`, `python-ulid==2.7.0`, `aws-lambda-powertools==2.43.1`, `boto3==1.43.19`) and cross-targeted to `aarch64-manylinux_2_17` because Lambda runs Graviton.
- **`-lock-timeout=30m` on every backend-touching command.** Bitbucket runs successive pushes concurrently; the default `0s` makes the second run die instantly on the state lock. 30 minutes makes it queue. The trade-off — a genuinely stale lock now stalls 30 minutes before erroring — is documented with the `force-unlock` recovery in the file header.

## Words you'll hear

| Word | What it means here |
|---|---|
| OIDC | OpenID Connect — Bitbucket signs a token, AWS trusts the signature, no shared secret |
| Web identity | The token file the SDK trades at STS for temporary credentials |
| Subject claim (`sub`) | `{repo-uuid}:<branch>:<step-uuid>` — what the trust policy pattern-matches |
| Deploy role | `tamimi-lakehouse-bitbucket-deploy-<env>`, one per environment |
| Manual gate | `trigger: manual` — the step will not run until a person clicks it |
| Saved plan | `plan -out=file` then `apply file`; fails closed if state changed |
| Artifacts-first | Upload the Lambda zips before the apply that references them |
| Pinning | An exact version plus, where possible, a checksum |

## In this repo

- [`bitbucket-pipelines.yml:60-109`](../../../tamimi-lakehouse/bitbucket-pipelines.yml) — the shared `&lint-and-test` step: ruff, mypy, `pytest -m "unit or invariant"`, `terraform fmt -check`, and `validate` for all three envs plus `global/oidc`. This is the only thing a pull request runs.
- `:136-139` — the four lines that *are* the OIDC exchange: `AWS_REGION`, `AWS_ROLE_ARN=$AWS_ROLE_DEV_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`, `echo $BITBUCKET_STEP_OIDC_TOKEN > …`.
- `:152-155` — the Dev targeted bootstrap (`-target=module.kms -target=module.s3`) with the plan logged before the apply.
- `:201-203` — the `ngdbc.jar` SHA256 comparison, written as an explicit `test "$computed" = "$expected"` with a failure message, not `sha256sum -c`.
- `:424` — QA's `trigger: manual  # HIGH-11`; `:492-495` — Prod's `trigger: manual` + `deployment: production`; `:692` — the same on `prod-deploy`.
- `:569-571` — `plan -out=/tmp/prod-full.tfplan` → `show` → `apply /tmp/prod-full.tfplan`, with the comment explaining why this is not `-auto-approve`.
- `:33-52` — the state-lock note: the real 2026-08-03 failure (pipeline #434), why 30m, and how to recover a stale lock.
- [`global/oidc/main.tf:30-59`](../../../tamimi-lakehouse/global/oidc/main.tf) — the OIDC provider and the deploy role's `assume_role_policy` (`aud` StringEquals, `sub` StringLike).
- [`global/oidc/locals.tf:12,23-41`](../../../tamimi-lakehouse/global/oidc/locals.tf) — the Bitbucket thumbprint (with the `openssl` command to refresh it), the per-env branch patterns, and the subject-claim construction.
- [`global/oidc/permissions.tf:27-64`](../../../tamimi-lakehouse/global/oidc/permissions.tf) — the ARN globs every statement is scoped to; `:212-221`, `:376-385`, `:504-513` — the three policies and their attachments.

## Do this

1. Trace one deploy end to end in `bitbucket-pipelines.yml`: push to `develop` → lint step → targeted kms/s3 apply → artifact upload → full apply → seed. Name the AWS identity in use at each step, and where it came from.
2. Open `global/oidc/locals.tf:23-27` next to the `branches:` keys in `bitbucket-pipelines.yml`. Write down, for each environment, the branch the pipeline uses and the branch the trust policy allows. If they differ, that deploy cannot assume its role.
3. Delete `trigger: manual` from the Prod step in your head and describe the failure mode in one sentence. Then delete `-out=/tmp/prod-full.tfplan` and describe a different one.
4. Find every `${VAR:?…}` in the file. Each is a fail-closed guard — the step dies if the repo variable is unset rather than silently downloading something unverified.

## You've got it when you can…

…explain that CI never holds an AWS key — it presents a per-step signed token, STS returns a one-hour session for exactly one environment's role — and then name the three things that stand between a merge and production: **a human on `trigger: manual`, a saved plan file that fails closed, and a SHA256 on every binary the runner downloads.**
