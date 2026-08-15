# D13 · Environments And Composition

> **Module 3 · Architecture 13 · as built** · ~15 min

**Diagram:** [`_render/D13-environments-terraform.html`](_render/D13-environments-terraform.html)

## What it shows

**One set of modules, composed three times.** Roughly 28 Terraform modules — networking, storage, catalog, glue, redshift, control-plane, orchestration, observability, iam — instantiated per environment.

> **What differs between environments should be *values*. Never code.**

If dev and prod need different modules, one of them is not really testing the other, and the test you thought you had is imaginary.

## The three environments

**Dev** — its own account, smallest sizing, synthetic and sampled data, deployed from `develop`, destroyed and rebuilt freely.

**QA** — its own account, production-shaped: realistic volumes, real source connections, where UAT and reconciliation actually happen. Same modules, bigger values.

**Prod** — its own account. Nobody logs in to change anything. Manual approval before apply, `prevent_destroy = true` on stateful resources, full retention and alarms.

**An account each.** Not one account with prefixes — the blast radius of a mistake should stop at an account boundary.

## Verify these three in the repo

They drift quietly, and each one is invisible until the day it matters:

1. **Remote state is genuinely separate per environment.** A shared state bucket means a dev mistake can reach prod state. Worth checking the actual `backend.tf` values rather than the comments above them — comments describing a split that no longer exists are the classic trap.
2. **OIDC trust pins each environment to the branch that actually deploys it.** If dev's trust policy names `main` while the pipeline deploys dev from `develop`, deployments fail confusingly — or worse, succeed from the wrong branch.
3. **`prevent_destroy` is on every stateful prod resource.** Buckets, catalogs, the Redshift namespace, the control-plane tables.

These are stated as checks rather than findings because they are the kind of thing that regresses. Verify them against the current repo before quoting the state of any of them.

## Why "tfvars only"

The value is not tidiness. It is that a QA test **means something**. If QA runs the same modules as prod with different numbers, then QA passing is evidence. If QA runs different code, QA passing is a nice feeling.

## Checklist

- [ ] Modules are written once and composed per environment
- [ ] Environments differ by tfvars, not by code
- [ ] One AWS account per environment
- [ ] Remote state verified separate — in the code, not the comments
- [ ] OIDC trust verified against the branch that actually deploys
- [ ] `prevent_destroy` on every stateful prod resource
- [ ] Nobody has console write access to prod

## You've got it when you can…

…open the three `backend.tf` files and the OIDC trust policy and say, from the code alone, whether the environments are genuinely isolated.
