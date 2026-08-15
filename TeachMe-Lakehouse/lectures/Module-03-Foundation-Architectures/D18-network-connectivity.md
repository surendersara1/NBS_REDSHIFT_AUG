# D18 · Reaching The On-Prem Sources

> **Module 3 · Architecture 18 · proposed** · ~15 min

**Diagram:** [`_render/D18-network-connectivity.html`](_render/D18-network-connectivity.html)

## What it shows

How Glue reaches three Oracle databases sitting in Apparel Group's data centre, with **nothing exposed to the internet in either direction**.

> **The network path is procured, not coded. It has weeks of lead time.**
> Raise it in week one or it becomes the critical path in week nine.

That sentence is the reason this diagram exists at all. It is the most common cause of slippage on projects of this shape, and it is entirely predictable.

## The path

**Their side.** Three Oracle databases behind a corporate firewall, governed by their change process — which is another lead time, and another team's calendar.

**The link.** Direct Connect or Site-to-Site VPN into a gateway that routes into our VPC.

**Private subnets.** No internet gateway, no public IPs. The **Glue connection runs on an ENI inside the subnet**, which is what lets a serverless job reach a private database at all — and it is the piece people are surprised by.

**Credentials.** Secrets Manager, never in job parameters or a spec file.

**Egress.** A NAT gateway for patching only — not a data path.

**VPC endpoints.** S3, Glue, Secrets Manager and DynamoDB reached **without traversing the internet**. This matters for both security posture and data-transfer cost (D29).

**Flow logs.** So "who talked to whom" is answerable afterwards.

## The three things to start in week one

1. **The network request itself** — the long pole, and not ours to expedite.
2. **Firewall rules on their side** — their change process, their calendar.
3. **A test credential and a single reachable table** — so that the day the link comes up, you can prove it in ten minutes rather than starting to debug.

That third one is the trick worth remembering. Teams wait for the link, then spend a week discovering credentials are wrong.

## Why no public path, ever

Not policy for its own sake. A publicly reachable database is a database that will eventually be reached by someone else, and the discussion after that is not a technical one.

Private subnets plus endpoints also mean traffic to S3 and Glue never leaves the AWS network, which is cheaper as well as safer.

## Checklist

- [ ] Network request raised in week one, with a named owner on their side
- [ ] Glue connection configured with subnet and security group
- [ ] Credentials in Secrets Manager, referenced not embedded
- [ ] VPC endpoints for S3, Glue, Secrets Manager, DynamoDB
- [ ] No public IPs and no internet gateway on the data subnets
- [ ] NAT is egress-only, and not on the data path
- [ ] Flow logs enabled
- [ ] A single table proven reachable the day the link is up

## You've got it when you can…

…sit in a kickoff and identify the network path as the critical path before anyone has written a line of code — and name the three things to start that morning.
