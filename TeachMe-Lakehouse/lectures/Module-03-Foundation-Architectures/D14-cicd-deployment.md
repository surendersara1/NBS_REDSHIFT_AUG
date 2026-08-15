# D14 · From Commit To Environment

> **Module 3 · Architecture 14 · deep dive** · ~20 min

**Diagram:** [`_render/D14-cicd-deployment.html`](_render/D14-cicd-deployment.html)

## What this pattern is for

Getting a change from a developer's branch into an environment **with no long-lived AWS credentials anywhere**, and with exactly one manual gate — in front of production only.

## The nine steps

**1 · A developer opens a pull request.** Not a push to a deploy branch. The PR is where review happens, and review is the only control that scales.

**2 · The repository, branch per environment.** `develop` → dev, `release` → qa, `main` → prod. The mapping must match the OIDC trust policies exactly (D13) or deployments fail in ways that take a morning to diagnose.

**3 · Lint and tests run.** Including **spec validation** — the per-table declarations are the thing most likely to be wrong, and they are pure data, so they can be checked in seconds without a cluster.

**4 · `terraform plan`, posted to the PR.** ⭐ The plan is the review artefact. A reviewer approves *a specific plan*, not a vague intention. This is what makes "what will this change?" answerable before it changes anything.

**5 · OIDC, not stored keys.** ⭐ The pipeline assumes a role via OpenID Connect and receives short-lived credentials. **There is no AWS access key in the CI system to leak, rotate or forget.** If you take one thing from this diagram, take this one.

**6 · The wheel is built once.** One versioned artifact, published to the artifact store. The same bytes are deployed to dev, then qa, then prod — not rebuilt per environment, because a rebuild is a chance to be different.

**7 · Artifacts land in a bucket.** The wheel and the specs, versioned. This is what "promotion" actually moves (D20).

**8 · Manual approval — production only.** ⭐ Dev and QA deploy automatically; slowing them down teaches people to route around the pipeline. Production has one gate, and the approver is looking at the plan from step 4.

**9 · `terraform apply` — the plan that was reviewed.** Not a fresh plan generated at apply time. Applying an unreviewed plan makes step 4 theatre.

## The rule

> **The pipeline is the only key holder.**

If a person can change production without going through this picture, the picture is decoration. That includes emergency fixes — an emergency path that bypasses review is the one that will be used at 2am by someone tired.

## What breaks if you skip a piece

- **Stored access keys** — they leak, and they never expire.
- **No plan in the PR** — reviewers approve intentions, not changes.
- **Rebuild per environment** — prod runs bytes nobody tested.
- **Approval gates on dev and QA** — people route around the pipeline.
- **Fresh plan at apply time** — the review was of something else.

## Checklist

- [ ] No long-lived AWS credentials in CI
- [ ] OIDC trust matches the branch that actually deploys each environment
- [ ] `terraform plan` is posted to the PR and reviewed
- [ ] One artifact built once and promoted unchanged
- [ ] Manual approval on production only
- [ ] Apply uses the reviewed plan
- [ ] No human has console write access to production

## You've got it when you can…

…be asked "how did that get into production?" and answer with a PR number, a plan, an approver and a pipeline run — every time, including for the urgent one.
