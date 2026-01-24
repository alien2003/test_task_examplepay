# ExamplePay Infrastructure

Production-grade multi-region Kubernetes infrastructure on AWS, powering ExamplePay's payment processing platform.

## Architecture Overview

ExamplePay runs on Amazon EKS across two AWS regions in an active/passive configuration with latency-based routing:

| Region | Role | Cluster | VPC CIDR |
|--------|------|---------|----------|
| us-east-1 | Primary | `examplepay-prod` | `10.10.0.0/16` |
| eu-west-1 | DR / EU Traffic | `examplepay-prod-eu` | `10.20.0.0/16` |

Cross-region connectivity is provided by AWS Transit Gateway peering, enabling private communication between clusters. Route 53 latency-based routing with health checks provides automatic DNS failover when the primary region becomes unhealthy.

Key infrastructure components:

- **Compute**: EKS 1.29 with Karpenter for node autoscaling (payments, batch, and GPU node pools)
- **Networking**: Isolated VPCs with private subnets, NAT gateways per AZ, VPC endpoints for AWS service access
- **Security**: Envelope encryption for Kubernetes secrets (KMS), IRSA for pod-level IAM, Cilium network policies, Kyverno image verification
- **Observability**: Prometheus metrics, Fluent Bit log forwarding, AWS X-Ray distributed tracing
- **Deployments**: Argo Rollouts blue/green with automated analysis (P99 latency, error rate gates)
- **Secrets**: AWS Secrets Manager with External Secrets Operator — secrets never enter Terraform state

## Directory Structure

```
.
├── modules/
│   ├── vpc/                    # VPC, subnets, NAT, flow logs, VPC endpoints
│   ├── eks/                    # EKS cluster, managed node group, IRSA roles, addons
│   ├── transit-gateway/        # Cross-region Transit Gateway peering
│   └── dns-failover/           # Route 53 health checks and latency-based routing
├── environments/
│   └── prod/
│       ├── us-east-1/          # Primary region deployment
│       └── eu-west-1/          # DR region deployment
├── kubernetes/
│   ├── karpenter/              # NodePool and EC2NodeClass definitions
│   ├── deployments/            # Argo Rollouts, analysis templates, Kyverno policies
│   ├── secrets/                # External Secrets Operator manifests
│   └── network-policies/       # Cilium network policies
├── monitoring/
│   └── prometheus-rules.yaml   # PrometheusRule CRDs (SLO burn rate, node pressure, Karpenter)
└── docs/
    ├── state-management.md     # Terraform state backend strategy
    ├── observability-stack.md  # Monitoring and logging architecture
    ├── dr-runbook.md           # Disaster recovery procedures
    ├── cicd-pipeline.md        # CI/CD pipeline design
    ├── database-migration-strategy.md
    └── troubleshooting.md      # Common failure scenarios and fixes
```

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | >= 1.6.0 | Infrastructure provisioning |
| kubectl | >= 1.29 | Kubernetes cluster management |
| Helm | >= 3.14 | Chart deployments (Karpenter, Prometheus, etc.) |
| AWS CLI | >= 2.15 | AWS authentication and EKS token generation |
| cosign | >= 2.2 | Container image signature verification |

You must have AWS credentials configured with permission to assume the `TerraformDeployRole` in the target account.

## Quick Start

### 1. Initialize the primary region

```bash
cd environments/prod/us-east-1
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### 2. Configure kubectl

```bash
aws eks update-kubeconfig \
  --name examplepay-prod \
  --region us-east-1 \
  --role-arn arn:aws:iam::role/TerraformDeployRole
```

### 3. Deploy Karpenter node pools

```bash
kubectl apply -f kubernetes/karpenter/
```

### 4. Deploy workloads

```bash
kubectl apply -f kubernetes/secrets/
kubectl apply -f kubernetes/network-policies/
kubectl apply -f kubernetes/deployments/
```

### 5. Initialize the DR region

```bash
cd environments/prod/eu-west-1
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## Modules

### VPC (`modules/vpc`)

Creates a production VPC with public and private subnets across three availability zones, NAT gateways (one per AZ for high availability), VPC flow logs to S3, and VPC endpoints for private access to ECR, STS, Secrets Manager, and S3.

### EKS (`modules/eks`)

Provisions an EKS cluster with private API endpoint, KMS envelope encryption for secrets, all control plane log types enabled, a managed node group for Karpenter bootstrapping, VPC CNI with network policy and prefix delegation, and IRSA roles for workloads (payment-service, Karpenter controller).

### Transit Gateway (`modules/transit-gateway`)

Establishes cross-region connectivity via Transit Gateway peering. Manages route table associations, propagations, and VPC route entries for private traffic between the us-east-1 and eu-west-1 VPCs.

### DNS Failover (`modules/dns-failover`)

Configures Route 53 latency-based routing with health checks against both regional ingress endpoints. Health checks run from three geographically distributed regions with a 10-second interval and 3-failure threshold.

## Documentation

- [Terraform State Management](docs/state-management.md)
- [Observability Stack](docs/observability-stack.md)
- [Disaster Recovery Runbook](docs/dr-runbook.md)
- [CI/CD Pipeline](docs/cicd-pipeline.md)
- [Database Migration Strategy](docs/database-migration-strategy.md)
- [Troubleshooting Guide](docs/troubleshooting.md)
