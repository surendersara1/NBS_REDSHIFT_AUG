# D20 · What Gets Promoted

> **Module 3 · Architecture 20 · proposed** · ~15 min

**Diagram:** [`_render/D20-promotion-path.html`](_render/D20-promotion-path.html)

## What it shows

**Code and configuration move forward. Data, credentials and manual fixes do not move at all.**

Most environment confusion comes from being vague about which of those two lists a thing belongs to.

## What moves forward

- Terraform modules and the composed stacks
- The engine wheel — versioned, **built once** (D14)
- Source specs, dbt models, dashboard definitions

## What never moves

- **Data.** Each environment loads its own. Copying prod data into dev is how PII ends up somewhere it is not governed.
- **Credentials.** A separate secret per account. A credential that works in two environments is a credential that will be used in the wrong one.
- **Manual fixes.** If it was not in the plan, it did not happen — and it will be gone at the next apply, usually at the worst moment.

## The gates

**Dev → QA:** unit tests, spec validation, plan reviewed.
**QA → Prod:** UAT sign-off **and numbers reconciled to source**.

That second gate is the one worth defending. "It runs" is not the same as "it is right", and reconciliation is the only evidence that separates them.

## Why QA has to be production-shaped

If QA runs different code, or a tenth of the data, or without the real source connections, then QA passing is a nice feeling rather than evidence. Same modules, bigger values, real connections — that is what makes the QA gate mean something (D13).

## The rule about manual fixes

Worth being blunt, because everyone is tempted at least once:

> **A change made by hand in production is a change that will vanish silently at the next apply — and nobody will connect the outage to it.**

The correct response to an urgent production problem is an urgent pull request, not an urgent console session. If the pipeline is too slow to allow that, fix the pipeline; do not build a habit of bypassing it.

## Checklist

- [ ] Code and config promote; data and credentials do not
- [ ] One artifact built once, promoted unchanged
- [ ] QA has real source connections and realistic volumes
- [ ] The QA gate includes reconciliation, not only "it ran"
- [ ] Production changes only ever arrive through the pipeline
- [ ] A separate secret per environment
- [ ] Nobody has console write access to production

## You've got it when you can…

…be asked to "just fix it in prod, we'll do the PR after" and offer the faster correct path instead — because you already know how long the pipeline takes.
