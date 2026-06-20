# The Redemption Service — Cloud Architecture Design Document
### Accor · Cloud Engineer Technical Assessment · June 2026

---

## Executive Summary

This document describes the production-grade AWS architecture for **"The Redemption"** — a business-critical microservice that handles global hotel loyalty-point deductions for Accor. The design is optimized for three non-negotiable constraints: **zero downtime**, **automatic 10× traffic spike absorption**, and **defence-in-depth security** for cardholder/loyalty data.

---

## A. Compute & Architecture

### EKS Cluster Design

| Layer | Choice | Rationale |
|-------|--------|-----------|
| Container orchestrator | AWS EKS 1.29 | Managed control plane; reduces ops toil for upgrades and HA |
| Compute baseline | On-Demand `m6i.xlarge` × 3 nodes (one per AZ) | Predictable performance for steady-state traffic; protected from Spot interruptions |
| Compute burst | Spot `m6i.xlarge / m6a.xlarge / m5.xlarge` × 0–30 nodes | 60–70% cost saving for ephemeral Flash Sale capacity |
| Runtime | Amazon Linux 2 EKS-optimized AMI, IMDSv2 enforced | Removes IMDS v1 SSRF vector; CIS benchmark baseline |
| Secret encryption | KMS-backed envelope encryption of Kubernetes secrets at rest | Prevents offline cluster-state compromise |
| Private cluster | `endpoint_public_access = false` | API server not reachable from the internet; accessed only via VPN/bastion |

### High-Availability Controls

- **Pod Topology Spread**: `maxSkew: 1` on both `topology.kubernetes.io/zone` and `kubernetes.io/hostname`, ensuring no single AZ or node hosts more than one extra pod.  
- **Pod Anti-Affinity**: `requiredDuringScheduling` rule prevents two `redemption` pods from sharing the same node.  
- **Rolling Update**: `maxUnavailable: 0` / `maxSurge: 2` guarantees zero downtime during deployments.  
- **PodDisruptionBudget**: `minAvailable: 70%` protects against simultaneous node drains (e.g., AZ maintenance).  
- **Pre-stop hook + terminationGracePeriodSeconds: 60**: in-flight requests complete before pod removal; ALB deregistration delay set to 60 s.

---

## B. Scalability Strategy

### Two-Layer Auto-scaling

```
Traffic spike detected
        │
        ▼
 HPA evaluates CPU / memory / RPS
 KEDA evaluates SQS queue depth
        │
        ▼
 Pod count scales 3 → 50 (within 15 s)
        │
        ▼
 Cluster Autoscaler detects Pending pods
        │
        ▼
 Burst Spot node group scales 0 → 30 (within ~90 s)
```

#### Horizontal Pod Autoscaler (HPA)
| Parameter | Value | Reason |
|-----------|-------|--------|
| `minReplicas` | 3 | One per AZ at all times |
| `maxReplicas` | 50 | Supports 10× baseline traffic with headroom |
| CPU target | 60% | Leaves buffer for bursty workloads |
| Scale-up stabilisation | 0 s | Immediate response to spikes |
| Scale-down stabilisation | 300 s | Avoids flapping after Flash Sale ends |

#### KEDA (Kubernetes Event-Driven Autoscaling)
- Trigger: SQS `redemption-jobs` queue depth; scales 1 pod per 10 messages.
- Complements HPA for async workloads that do not generate CPU load immediately.

#### Cluster Autoscaler
- Tagged node groups with `k8s.io/cluster-autoscaler/enabled = true`.
- Spot node group uses three instance-type substitutes to minimise interruption probability.
- Spot interruption handling: AWS Node Termination Handler drains nodes gracefully on 2-minute ITN notice.

### Flash Sale Pre-warming (Day-2 Runbook)
For scheduled Flash Sales, the SRE team can pre-scale the Deployment and warm the burst node group via:
```bash
kubectl scale deployment/redemption -n redemption --replicas=20
```
This avoids the ~90 s cold-start penalty for the first wave of requests.

---

## C. Security & Networking

### Network Architecture (Defence-in-Depth)

```
Internet
    │  HTTPS 443 only
    ▼
CloudFront + WAF (OWASP managed rule set)
    │
    ▼
Application Load Balancer (public subnets — ACM TLS termination)
    │  HTTP → private subnets
    ▼
EKS Worker Nodes (private subnets — no public IPs)
    │
    ▼
Aurora PostgreSQL / ElastiCache Redis (isolated data subnets)
```

**Three-tier subnet isolation:**
- **Public**: Only ALB ENIs and NAT Gateways. No worker nodes.
- **Private**: EKS nodes. No inbound from internet. Outbound via per-AZ NAT Gateways (redundant).
- **Data**: Aurora and Redis. Security Groups allow only port 5432/6379 from Private subnet CIDRs.

