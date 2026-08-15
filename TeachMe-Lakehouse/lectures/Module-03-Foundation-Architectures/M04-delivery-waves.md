# M04 · Delivery Waves And What Blocks Them

> **Module 3 · Master Flow 04 · Apparel Group** · ~15 min

**Diagram:** [`_render/M04-delivery-waves.html`](_render/M04-delivery-waves.html)

## What it shows

Sources onboarded in four waves, **hardest first** — and the things that actually delay a wave, which are almost never the engineering.

## The four waves

### Wave 1 · Prove it — Oracle RMS
The reference data everything else joins to: product, store, supplier, price. Builds `dim_product` and `dim_store` first, so every later wave has something to attach to.
**Proves:** the engine works, end to end.

### Wave 2 · The volume — SIM and XStore
The two big transactional sources. XStore is the giant and carries the receipt logic (D11). This is where parallelism, cost and the hard-delete question all get answered for real rather than in principle.
**Proves:** it scales, and it reconciles.

### Wave 3 · The APIs — Epsilon and MoEngage
A different connector class: rate limits, cursor paging, no bulk export to fall back on. **Epsilon carries PII, so this wave cannot start until classification and sign-off are done.**
**Proves:** governance actually works.

### Wave 4 · The rest — Magento and footfall
Small volumes, third connector class, unreliable arrival. Deliberately last: by now the landing conventions, alarms and idempotency are proven, so late and duplicate files are harmless.
**Proves:** the ninth source is cheap.

## Why hardest first

Because you want to be wrong **while there is still time to be wrong**.

Doing the easy sources first produces a comfortable burn-up chart and postpones every genuine risk to the end, where there is no slack. Wave 2 is where the architecture either holds or does not; find that out in month two, not month six.

The easy ones at the end are the reward, not the warm-up.

## What blocks waves — and is not ours to fix

| Blocker | Blocks | Start it |
|---|---|---|
| Network path to on-prem Oracle | waves 1–2 | week one (D18) |
| PII classification and legal sign-off | wave 3 | week one |
| SaaS API credentials and quota | wave 3 | week one |
| Source owners agreeing a contract | **everything** | week one |

All four are other people's calendars. Track them as first-class programme items with named owners on the client side, and report on them weekly — not as a risk register entry nobody reads.

## The test at the end of wave 1

Before wave 2 starts, onboard the **second table** in RMS and count the lines of new Python. If it is not close to zero, the seam is wrong (D16) — fix it now, at two tables, not at ninety.

## Checklist

- [ ] Waves are ordered hardest-first, with a reason
- [ ] Wave 1 builds the conformed dimensions
- [ ] Wave 3 is gated on PII sign-off, and everyone knows it
- [ ] All four blockers have named client-side owners
- [ ] The "second table costs zero code" test is run at the end of wave 1
- [ ] Blockers are reported weekly, not buried in a risk log

## You've got it when you can…

…be asked why the smallest source is scheduled last and give the real answer — that the schedule is ordered by risk, not by effort.
