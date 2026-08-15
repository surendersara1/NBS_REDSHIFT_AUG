# L23 · Set Up Observability From Day One

> **Module 2 · Lesson 23** · ~45 min
> **Slide:** [`_render/L23-observability-from-day-one.html`](_render/L23-observability-from-day-one.html)

## The decision

When is this table late — and who finds out first, you or the business?

Failure alarms are the easy half; every platform ships with them. The hard half is that **nothing fires when a job succeeds on time and produces nothing**. That is the failure that reaches a report, and it is the one you have to design for.

## Do this

1. **Give every table a freshness SLA, expressed as a number the platform can evaluate.** Not "daily by 07:00" in a document — a row in the control plane:

   ```
   entity:  freshness:<table>
   fields:  last_success_at            (written by the pipeline on success)
            expected_within_seconds    (the SLA, per table)
   ```

   The pipeline writes the first field. You choose the second, per table, when you onboard the table — the same pull request, not later.

2. **Alarm on failure AND on lateness.**

   | | Fires when | Answers |
   |---|---|---|
   | **Alarm A — failure** | a run reached a terminal FAILED state | "something broke" |
   | **Alarm B — lateness** | `now − last_success_at > expected_within_seconds` | "nothing broke, and nothing arrived" |

   Alarm B is the one that catches a wedged watermark, an upstream export that stopped being written, and a source that returns an empty page forever.

3. **Route both alarms to a real distribution list.** Not one engineer's inbox, not a channel nobody has joined. Write down who is on the list and confirm at least two of them can act at the hour the alarm can fire.

4. **Make the alert carry the evidence, not just the news.** A useful alert names the **stage**, the **table**, the **cycle**, the recorded error message verbatim, a console link, and the runbook. The recipient should be able to start diagnosing from the email alone.

5. **Write the runbook in the same pull request as the pipeline.** One page per stage: what this stage does, the three most likely causes, the exact command or payload for each recovery, and who is allowed to run it. A runbook written six months later is written from memory and is wrong.

6. **Build the operator view on the control plane, not on log searches.** If the platform records runs (per stage), watermarks, cycle state and lineage, then every operator question is a lookup. Design for these four questions:

   - Did today's cycle complete, and which stage is it on?
   - Which table failed, and what did it say?
   - Did this table's watermark advance, and is the new value plausible?
   - Is this table inside its freshness SLA right now?

7. **Alarm on the things that are not runs, too:** cost against budget, queue depth or dead-letter counts on anything asynchronous, and the age of the oldest in-flight cycle.

## Why

Monitoring is not a dashboard; it is a **promise with a number attached and a person on the other end**. A run that ends green tells you the code did not crash. It does not tell you the data arrived — only a freshness number can do that.

> **What breaks if you don't:** the business tells you the data is stale.

## On Apparel Group

- **One SLA number per table, not one for the platform.** XStore POS lands overnight and has hours of slack; footfall files arrive hourly and go stale in one; Epsilon and MoEngage page against their own cursors and can quietly return nothing. A single platform-wide threshold is wrong for all three.
- **Set the number when you onboard the table** — it is step 6 of L24's procedure, not a follow-up ticket.
- **The SaaS sources need lateness alarms most.** A JDBC pull that cannot reach Oracle fails loudly; an API that returns an empty page succeeds quietly. Alarm B is the only thing watching Epsilon and MoEngage.
- **Route to the workstream, not the individual.** Four workstreams over 12 weeks means the person who wrote the pipeline may not be the person on duty when it breaks.
- Write eight runbooks — one per source — as you onboard, and keep them beside the specs.

**Worked example of the pattern:** the Tamimi control plane's `pipeline_state` freshness entity (`last_success_at` vs `expected_within_seconds`), the per-stage failure notifier that emails the run row itself, and `docs/runbooks/` with one file per stage.

## Checklist

- [ ] Every table has an `expected_within_seconds` value, chosen deliberately
- [ ] A failure alarm and a lateness alarm exist, and both have been tested by firing them
- [ ] Both route to a distribution list with at least two people who can act
- [ ] The alert body names stage, table, cycle, error text, console link and runbook
- [ ] A stage runbook shipped in the same pull request as the stage
- [ ] The operator view answers the four questions above from stored state, not log search
- [ ] Budget, dead-letter and stuck-cycle alarms exist

## You've got it when you can…

- Explain the difference between Alarm A and Alarm B, and name a failure that only Alarm B catches.
- State the freshness SLA of any table on the platform, in seconds, and say who chose it.
- Show, from stored state alone, whether today's cycle completed and which stage it is on.
- Explain why a green run with zero rows is more dangerous than a red one.
- Say why "an alarm that reaches nobody is not monitoring" is a statement about people, not about tooling.
