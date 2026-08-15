# M03 · The Retail Domain Model

> **Module 3 · Master Flow 03 · Apparel Group** · ~15 min

**Diagram:** [`_render/M03-retail-domain-model.html`](_render/M03-retail-domain-model.html)

## What it shows

**Four dimensions and four facts.** Every dashboard the business asks for is a combination of these eight things.

That is worth saying out loud early in a programme, because the request list will look like forty reports. It is eight objects, sliced differently.

## Four dimensions — what you slice by

| | Grain | Fed by | Note |
|---|---|---|---|
| `dim_store` | one row per **version** of a store | Oracle RMS | Type 2 — stores move region |
| `dim_product` | one row per version of an SKU | Oracle RMS | Type 2 — hierarchy changes; pack size parsed |
| `dim_customer` | one row per loyalty member | Epsilon | **PII** — masked at the column |
| `dim_date` | one row per calendar day | generated | fiscal calendar, one timezone, written down |

## Four facts — what you count

| | Grain | Fed by | Note |
|---|---|---|---|
| `fct_sales_line` | one line on one receipt | XStore + Magento | the biggest table by far |
| `fct_stock_daily` | one SKU, store, day | Oracle SIM | **semi-additive — never sum over time** |
| `fct_footfall` | one store, one hour | Vemco + Irisys | two vendors, one grain |
| `fct_campaign` | one engagement event | MoEngage | attribution is a business rule |

## Build the dimensions first

`dim_date` and `dim_store` before anything else, then `dim_product`. Every fact joins to them, so building them first means each subsequent fact is faster than the one before — and building them late means every fact gets reworked.

This is why **wave 1 is Oracle RMS** (M04): it is the reference data everything else attaches to.

## The two traps on this diagram

**`fct_stock_daily` is semi-additive.** Stock on hand of 100 on Monday and 100 on Tuesday is not 200. Summing it over time is the most common wrong number in retail analytics, and it looks completely plausible in a chart.

**`dim_customer` is PII.** It is the only object here that carries a legal obligation. Column-level grants, not a filtered copy (D19).

## Attribution is a business rule, not a technical one

`fct_campaign` joins customers to sales, and *how* it attributes a sale to a campaign — last touch, first touch, a window — is a decision the business makes and signs. Implement whichever they choose; do not choose for them, and do not let it be decided implicitly by whoever writes the SQL.

## Checklist

- [ ] I can name the four dimensions and four facts with their grains
- [ ] I know which dimensions are Type 2 and why
- [ ] I know `fct_stock_daily` is semi-additive
- [ ] I know which object carries PII
- [ ] Dimensions are built before facts
- [ ] Attribution rules are agreed with the business, in writing

## You've got it when you can…

…be handed a list of forty requested reports and map them onto these eight objects — then say which two or three actually need new modelling.
