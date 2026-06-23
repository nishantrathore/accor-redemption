# The Redemption Service — Infrastructure

AWS EKS production infrastructure for Accor's hotel loyalty-point deduction microservice.  
Region: `ap-southeast-1` (Singapore) · Zero downtime · Auto-scales 10× on Flash Sales

---

## Architecture

See [docs/architecture-diagram.md](docs/architecture-diagram.md) for the full diagram, component table, and network security layers.

---

## SLO Targets

| SLI | Target | Alert |
|-----|--------|-------|
| Availability | 99.9% (≤ 0.1% errors) | Error rate > 1% for 5 min → page |
| Latency p99 | < 2 s | > 2 s for 5 min → warn |
| Latency p50 | < 300 ms | Dashboard only |
| Scale-out | 3 → 50 pods in < 3 min | HPA maxed → warn |

---

## Prerequisites

| Tool | Version |
|------|---------|
| Terraform | >= 1.6.0 |
| kubectl | >= 1.29 |
| AWS CLI | >= 2.15 |
| helm | >= 3.14 |

---

## Quick Start

### 1. Bootstrap remote state

```bash
aws s3 mb s3://accor-tf-state-prod --region ap-southeast-1
aws dynamodb create-table \
  --table-name accor-tf-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-southeast-1
```

### 2. Deploy infrastructure

```bash
cd terraform/envs/production
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### 3. Configure kubectl

```bash
aws eks update-kubeconfig \
  --name redemption-production \
  --region ap-southeast-1
```

### 4. Install cluster add-ons (Helm)

```bash
# AWS Load Balancer Controller
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --set clusterName=redemption-production

# Cluster Autoscaler
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName=redemption-production \
  --set awsRegion=ap-southeast-1

# KEDA
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda -n kube-system

# External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n kube-system

# Prometheus stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace
```

### 5. Deploy the application

Replace `ACCOUNT_ID` and `IMAGE_TAG` in `k8s/base/deployment.yaml`, then:

```bash
kubectl apply -f k8s/base/
kubectl apply -f k8s/autoscaling/
kubectl apply -f k8s/monitoring/
```

### 6. Verify

```bash
kubectl get pods -n redemption
kubectl get hpa -n redemption
kubectl get ingress -n redemption
```

---

## Flash Sale Pre-warm

Pre-scale 10 minutes before a known event to skip the ~90s autoscaler cold start:

```bash
kubectl scale deployment/redemption -n redemption --replicas=20
kubectl get nodes -w
```

---

## Repository Structure

```
accor-redemption/
├── terraform/
│   ├── modules/
│   │   ├── vpc/               VPC, subnets ×3 AZs, NAT GWs, Flow Logs
│   │   ├── eks/               Cluster, baseline + burst node groups, KMS, add-ons
│   │   ├── iam/               Cluster/node roles, IRSA (app + autoscaler)
│   │   └── security-groups/   Cluster ↔ node SGs
│   └── envs/production/       main.tf · variables.tf · outputs.tf
├── k8s/
│   ├── base/                  Namespace, Deployment, Service, Ingress
│   │   ├── namespace.yaml     Pod Security Standards: restricted
│   │   ├── deployment.yaml    Topology spread, rolling update, security context
│   │   ├── pdb.yaml           minAvailable 70%
│   │   ├── ingress.yaml       ALB + WAFv2 + ACM
│   │   ├── configmap.yaml     App tuning (circuit breaker, pool sizes)
│   │   └── network-policy.yaml  Default-deny + explicit allow rules
│   ├── autoscaling/
│   │   ├── hpa.yaml           CPU/memory/RPS triggers (3–50 replicas)
│   │   └── keda-scaledobject.yaml  SQS queue-depth trigger
│   └── monitoring/
│       └── servicemonitor-alerts.yaml  PrometheusRules + ServiceMonitor
└── docs/
    ├── architecture-diagram.md   Architecture diagram + component summary
    └── design-document.md        Design decisions and reasoning
```

---

## Docs

- [Architecture Diagram](docs/architecture-diagram.md)
- [Design Document](docs/design-document.md)
