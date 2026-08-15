# M02 · Source To Dashboard, Traced

> **Module 3 · Master Flow 02 · Apparel Group** · ~15 min · ⭐ **the argument-ender**

**Diagram:** [`_render/M02-source-to-dashboard.html`](_render/M02-source-to-dashboard.html)

## What it shows

**"Where does this number come from?"** — answered for all eight sources, one row each, left to right:

```
source  →  lands as  →  silver entity  →  gold mart  →  the question it answers
```

## The eight rows

| Source | Lands as | Silver entity | Gold mart | Answers |
|---|---|---|---|---|
| Oracle RMS | `bronze.rms_*` | product, supplier, price | `dim_product` | margin, assortment |
| Oracle SIM | `bronze.sim_*` | stock position, movement | `fct_stock_daily` | availability, shrinkage |
| Oracle XStore | `bronze.xstore_*` | receipt, sale line, tender | `fct_sales_line` | sales, basket, VAT |
| Epsilon **(PII)** | `bronze.epsilon_*` | customer, loyalty member | `dim_customer` | loyalty, retention |
| MoEngage | `bronze.moengage_*` | campaign, engagement | `fct_campaign` | campaign response |
| Magento | `bronze.magento_*` | online order, web customer | `fct_sales_line` | online vs store |
| Vemco footfall | `bronze.vemco_*` | store visit count | `fct_footfall` | conversion rate |
| Irisys footfall | `bronze.irisys_*` | store visit count | `fct_footfall` | conversion rate |

## Two things to notice

**Two sources land in one fact.** XStore and Magento both feed `fct_sales_line` — that is deliberate, and it is how "online vs store" becomes a filter rather than a separate report. Same for the two footfall vendors feeding `fct_footfall`: **two vendors, one grain, conformed**.

**`dim_store` and `dim_date` are conformed.** Every fact above joins to the same two. Without that, two marts that both report "sales by region" will disagree structurally — and the disagreement will not look like a bug, it will look like an argument.

## Why this diagram ends arguments

When a figure is questioned in a meeting, you follow its row back to the system that produced it. Three consequences:

1. The conversation becomes **"is the source right?"** rather than "is your pipeline right?" — a different and usually shorter conversation.
2. **Impact analysis is visual.** If RMS changes, look down its row.
3. **Ownership is visible.** Every number has a source system, and every source system has an owner (M01, phase 1).

## Keep it current

This is the diagram that rots fastest, because it changes every time a mart is added. **Update it in the same PR that adds the mart.** A traceability diagram that is six months stale is worse than none — people trust it and are wrong.

## Checklist

- [ ] I can trace any gold table back to its sources
- [ ] I know which two sources share `fct_sales_line` and why
- [ ] I know the two conformed dimensions and what they prevent
- [ ] I know which row carries PII
- [ ] The diagram is updated in the PR that changes the model

## You've got it when you can…

…be challenged on a number in front of a client and walk its row backwards to the source system — turning a credibility question into a data question.
