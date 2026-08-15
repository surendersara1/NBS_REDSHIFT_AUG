# L22 · Connect to On-Prem Sources Safely

> **Module 2 · Lesson 22** · ~45 min
> **Slide:** [`_render/L22-connect-to-on-prem.html`](_render/L22-connect-to-on-prem.html)

## The decision

Your compute is in AWS. Oracle is not — it is on-premises, behind someone else's firewall, reachable only over a shared link. Four things must be true before a byte moves, and the fourth is the one that surprises application developers:

1. The worker sits in a subnet whose **route table** points the source CIDR at the link.
2. The link has an **available attachment** to your VPC.
3. The session is **encrypted** — and that is two switches, not one.
4. There is a **free IP address** in that subnet.

Number four is what caps your download concurrency. Not CPU, not the database.

## Do this

1. **Three subnet tiers, three different exits.**

   | Tier | Holds | Reaches the internet | Reaches AWS APIs |
   |---|---|---|---|
   | Public | NAT and the internet gateway only | yes | — |
   | Private | orchestration Lambdas, transform runner | via NAT | interface endpoints |
   | Data | JDBC worker ENIs, the warehouse | **no route** | gateway endpoints only |

   No workload of yours runs in the public tier.

2. **Use interface endpoints instead of NAT for AWS APIs.** Secrets Manager, KMS, STS, logs, the catalog, queues, metrics — put an interface endpoint in the private subnets so those calls stay on the AWS backbone.

   Know the difference, because it decides what works where:
   - **Gateway endpoints** (object storage, the key-value store) are route-table entries. Free, and they work in a subnet with no NAT.
   - **Interface endpoints** are ENIs with a security group, in *named* subnets. A workload in a subnet without one has no path at all — it does not silently fall back.

3. **Route only the specific source CIDR.** One route per source, as narrow as the source team will give you. A `/32` to a single Prod database host is better than a `/24`; a `/16` or a `/12` is a routing decision you will be asked to justify in a security review.

4. **Enforce TLS twice.** The URL and the connection object must agree, and the server certificate must be in the connection's truststore or validation fails:

   ```
   jdbc:oracle:thin:@…?ssl_server_dn_match=true
   JDBC_ENFORCE_SSL = "true"
   ```

   Grep for both switches across your infrastructure and your job code, and find any place they disagree.

5. **Size the subnet against the ENI count, then cap concurrency to match.** This is arithmetic, and you should do it before you pick a CIDR.

   ```
   a /26 subnet          → 59 usable addresses
   each worker           → 1 ENI
   ENI teardown lags a finished run by 1–2 minutes

   peak ENIs = lanes × concurrent runs per lane × workers per run
             = 3     × 2                        × 12
             ≈ 72 … too many for one /26 — spread across three, or reduce workers
   ```

   Then set the orchestrator's fan-out cap equal to the sum of the lanes' per-lane run caps. If those two numbers disagree, a retry stacks an extra run onto a subnet instead of queueing on the pool.

6. **Turn off engine-internal retries on the download jobs.** An internal retry starts a second attempt without passing back through the scheduler, so it ignores your concurrency budget and stacks another full set of ENIs. Put retry in the orchestrator, where it re-issues through the same gate.

7. **Watch the second, softer ceiling too:** `fan-out cap × max JDBC partitions per table` is your concurrent connection count against the source. Keep it comfortably under whatever the source DBA will admit to.

8. **Enable VPC flow logs from day one**, all traffic, with a retention period someone has agreed to. You will want them the first time a connection is refused and both teams believe it is the other's firewall.

## Why

The database is rarely the first thing to give out. The subnet is. And when it does, the error surfaces at the driver — a connect timeout, a socket failure — so the first hour goes to the DBA and the second hour goes to the network, and neither of them changed anything.

> **What breaks if you don't:** jobs die on zero free IPs, not on the query.

## On Apparel Group

- **RMS, SIM and XStore all cross the same on-prem link.** Size the plan for XStore — POS transactions are the giant — and let the RMS masters ride along.
- **Route each source CIDR separately.** Three narrow routes are easier to defend and easier to revoke than one broad one, and they let you cut a single source without touching the others.
- **Epsilon, MoEngage and Magento are not on-prem** — they are public API egress. That is a different path (NAT or a proxy), a different security group, and a different set of failure modes. Don't design one network rule for both halves of the source list.
- **Do the ENI arithmetic for XStore before you choose subnet sizes.** Changing a subnet CIDR after Redshift and a dozen Glue connections are pinned to it is not a small change.
- Footfall feeds (Vemco, Irisys) are small file/API pulls — no lanes, no ENI budget, no special routing.

**Worked example of the pattern:** the Tamimi `infra/modules/vpc` (three tiers, gateway + interface endpoints, flow logs) and its lane definitions, where the per-lane worker counts are written next to the ENI arithmetic that justifies them.

## Checklist

- [ ] Compute runs in private or data subnets — never public
- [ ] Interface endpoints exist for every AWS API the workload calls from a private subnet
- [ ] Data-tier subnets have no default route, and you know exactly what they can reach
- [ ] Exactly one route per source CIDR, each as narrow as the source allows
- [ ] TLS enforced on both the URL and the connection object; server cert in the truststore
- [ ] Peak-ENI arithmetic written down, and the subnet sized above it
- [ ] Orchestrator fan-out cap equals the sum of per-lane run caps
- [ ] Engine-internal retries disabled on download jobs; retry lives in the orchestrator
- [ ] Flow logs enabled with an agreed retention

## You've got it when you can…

- Name the four preconditions for an on-prem pull: **a route on the right table, an available attachment, TLS on both switches, and a free IP.**
- Answer without running anything: a function in a private subnet calls Secrets Manager — does that traffic leave the VPC? Same call from a data subnet — what happens?
- Derive a fan-out cap from first principles, starting at usable addresses per subnet.
- Explain why an internal engine retry breaks a concurrency budget that the orchestrator's retry does not.
- Say, for each of the 8 Apparel Group sources, whether it crosses the on-prem link or goes out to the internet.
