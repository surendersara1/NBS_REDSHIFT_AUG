# L11 · Reproduce Source Business Rules Faithfully

> **Module 2 · Lesson 11** · ~45 min
> **Slide:** [`_render/L11-reproduce-business-rules.html`](_render/L11-reproduce-business-rules.html)

---

## The decision

**Do you re-implement the source rule, or re-derive it yourself?**

When a number in the source system is produced by logic — a VAT split, a landed cost, a margin, a store classification, a discount hierarchy — you have two ways to get that number into the lakehouse. You can obtain the actual rule and reproduce it. Or you can look at the inputs and outputs and work out what the rule must be.

Only the first is safe. The second produces something that agrees with the source on the rows you sampled and disagrees on the rows you didn't.

There is a third thing people do that is worse than either: reproduce the rule, notice it does something odd, and fix it on the way through. That is how a lakehouse quietly stops agreeing with the system of record — and nobody finds out until a report is challenged in a meeting.

## Do this

1. **Get the rule as an artefact before you write anything.** Source code, a functional spec, or a written statement signed off by whoever owns the number. One of those three. If you cannot obtain any of them, the model is blocked — escalate it as blocked. *Inference is not a rule.*
2. **Reproduce it exactly, including the quirks.** If the source's calculation has an off-by-one, an odd rounding order, or a field it never inspects, and the business already reconciles against that output — reproduce it. A shipped quirk is the accepted answer, not a defect. The pack sizes on the shelf labels and the totals in the existing reports came out of that quirk.
3. **Prove parity with a reconciliation query before anyone builds on it.** Same window, same filters, source total versus lakehouse total, with the acceptable tolerance written down. Get it signed off. This step is the entire point of the lesson — a "faithful port" nobody reconciled is just an assertion.
4. **Refuse to copy a quirk that loses rows.** This is the one deviation you take without hesitation. A rule that silently drops records — an inner join to a lookup that has no matching row, a default filter that excludes a whole document class — is not a rule you can reproduce, because downstream layers stop reading the raw data and the loss becomes unrecoverable. Keep the rows, move the *scoping* decision downstream where it is visible and reversible.
5. **Do not mistake a source idiom for a bug.** Some conventions read as defects to an outsider: an empty selection range that means "no restriction" rather than "no rows", a screen default that is a suggestion rather than a filter. Encoding one of those as a hard filter drops real data. When something looks wrong, ask before you port it.
6. **Record every intentional deviation in two places: the docstring and a test.** The docstring says what you diverged from and why. The test fails if someone later "fixes" it back. One without the other does not hold.
7. **Fail loudly on unknown inputs.** A ported rule that meets a value it does not recognise should raise, not silently fall back to a default. A default is how a typo restores a bug you already removed.

**Worked examples of the pattern:** in `tamimi-lakehouse/src/glue/glue_engine/abap/helpers.py` you can see all three outcomes side by side — a rule reproduced exactly (including its documented off-by-one), a rule that is a derivation rather than a lookup, and a deliberate refusal to reproduce source behaviour that dropped rows. Each one states which it is in its docstring.

## Why

The lakehouse's first obligation is **agreement with the system of record**. Until the numbers match, every improvement you make is indistinguishable from a defect — because the only test anyone can apply is "does it match the system we already trust?"

Parity first. Improvements afterwards, as a named change with its own sign-off and its own communication. That ordering is not bureaucracy; it is what makes an improvement *visible* rather than a mystery discrepancy.

**What breaks if you don't:** "we improved it while porting" is how a lakehouse quietly disagrees with the source — and the disagreement surfaces in a meeting, not in a test.

There is one asymmetry worth internalising, because it decides every hard case:

> **Does the divergence change a number people already reconcile against, or does it lose data you can never get back?**

Reproduce the first kind. Refuse the second kind. Everything else is a judgement call you write down.

## On Apparel Group

**Oracle Retail RMS is decades of embedded business logic.** Pricing, promotions, markdowns, landed cost, intercompany transfer valuation — these are not columns, they are calculations, and many of them have been amended repeatedly by people who have since left. This is exactly the environment where inference feels reasonable and is not.

Concretely, before building any priced or costed model:

- **Get the pricing and costing rules from the people who own them** — the Oracle Retail functional team or DBAs — as code or as a signed statement. Book that conversation in week one; it is a long-lead item, not a detail.
- **Reconcile against RMS itself**, at a stated grain and window, before any downstream model consumes the output.
- **Watch for rules that are time-dependent.** Tax rates, cost methods and promotional logic change on effective dates. A flat constant applied to all history silently misprices every row from before the change.
- **XStore, SIM and Magento each carry their own version of "the price"** — ticket price, promotional price, price actually paid. Name which one each model means, in the model header. In apparel these differ constantly because markdown is the business model.
- **Epsilon loyalty accruals are rules too** — points earned, tier thresholds, expiry. Same treatment: get the rule, reproduce it, reconcile it.

## Checklist

- [ ] I have the rule as code, a spec, or a signed-off written statement
- [ ] I reproduced it exactly, quirks included
- [ ] A reconciliation query exists, with a stated window, grain and tolerance
- [ ] The reconciliation has been run and signed off *before* downstream work started
- [ ] Any quirk I refused to reproduce is one that **loses rows**, and that is stated
- [ ] Every intentional deviation is in the docstring **and** guarded by a test
- [ ] Unknown / unmapped input values raise rather than silently defaulting
- [ ] Time-dependent parameters (rates, costs) are looked up by date, not hardcoded

## You've got it when you can…

…hold both sentences at once — **"we copied the source's quirk on purpose"** and **"we refused to copy the source's quirk"** — and state the rule that decides between them: *does the divergence change a number people already reconcile against, or does it lose data we can never get back?*