### Kubernetes Network Policies
1. **Default-deny all** ingress and egress for the `redemption` namespace.
2. Explicit allow rules for:
   - ALB controller → pods (port 8080)
   - Pods → Aurora (5432), Redis (6379), SQS/AWS APIs (443), DNS (53)
   - Prometheus → pods scraping (9090)

### Identity & Access
| Principal | Mechanism | Scope |
|-----------|-----------|-------|
| Redemption pods | IRSA (IAM Roles for Service Accounts) | Secrets Manager (own path), SQS read, CloudWatch PutMetricData |
| Cluster Autoscaler | IRSA | Describe/Set ASG, tag-scoped to this cluster |
| Nodes | Instance Profile | ECR pull, SSM (no SSH needed), EBS CSI |
| CI/CD pipeline | OIDC federation | ECR push, `kubectl apply` via kubeconfig |

**Least-privilege applied at every layer:** no wildcard `Resource: "*"` except where AWS APIs require it (DescribeAutoScalingGroups), and even those are scoped by resource tags.

### Additional Security Controls
- **IMDSv2 enforced** on all nodes (hop limit 1 — containers cannot reach IMDS).
- **Read-only root filesystem** on all containers; writable `/tmp` via emptyDir.
- **Pod Security Standards**: namespace label `enforce: restricted`.
- **Secrets** stored in AWS Secrets Manager; mounted via External Secrets Operator — never baked into images or ConfigMaps.
- **VPC Flow Logs** → CloudWatch Logs (90-day retention) for forensic analysis.
- **ALB access logs** → S3 for audit trail.
- **KMS** encrypts: EKS secrets, EBS volumes, Aurora, S3 buckets, CloudWatch logs.
- **Container images**: scanned by ECR image scanning (weekly); critical vulnerabilities block CI pipeline.

---

## D. Reliability & Observability

### SLO Targets
| SLI | Target | Alert Threshold |
|-----|--------|-----------------|
| Availability (error rate) | 99.9% (≤0.1% errors) | Alert if >1% for 5 min |
| Latency p99 | < 2 s | Alert if >2 s for 5 min |
| Latency p50 | < 300 ms | Dashboard only |

### Observability Stack
- **Metrics**: Prometheus (Amazon Managed Prometheus) + Grafana (Amazon Managed Grafana).  
  Recording rules pre-compute `request_rate5m`, `error_rate5m`, `p99_latency5m` for fast dashboards.
- **Logs**: Structured JSON logs → AWS CloudWatch Logs (via Fluent Bit DaemonSet) → CloudWatch Log Insights for ad-hoc queries.
- **Traces**: AWS X-Ray (sidecar) for distributed tracing across the point-deduction transaction chain.
- **Alerting**: PagerDuty integration via CloudWatch Alarms and PrometheusRule alerts:
  - `RedemptionHighErrorRate` (critical — pages on-call)
  - `RedemptionHighP99Latency` (warning)
  - `RedemptionHPAMaxedOut` (warning — pre-emptive capacity alert)
  - `RedemptionPDBViolation` (critical)

### Failure Scenarios & Recovery

| Failure | Detection | Recovery Mechanism | RTO |
|---------|-----------|-------------------|-----|
| Single pod crash | Liveness probe fails | Kubernetes restarts pod | < 30 s |
| Bad deployment (new image) | Readiness probe fails | Rolling update halts; old pods keep serving | 0 downtime |
| AZ outage | Node NotReady | Topology spread reschedules pods to remaining 2 AZs; Cluster Autoscaler adds nodes | ~2 min |
| Node Spot interruption | AWS Node Termination Handler (2 min notice) | Drains node; HPA fills capacity on remaining nodes | < 2 min |
| Flash Sale 10× spike | CPU/RPS metric breach | HPA + Cluster Autoscaler fully automated | < 3 min |
| Database failover | Aurora Multi-AZ automatic | Aurora promotes replica (DNS CNAME flip); app retries with exponential back-off | < 30 s |
| Secrets rotation | External Secrets Operator re-syncs on schedule | Pods pick up new credentials without restart | Transparent |

### Circuit Breaker
The application is configured with a circuit breaker (`ENABLE_CIRCUIT_BREAKER=true`, threshold 50%) to fail fast on downstream database saturation and return 503 instead of accumulating latency tails.

---

## E. Operations

### Day-2 Operations — Minimising Toil

