# L22 · Getting to SAP Safely

**Slide:** [`_render/L22-networking-sap-connectivity.html`](_render/L22-networking-sap-connectivity.html)

## The point

SAP is not in AWS. It is on-premises, behind someone else's firewall, reachable only across a shared Transit Gateway. Four things have to be true before a byte moves, and the fourth is the one that surprises application developers:

1. The Glue worker must sit in a subnet whose **route table** points the SAP CIDR at the TGW.
2. The VPC must have an **available attachment** to that TGW (managed out-of-band, by another team).
3. The connection must be **encrypted** — TLS on the JDBC URL *and* on the Glue connection.
4. There must be a **free IP address** in that subnet. This is what caps download concurrency, not CPU and not SAP.

## Key ideas

- **Three subnet tiers, three different exits.** Public (two `/28`s) holds the Internet Gateway and the NAT — no workload of ours runs there. Private (two `/28`s) holds the dbt Glue runner and the Lambdas; it reaches the internet via NAT and reaches AWS APIs through **seven interface endpoints** (`secretsmanager`, `kms`, `glue`, `sts`, `logs`, `sqs`, `monitoring`) so those calls stay on the AWS backbone. Data (three `/26`s) holds Redshift Serverless and every SAP Glue ENI — **no NAT route and no interface endpoints**.
- **The data subnets are deliberately no-egress.** Their route tables carry `local`, the S3 and DynamoDB **gateway** endpoints, and (in Prod) the TGW route to SAP. Nothing else. That is why the Glue jobs bootstrap Python with `--no-index` from a vendored wheel closure in S3 instead of PyPI, and why the DynamoDB gateway endpoint is load-bearing: in QA on 2026-07-21 the `source_download` runs died on connect timeouts to `dynamodb.eu-west-1.amazonaws.com` the moment their ENIs moved into the `/26`s.
- **Interface vs gateway matters.** Gateway endpoints (S3, DynamoDB) are **route-table** entries — free, and they work in a subnet with no NAT. Interface endpoints are **ENIs with a security group** in specific subnets — here, the private ones only. If your workload is in a data subnet and calls Secrets Manager, it is not using an endpoint; check before you assume.
- **Redshift Serverless forces three data subnets in three AZs** ("at least 9 free IPs in 3 subnets, each in a different AZ"). That constraint is why the data tier is three `/26`s, which is also what gives the SAP lanes their address pool.
- **The TGW route is one `aws_route` per route table.** The module fans `route_table_ids × routes` into a keyed map, keyed on route-table **index** rather than id so `for_each` stays known at plan time. It also carries a `lifecycle { precondition }` that checks for an *available* VPC→TGW attachment, because `CreateRoute` toward an unattached TGW fails after ~5 minutes with the misleading `InvalidTransitGatewayID.NotFound` — which is exactly what happened on 2026-07-20 when the network-hub team deleted this account's attachment out of band.
- **Which route table you attach it to is a correctness question, and Prod is the one that got it right.** Dev and QA pass `module.vpc.private_route_table_ids`; Prod passes `module.vpc.data_route_table_ids`. The SAP Glue connections pin their ENIs to the **data** subnets, so those ENIs read the data route tables. On 2026-08-04 every Prod SAP pull timed out at the socket while the private tables carried a SAP route nothing used. There is a second reason too: `modules/vpc` declares `aws_route_table.private` with a **dynamic inline `route` block** for NAT, and mixing inline routes with standalone `aws_route` on the same table is unsupported — each apply reconciles one and strips the other. `aws_route_table.data` has no inline routes, so standalone routes stick.
- **Blast radius shrinks per environment.** Dev routes `172.30.1.0/24` **and** `172.30.0.0/16`; QA routes only the `/24`; Prod routes a single host, `172.30.5.45/32`. The audit's HIGH-19 was that the original config routed `172.16.0.0/12` and `192.168.0.0/16` on-prem — nearly the whole private address space, in both directions. Those are gone; Dev's `/16` is the remaining "partial".
- **TLS on the JDBC path is two switches, not one.** The URL must carry `?encrypt=true&validateCertificate=true` *and* the Glue connection must set `JDBC_ENFORCE_SSL = "true"`. Before HIGH-09, the extractor defaulted to `encrypt=False, sslValidateCertificate=False` and the connection shipped with `JDBC_ENFORCE_SSL="false"` — SAP ERP credentials and full sales/customer extracts crossing the TGW in cleartext. The prerequisite nobody skips: the HANA server certificate has to be in the Glue connection's truststore or validation fails.
- **VPC flow logs exist now (HIGH-08).** VPC-scope, `traffic_type = "ALL"`, to a CloudWatch log group with 90-day retention and its own delivery role. `flow_log_kms_key_arn` defaults to `""` — no env passes a CMK today, so the group uses CloudWatch's default encryption. Worth knowing when someone asks "are the flow logs CMK-encrypted?": the wiring is there, the value is not.
- **The ENI budget is the real concurrency ceiling.** A `/26` gives 59 usable addresses. Each Glue worker consumes one, and Glue's ENI teardown lags a finished run by 1–2 minutes. The P1 download therefore runs **3 lanes** — three Glue connections pinned to `data-0/1/2` — with `max_concurrent_runs = 2` per lane and `G.2X × 12` workers. `3 × 2 × 12 ≈ 24 ENIs` at peak, ~35 free. The Step Functions `Map` sets `MaxConcurrency = 6`, which **must** equal the sum of the lanes' `max_concurrent_runs`, or a retry stacks an extra run onto a subnet instead of queueing on the pool. Overshoot and chunks die with `Number of IP addresses on subnet is 0`.
- **`max_retries = 0` on the download jobs is part of the same budget.** A Glue-*internal* retry starts `<run>_attempt_1` without passing through `StartJobRun`, so it ignores the Map's lane budget and stacks another 12 ENIs. Retry lives only in the Map's `Retry` block, which re-issues `StartJobRun` and therefore honours the pool.
- **There is a second, softer ceiling:** `MaxConcurrency × max(jdbc_hash_partitions)` is the concurrent HANA connection count. Specs cap `jdbc_hash_partitions ≤ 8`, so `6 × 8 = 48` of a ~64 connection budget — well under the ~160 AWS→on-prem trip point observed on 2026-07-15.

