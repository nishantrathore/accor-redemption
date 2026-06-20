# The Redemption Service — Infrastructure

AWS EKS infrastructure for Accor's hotel loyalty-point deduction microservice.

## Prerequisites

| Tool | Version |
|------|---------|
| Terraform | >= 1.6.0 |
| kubectl | >= 1.29 |
| AWS CLI | >= 2.15 |
| helm | >= 3.14 |

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
  -n kube-system \
  --set clusterName=redemption-production

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
helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
```

### 5. Deploy the application

Replace `ACCOUNT_ID` and `IMAGE_TAG` placeholders, then:

```bash
kubectl apply -k k8s/base/
kubectl apply -f k8s/autoscaling/
kubectl apply -f k8s/monitoring/
```

### 6. Verify

```bash
kubectl get pods -n redemption
kubectl get hpa -n redemption
kubectl get ingress -n redemption
```

## Architecture Overview

See [docs/architecture-diagram.drawio](docs/architecture-diagram.drawio) — open with [draw.io](https://app.diagrams.net).

## Design Document

See [docs/design-document.md](docs/design-document.md) for the full architectural decision record, trade-offs, SLO targets, and team delegation plan.

## Scaling for Flash Sales

Pre-warm before a scheduled event:

```bash
# Scale app pods immediately
kubectl scale deployment/redemption -n redemption --replicas=20

# Verify cluster autoscaler is adding nodes
kubectl get nodes -w
```

## Key Files

| File | Purpose |
|------|---------|
| `terraform/modules/vpc/` | VPC, subnets (3 AZs), NAT GWs, Flow Logs |
| `terraform/modules/eks/` | EKS cluster, baseline + burst node groups, KMS |
| `terraform/modules/iam/` | Cluster/node roles, IRSA for app + autoscaler |
| `terraform/modules/security-groups/` | Cluster and node security groups |
| `k8s/base/deployment.yaml` | App Deployment + ServiceAccount + Service |
| `k8s/base/pdb.yaml` | PodDisruptionBudget (minAvailable 70%) |
| `k8s/base/network-policy.yaml` | Default-deny + allow rules |
| `k8s/autoscaling/hpa.yaml` | HPA (3–50 replicas, CPU/memory/RPS) |
| `k8s/autoscaling/keda-scaledobject.yaml` | KEDA SQS queue-depth trigger |
| `k8s/monitoring/servicemonitor-alerts.yaml` | SLO PrometheusRules |
