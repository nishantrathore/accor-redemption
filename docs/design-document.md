# The Redemption Service — Design Notes

**Author:** Nishant Rathore  
**Role:** Lead SRE  
**Date:** June 2026

---

## What this service does and why it matters

The Redemption service handles loyalty point deductions for Accor's global hotel network. Every failed request is a guest who couldn't redeem points at checkout — that's a direct revenue and trust hit. The traffic pattern makes this interesting: mostly quiet, then absolutely slammed during Flash Sales. That combination — low baseline, sudden 10× spikes, zero tolerance for downtime — is what shaped every decision here.

---

## A. Compute & Architecture

I went with EKS on AWS, primarily because the team already has AWS expertise and EKS gives us managed control plane upgrades without the pain of doing it ourselves. Running Kubernetes on bare EC2 in 2026 doesn't make sense when EKS handles etcd, API server HA, and cert rotation for us.

**The node group split** was the most important infrastructure decision. I'm running two groups:

- **Baseline** — On-Demand `m6i.xlarge`, minimum 3 nodes spread across all three AZs. These never go to zero. The Redemption service needs to be responsive immediately, not after waiting for a node to spin up.
- **Burst** — Spot instances (`m6i.xlarge`, `m6a.xlarge`, `m5.xlarge` — three types to reduce interruption risk), min 0, max 30. These absorb Flash Sale traffic and get terminated when things quiet down.

The reason I kept them separate rather than just one big auto-scaling group is the Spot interruption risk. If everything is Spot and AWS reclaims capacity during a Flash Sale, you're in trouble. The On-Demand baseline guarantees a floor.

**On the cluster itself** — I disabled the public API endpoint. You access the cluster through VPN or a bastion. This removes the API server as an internet attack surface entirely. EKS audit logs go to CloudWatch so we have a full record of who did what.

**IMDSv2 is enforced on all nodes** with hop limit 1. This means containers can't reach the instance metadata service even if compromised — classic SSRF protection.

---

## B. Scalability

The scaling stack has three layers and they each cover a different failure mode:

**HPA (Horizontal Pod Autoscaler)** handles the reactive case — CPU climbs, memory climbs, or requests-per-second breaches 500 per pod. Scale-up stabilisation is zero seconds. I don't want it waiting when traffic is spiking. Scale-down has a 5-minute window to avoid thrashing after a Flash Sale ends.

**KEDA** covers a gap HPA has: async work. When guests submit redemption requests that go into SQS, CPU doesn't immediately spike — the pods are idle waiting to process. KEDA watches queue depth directly and scales before the CPU load materialises. One pod per 10 messages in the queue.

**Cluster Autoscaler** handles the infrastructure layer — when pods can't schedule because there's no capacity, it tells the ASG to add Spot nodes. Takes roughly 90 seconds end-to-end. That's why the baseline On-Demand group matters: the first wave of traffic hits running pods, Cluster Autoscaler catches up behind it.

One thing I'd add for future: for scheduled Flash Sales we know are coming, we should pre-warm manually. The runbook is just `kubectl scale deployment/redemption --replicas=20` 10 minutes before the event. Removes the cold-start completely.

The numbers: 3 baseline pods scale to 50 maximum. At our current resource requests that covers roughly 10× the steady-state load with headroom.

---

## C. Security & Networking

The network is a standard three-tier setup but I want to explain the reasoning, not just list it:

**Public subnets** have only two things: ALB ENIs and NAT Gateways. No worker nodes, ever. Nodes live in private subnets with no public IPs. Outbound traffic hits per-AZ NAT Gateways (one per AZ — if you use a single NAT Gateway and that AZ goes down, all your pods lose internet access).

**Data subnets** are isolated further. Aurora and Redis security groups only allow inbound on ports 5432 and 6379 from the private subnet CIDRs. Not from "the VPC" — specifically the private CIDRs. Small difference but it matters.

**Network Policies** in Kubernetes default-deny everything and then explicitly allow what's needed. The redemption pods can reach Aurora, Redis, SQS, DNS, and AWS APIs on 443. Nothing else. If a pod gets compromised, the blast radius is contained.

**IRSA (IAM Roles for Service Accounts)** is how pods authenticate to AWS — no access keys, no instance profile abuse. The Redemption service role can only read its own Secrets Manager path (`redemption/*`), consume its own SQS queue, and write to its own CloudWatch namespace. The Cluster Autoscaler role can only modify ASGs tagged with this cluster's name.

**Secrets Management** — credentials never touch the codebase or ConfigMaps. External Secrets Operator syncs from Secrets Manager into Kubernetes secrets on a schedule. When we rotate a DB password in Secrets Manager, pods pick it up without a restart.

The WAF sits at both CloudFront (edge) and ALB (regional). OWASP Core Rule Set blocks the obvious stuff — SQLi, XSS, common scanners. Rate limiting prevents a single client from hammering us during a Flash Sale.

---

## D. Reliability & Observability

**What "healthy" looks like:** error rate below 0.1%, p99 latency under 2 seconds, p50 under 300ms. These are the numbers I'd commit to in an SLA conversation.

**The alerts I actually care about:**