## Words you'll hear

| Word | What it means here |
|---|---|
| ENI | Elastic Network Interface — one private IP; every Glue worker takes one |
| Gateway endpoint | A route-table entry for S3/DynamoDB; works with no NAT, costs nothing |
| Interface endpoint | An ENI + SG in named subnets; here, private subnets only |
| TGW | Transit Gateway — the shared hub that reaches on-prem SAP |
| Attachment | The VPC↔TGW link; owned by the network-hub account, not by us |
| Lane | One Glue connection pinned to one data subnet; three of them spread the ENIs |
| `MaxConcurrency` | The Step Functions `Map` fan-out cap; must equal the sum of lane run caps |
| Flow log | A record of accepted/rejected traffic; forensics after the fact |

## In this repo

- [`infra/modules/vpc/main.tf:18-53`](../../../tamimi-lakehouse/infra/modules/vpc/main.tf) — the three subnet tiers; `:112-148` the private route tables (inline NAT route) versus the bare data route tables; `:153-186` the S3 and DynamoDB gateway endpoints, with the QA incident note; `:193-230` the interface endpoints and their `:443`-from-VPC security group; `:236-300` the HIGH-08 flow-log stack.
- [`infra/modules/vpc/variables.tf:41-72`](../../../tamimi-lakehouse/infra/modules/vpc/variables.tf) — `enable_flow_logs`, `flow_log_kms_key_arn` (default `""`), and the seven `interface_endpoint_services`.
- [`infra/env/dev/terraform.tfvars:3-12`](../../../tamimi-lakehouse/infra/env/dev/terraform.tfvars) — the CIDR plan, including why three data subnets exist; `:55-69` the TGW routes with the HIGH-19 comment.
- [`infra/env/prod/terraform.tfvars:46-55`](../../../tamimi-lakehouse/infra/env/prod/terraform.tfvars) — Prod's `/32`, and why Prod must not path to non-prod SAP.
- [`infra/env/prod/main.tf:642-666`](../../../tamimi-lakehouse/infra/env/prod/main.tf) — the two-reason comment for routing on the **data** tables. The best 15 lines of networking prose in the repo.
- [`infra/modules/tgw-route/main.tf:43-79`](../../../tamimi-lakehouse/infra/modules/tgw-route/main.tf) — the attachment `precondition` and its error message.
- [`infra/env/dev/sap_hana_source_download.tf:90-108`](../../../tamimi-lakehouse/infra/env/dev/sap_hana_source_download.tf) — `JDBC_CONNECTION_URL`, `SECRET_ID`, `JDBC_ENFORCE_SSL = "true"` and the `physical_connection_requirements` block that places the ENI.
- [`infra/env/dev/main.tf:410-451`](../../../tamimi-lakehouse/infra/env/dev/main.tf) — the `sap-hana` / `sap-hana-lane1` / `sap-hana-lane2` Glue connections and the `/28`-exhaustion story that moved them onto the `/26`s.
- [`infra/env/dev/glue_sources.tf:113-181`](../../../tamimi-lakehouse/infra/env/dev/glue_sources.tf) — the three lane job definitions with the ENI arithmetic in the comments.
- [`infra/env/dev/source_download.tf:40-68`](../../../tamimi-lakehouse/infra/env/dev/source_download.tf) — `MaxConcurrency = 6` and the measured reason it dropped from 9.
- [`docs/handoff/audit_deep_analysis.md:197-209`](../../../tamimi-lakehouse/docs/handoff/audit_deep_analysis.md) — HIGH-08 and HIGH-09 as written by the auditor.

## Do this

1. Draw the Dev VPC from `terraform.tfvars` alone: `10.248.4.0/24` split into two public `/28`s, two private `/28`s, three data `/26`s. Mark which tiers have a NAT route, which have gateway endpoints, and which have interface endpoints.
2. Answer this without running anything: a Lambda in a **private** subnet calls Secrets Manager — does the traffic leave the VPC? Now the same call from a Glue worker in a **data** subnet. (The second one has no path at all.)
3. Open `infra/env/dev/main.tf` and `infra/env/prod/main.tf` at their `module "sap_tgw_route"` blocks. One argument differs. Explain both reasons Prod gives, then decide whether Dev should change.
4. Do the ENI arithmetic yourself for a hypothetical fourth lane on a `/28` instead of a `/26`, and say at which worker count it breaks.
5. Grep for `JDBC_ENFORCE_SSL` and `encrypt=` across `infra/` and `scripts/`. Both switches must agree — find any place they do not.

## You've got it when you can…

…name the four preconditions for a SAP pull (**route on the right table, an available TGW attachment, TLS on both switches, and a free IP**), explain why Prod puts the TGW route on the data route tables and Dev does not, and derive `MaxConcurrency = 6` from first principles: `59 usable IPs per /26 → 3 lanes × 2 runs × 12 workers ≈ 24 ENIs, with headroom for teardown lag.`