| Area | Strategy |
|------|----------|
| **Deployments** | GitOps via ArgoCD — push to Git triggers automated rollout; canary/blue-green weights managed via Argo Rollouts |
| **Secret rotation** | External Secrets Operator polls Secrets Manager every 1 h; zero manual rotation steps |
| **Node upgrades** | EKS managed node groups support one-click AMI upgrades with `max_unavailable: 1`; PDB prevents service disruption |
| **Certificate renewal** | ACM auto-renews; no manual cert handling |
| **Cost optimisation** | Spot for burst; Karpenter (future) for right-sizing; AWS Compute Savings Plans for baseline On-Demand |
| **Runbook automation** | Pre-warming script for scheduled Flash Sales; Slack-triggered Lambda for scale-out pre-warm |
| **Dependency updates** | Renovate Bot PRs for Terraform modules, Helm chart versions, and Docker base images |
| **Chaos engineering** | Monthly Game Days using AWS Fault Injection Simulator: AZ termination, pod deletion, latency injection |

### Team Delegation Plan

**Team:** 1 Senior Engineer (SE) + 2 Junior Engineers (JE-1, JE-2)

#### Sprint 1 — Foundation (Week 1)

| Task | Owner | Why |
|------|-------|-----|
| VPC, subnets, NAT GW, routing (Terraform) | JE-1 | Well-scoped, low ambiguity; good learning task |
| IAM roles, IRSA, KMS (Terraform) | SE | Security-critical; requires deep IAM knowledge |
| EKS cluster + node groups (Terraform) | SE | Complex; interacts with VPC and IAM modules |
| Aurora + ElastiCache + SQS (Terraform) | JE-2 | RDS/ElastiCache modules are well-documented |

#### Sprint 2 — Application Layer (Week 2)

| Task | Owner | Why |
|------|-------|-----|
| Kubernetes Deployment, Service, ConfigMap, PDB | JE-1 | Foundational K8s resources, reviewable by SE |
| HPA, KEDA ScaledObject, Cluster Autoscaler Helm chart | SE | Scaling interactions require senior judgement |
| Network Policies, Ingress, WAF | SE | Security-critical; least-privilege networking |
| Monitoring: ServiceMonitor, PrometheusRules, Grafana dashboards | JE-2 | Observable, well-defined metrics; good ownership |

#### Sprint 3 — Hardening & CI/CD (Week 3)

| Task | Owner | Why |
|------|-------|-----|
| ArgoCD setup, GitOps repo structure | JE-1 | Guided by SE; well-documented tooling |
| External Secrets Operator + secret sync | SE | Security posture decision |
| CI pipeline (GitHub Actions: build, scan, push, deploy) | JE-2 | Builds on previous ECR/ArgoCD work |
| Load testing (k6) + SLO validation | SE (leads) + both JEs | Full team; validates all Sprint 1–2 work |
| Runbooks + incident response playbooks | All | Shared ownership of operational readiness |

---

## Trade-offs & Decisions

| Decision | Alternative Considered | Reason Chosen |
|----------|----------------------|---------------|
| Spot for burst + On-Demand baseline | All On-Demand | 60–70% cost saving; baseline protects SLA |
| HPA + KEDA together | HPA only | KEDA enables queue-depth-driven scaling before CPU spikes |
| Private EKS endpoint | Public endpoint | Eliminates API server as an internet attack surface |
| Aurora Multi-AZ | RDS PostgreSQL | Faster failover (~30 s vs ~60–120 s); Aurora's writer/reader split for read scaling |
| External Secrets Operator | Sealed Secrets | Centralised rotation via Secrets Manager; no encrypted-in-Git complexity |
| Per-AZ NAT Gateway | Single NAT | Eliminates AZ single-point-of-failure for egress traffic |

---

## Repository Structure

```
accor-redemption/
├── terraform/
│   ├── modules/
│   │   ├── vpc/          # VPC, subnets, NAT GWs, Flow Logs
│   │   ├── eks/          # Cluster, node groups, add-ons, KMS
│   │   ├── iam/          # Cluster role, node role, IRSA roles
│   │   └── security-groups/  # Cluster and node SGs
│   └── envs/
│       └── production/   # main.tf, variables.tf, outputs.tf
├── k8s/
│   ├── base/             # Namespace, Deployment, Service, Ingress
│   │   ├── namespace.yaml
│   │   ├── deployment.yaml   # incl. ServiceAccount
│   │   ├── pdb.yaml
│   │   ├── ingress.yaml
│   │   ├── configmap.yaml
│   │   └── network-policy.yaml
│   ├── autoscaling/
│   │   ├── hpa.yaml
│   │   └── keda-scaledobject.yaml
│   └── monitoring/
│       └── servicemonitor-alerts.yaml
└── docs/
    ├── architecture-diagram.drawio
    └── design-document.md  ← this file
```

---

*Prepared by: [Candidate Name] | Assessment submitted: 2026-06-26*
