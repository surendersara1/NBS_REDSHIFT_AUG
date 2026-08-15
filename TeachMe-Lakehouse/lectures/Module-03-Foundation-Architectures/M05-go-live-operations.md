# M05 · Go-Live And Operations

> **Module 3 · Master Flow 05 · Apparel Group · deep dive** · ~20 min

**Diagram:** [`_render/M05-go-live-operations.html`](_render/M05-go-live-operations.html)

## What this pattern is for

Getting from "the platform works" to "the client team runs it".

> **The project is not finished when it works. It is finished when they can fix it without us.**

## The nine steps

**1 · The legacy report keeps running.** It is still the source of truth on day one, and it stays that way until step 5. Nothing is switched off on a promise.

**2 · The new gold layer answers the same question.** Same question, new path. Not a better question, not a redesigned metric — the *same* one, so the comparison in step 3 means something.

**3 · Compare them daily, automatically.** ⭐ Not a spreadsheet somebody maintains. A scheduled job that produces a variance figure every morning, because a manual comparison stops happening in week two, exactly when it starts to matter.

**4 · Every variance is explained, not hidden.** ⭐ Some will be legitimate — a rounding rule you deliberately corrected, a bug in the legacy report. **Write each one down.** An unexplained variance is a blocker; a documented one is a decision. This is where credibility is won or lost.

**5 · Business sign-off, in writing.** ⭐ Not "the numbers look right in the meeting". A named person accepting a documented variance list. This is the gate between QA and production (D20), and it is the one people are tempted to soften.

**6 · Cutover.** The legacy report is switched off. If it stays on "just in case", you now maintain two systems forever and nobody trusts either.

**7 · Alarms go live.** Freshness **and** failure (D26). The freshness alarm is the one that matters — a job that silently stopped is far more dangerous than one that failed loudly.

**8 · The ops console and runbooks.** One console per environment. **One runbook entry per alarm** — what it means, what to check, how to re-run safely. An alarm without a runbook costs the responder twenty minutes of orientation every time.

**9 · Handover.** ⭐ The client team has been through Modules 0–3. The real test: **they handle a nightly failure alone, while we watch.** Not a tabletop exercise — an actual incident, or a deliberately injected one.

## Hypercare has an exit criterion

It is not a duration. It is step 9: the client team resolving a real failure without us intervening. Hypercare defined as "four weeks" simply ends when the money does, whether or not anyone is ready.

## The variance conversation

Step 4 is where projects like this are actually judged. Two rules:

- **Bring variances to them before they find them.** A variance you disclose is diligence; the same variance discovered by the client is a defect.
- **Never explain a variance as "the old report was wrong" without evidence.** Sometimes it is. Prove it with the source data, and get that agreed too.

## Checklist

- [ ] Parallel run compares automatically, daily
- [ ] Every variance is documented and explained
- [ ] Sign-off is written, by a named person
- [ ] Legacy is actually switched off at cutover
- [ ] Freshness alarms as well as failure alarms
- [ ] One runbook entry per alarm
- [ ] Ops console live, per environment
- [ ] The client team has resolved a real failure unaided

## You've got it when you can…

…define "done" for this programme as something the client team demonstrates rather than something we deliver — and hold that line when the date gets tight.
