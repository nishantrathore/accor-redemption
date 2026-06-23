# The Redemption Service — Design Document

**Author:** Nishant Kumar

---

## What this service does and why it matters

The Redemption service handles loyalty point deductions for Accor's global hotel network. Every failed request is a guest who couldn't redeem points at checkout — that's a direct revenue and trust hit. The traffic pattern makes this interesting: mostly quiet, then absolutely slammed during Flash Sales. That combination — low baseline, sudden 10× spikes, zero tolerance for downtime — is what shaped every decision here.

---

## A. Compute & Architecture

I went with EKS on AWS, primarily because EKS gives us a managed control plane — no self-managing etcd, API server HA, or cert rotation. Running Kubernetes on bare EC2 in 2026 just doesn't make sense when the managed option exists.

**The node group split** was the most important infrastructure decision. I'm running two groups:

- **Baseline** — On-Demand `m6i.xlarge`, minimum 3 nodes spread across all three AZs. These never go to zero. The service needs to be responsive immediately, not after waiting 90 seconds for a node to spin up.
- **Burst** — Spot instances (`m6i.xlarge`, `m6a.xlarge`, `m5.xlarge` — three types to reduce interruption risk), min 0, max 30. These absorb Flash Sale traffic and get terminated when things quiet down.

The reason I kept them separate rather than one big auto-scaling group is Spot interruption risk. If everything is Spot and AWS reclaims capacity during a Flash Sale, you're done. The On-Demand baseline guarantees a floor.

**On the cluster itself** — I disabled the public API endpoint. You access the cluster through VPN or a bastion. This removes the API server as an internet attack surface entirely. EKS audit logs go to CloudWatch so there's a full record of every action.

**IMDSv2 is enforced on all nodes** with hop limit 1. Containers can't reach the instance metadata service even if compromised — standard SSRF protection.

---

## B. Scalability

The scaling stack has three layers and each covers a different gap:

**HPA** handles the reactive case — CPU climbs, memory climbs, or requests-per-second breaches 500 per pod. Scale-up stabilisation is zero seconds — I don't want it waiting when traffic is already spiking. Scale-down has a 5-minute window to avoid thrashing after a Flash Sale ends.

**KEDA** covers a gap HPA has: async work. When redemption requests land in SQS, CPU doesn't immediately spike — pods are idle waiting to process. KEDA watches queue depth directly and scales before the CPU load materialises. Configured at one pod per 10 messages.

**Cluster Autoscaler** handles the infrastructure layer — when pods can't schedule because there's no node capacity, it adds Spot nodes. Takes roughly 90 seconds. That's why the baseline On-Demand group matters: the first wave of traffic hits already-running pods while Cluster Autoscaler catches up behind it.

For scheduled Flash Sales — pre-warm manually 10 minutes before. `kubectl scale deployment/redemption --replicas=20` removes the cold-start lag entirely.

3 baseline pods scale to 50 maximum. At current resource requests, that covers roughly 10× the steady-state load with headroom.

---

## C. Security & Networking

The network is a standard three-tier setup but the reasoning matters:

**Public subnets** hold only two things: ALB ENIs and NAT Gateways. No worker nodes. Nodes live in private subnets with no public IPs. Outbound traffic hits per-AZ NAT Gateways — one per AZ, not shared. If you use a single NAT Gateway and that AZ goes down, all pods lose internet access.

**Data subnets** are isolated further. Aurora and Redis security groups only allow inbound on ports 5432 and 6379 from the private subnet CIDRs specifically — not from "the VPC" broadly. Small difference but it matters for blast radius.

**Kubernetes NetworkPolicy** defaults to deny-all, then explicitly allows only what's needed. Redemption pods can reach Aurora, Redis, SQS, DNS, and AWS APIs on 443. Nothing else. If a pod is compromised, lateral movement is contained.

**IRSA** is how pods authenticate to AWS — no access keys, no instance profile abuse. The Redemption service role reads only its own Secrets Manager path (`redemption/*`), consumes only its own SQS queue, and writes metrics only to its own CloudWatch namespace.

**Secrets** never touch the codebase or ConfigMaps. External Secrets Operator syncs from Secrets Manager into Kubernetes secrets. When a DB password rotates in Secrets Manager, pods pick it up without a restart.

WAF sits at both CloudFront and the ALB. OWASP Core Rule Set handles SQLi, XSS, common scanners. Rate limiting prevents any single client from hammering the service during a sale.

---

## D. Reliability & Observability

**What "healthy" looks like:** error rate below 0.1%, p99 latency under 2 seconds, p50 under 300ms.

**The alerts that matter:**

- Error rate above 1% for 5 minutes → pages on-call. Revenue-impact alert.
- p99 above 2 seconds → warning. Visibility before it becomes critical.
- HPA at max replicas for 5 minutes → warning. At capacity ceiling, needs action.
- PDB violated → page. Something is actively wrong with availability.

**Specific failure handling:**

*Bad deployment* — Rolling update with `maxUnavailable: 0` means new pods must pass readiness checks before old ones are removed. If the new image is broken, readiness fails, rollout stops, old pods keep serving. No manual intervention needed.

*AZ outage* — Topology spread constraints force pods across all three AZs. If one AZ disappears, Kubernetes reschedules into the remaining two. PDB ensures we never drop below 70% capacity during reschedule. Aurora fails over automatically in ~30 seconds.

*Spot interruption* — AWS gives 2 minutes notice. Node Termination Handler drains the node in that window. PDB prevents too many pods from being evicted at once.

*Database overload* — Circuit breaker in the app config. If Aurora is struggling, the service fails fast with 503 instead of holding connections open and building latency tails.

**Observability:** Prometheus (Amazon Managed) for metrics, CloudWatch for logs via Fluent Bit, X-Ray for distributed tracing. Grafana shows SLO burn rate — more useful than raw error counts when deciding whether to wake someone up at 2am.

---

## E. Operations

**Reducing toil:**

GitOps with ArgoCD — nobody `kubectl apply`s anything in production manually. A PR merge to main triggers deployment. Rollback is `git revert`. Audit trail is the git log.

Renovate Bot handles dependency updates — Terraform module versions, Helm charts, base images. Without it you end up six months behind on EKS add-on versions without realising it.

Node upgrades are one-click with EKS managed node groups. PDB prevents service disruption during rolling replacement.

The one thing that still needs a human: capacity planning before known large Flash Sale campaigns. Auto-scaling handles surprise spikes fine but for a known event, pre-warming 10 minutes early is just better.