- Error rate above 1% for 5 minutes → pages on-call. This is the revenue-impact alert.
- p99 above 2 seconds → warning, not page. Gives the team visibility before it becomes critical.
- HPA at max replicas for 5 minutes → warning. Means we're at capacity ceiling and need to either raise `maxReplicas` or provision more nodes.
- PDB violated → page. Means something is actively wrong with availability.

**How we handle specific failures:**

*Bad deployment* — Rolling update with `maxUnavailable: 0` means new pods have to pass readiness checks before old ones are removed. If the new image is broken, readiness fails, rollout stops, and old pods keep serving. No manual intervention needed. The startup probe gives containers 60 seconds to initialise before the liveness probe takes over.

*AZ outage* — Topology spread constraints force pods across all three AZs. If one AZ disappears, Kubernetes reschedules those pods into the remaining two. The PDB ensures we never go below 70% capacity even during a messy reschedule. Aurora fails over automatically in ~30 seconds; the app uses exponential backoff with jitter on retries.

*Spot interruption* — AWS gives 2 minutes notice. Node Termination Handler drains the node gracefully in that window. The PDB prevents too many pods from being evicted simultaneously.

*Database overload* — Circuit breaker is enabled in the app config. If Aurora is struggling, the service fails fast with 503 instead of holding connections and building latency tails.

**Observability stack:** Prometheus (Amazon Managed) for metrics, CloudWatch for logs (Fluent Bit DaemonSet ships them), X-Ray for distributed tracing across the point deduction flow. Grafana dashboards show the SLO burn rate — that's more useful than raw error counts when you're trying to decide whether to wake someone up at 2am.

---

## E. Operations

**Day-to-day toil reduction:**

The main thing is GitOps with ArgoCD. Nobody `kubectl apply`s anything manually in production. A PR merge to main triggers a deployment. Rollback is `git revert`. The audit trail is the git log.

Renovate Bot handles dependency updates — Terraform module versions, Helm chart versions, base image updates. PRs come in automatically, pass CI, get reviewed. Without this you end up six months behind on EKS add-on versions.

Node upgrades are one-click in EKS managed node groups. PDB prevents service disruption during the rolling replacement. We've tested this — it works.

The one thing that still requires a human: capacity planning before major Flash Sale campaigns. The auto-scaling handles surprise spikes but for a known big event, pre-warming is better than relying on the 90-second autoscaler loop.

---

## Team Delegation

**The team:** one Senior (me), two Junior engineers.

I thought about this practically — what can I delegate confidently without creating a review bottleneck on my end?

**Sprint 1 — Infrastructure foundations**

| Task | Owner | Reasoning |
|------|-------|-----------|
| VPC, subnets, NAT Gateways, routing | Junior 1 | Well-defined, low ambiguity, good AWS fundamentals exercise |
| Aurora, ElastiCache, SQS (Terraform) | Junior 2 | RDS/ElastiCache modules are well-documented, manageable scope |
| EKS cluster + node groups | Senior | Too many moving parts (VPC integration, KMS, IAM) to delegate safely in sprint 1 |
| IAM roles, IRSA, KMS | Senior | Security-critical; a mistake here has blast radius across everything |

**Sprint 2 — Application layer**

| Task | Owner | Reasoning |
|------|-------|-----------|
| Deployment, Service, ConfigMap, PDB | Junior 1 | Foundational K8s; reviewable in one pass |
| Monitoring — ServiceMonitor, PrometheusRules, Grafana dashboards | Junior 2 | Observable, well-defined; gives them ownership of a complete feature |
| HPA, KEDA, Network Policies, Ingress | Senior | Scaling interactions and security posture need senior judgement |

**Sprint 3 — Hardening and CI/CD**

| Task | Owner | Reasoning |
|------|-------|-----------|
| ArgoCD setup, GitOps repo structure | Junior 1 | Guided by Senior; well-documented tooling |
| GitHub Actions pipeline (build, scan, push, deploy) | Junior 2 | Builds on previous ECR work; good end-to-end ownership |
| External Secrets Operator + secret sync | Senior | Security architecture decision |
| Load testing (k6) + SLO validation | All three | Full team; validates everything we built |
| Runbooks + incident playbooks | All three | Shared operational ownership from day one |

The juniors get complete vertical slices — not just "write this Terraform file" but "own this feature end to end." That's how they actually grow, and it reduces the back-and-forth review load on me.

---

## Trade-offs I'd flag in a review

**Spot for burst:** The risk is AWS reclaiming capacity exactly when you need it most — during a large Flash Sale that's also causing a region-wide Spot crunch. The mitigation is three instance types and the On-Demand baseline. I'm comfortable with this trade-off but it's worth monitoring Spot interruption frequency as traffic grows.

**Single region:** This design is single-region. For a truly global service with Accor's footprint, you'd want active-active across at minimum two regions with Route 53 latency routing. That's a significant jump in complexity and cost — I'd want a business case conversation before going there.

**Aurora vs RDS PostgreSQL:** Aurora costs more. The justification is faster failover (~30s vs ~60-120s for RDS), the read replica configuration for query offloading, and the operational simplicity of the Aurora serverless option if we ever want to go that direction. Worth revisiting if costs become a concern.

**Private EKS endpoint only:** Means you need VPN or a bastion to run kubectl commands. Slightly more friction for developers. I consider this a feature, not a bug — you don't want engineers accidentally running commands against production from a coffee shop.
