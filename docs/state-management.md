# Terraform State Management

## Backend Isolation Strategy

Each environment and region maintains its own isolated Terraform state backend. This prevents blast radius from state corruption and allows independent deployment lifecycles per region.

### Naming Convention

| Resource | Pattern | Example |
|----------|---------|---------|
| S3 Bucket | `{company}-{env}-tfstate-{region}` | `examplepay-prod-tfstate-us-east-1` |
| DynamoDB Table | `{company}-{env}-tfstate-lock` | `examplepay-prod-tfstate-lock` |
| State Key | `{component}/terraform.tfstate` | `eks/terraform.tfstate` |

Each AWS account and region pair gets its own S3 bucket. The DynamoDB lock table can be shared within a region since lock keys are namespaced by the full S3 key path.

### Backend Configuration

```hcl
backend "s3" {
  bucket         = "examplepay-prod-tfstate-us-east-1"
  key            = "eks/terraform.tfstate"
  region         = "us-east-1"
  dynamodb_table = "examplepay-prod-tfstate-lock"
  encrypt        = true
}
```

The `encrypt = true` flag ensures state files are encrypted at rest using SSE-S3. The S3 buckets themselves are further configured with:

- Versioning enabled (for state history and recovery)
- Server-side encryption with AWS KMS
- Public access blocked at the bucket level
- Lifecycle rules to expire old versions after 90 days

## State Locking

DynamoDB provides distributed locking to prevent concurrent state modifications. When `terraform apply` runs, it acquires a lock in the DynamoDB table using the S3 key as the lock ID. If another process attempts to modify the same state, it receives a lock error and must wait.

Lock table schema:

| Attribute | Type | Purpose |
|-----------|------|---------|
| LockID | String (Hash Key) | S3 bucket + key path |
| Info | String | Lock holder metadata (who, when, operation) |

If a lock becomes stale (e.g., the operator's machine crashed mid-apply), it can be force-released:

```bash
terraform force-unlock LOCK_ID
```

This should only be done after confirming no other process is actively modifying state.

## Cross-Account Access

Terraform authenticates to the target AWS account via IAM role assumption. The CI/CD pipeline assumes `TerraformDeployRole` in the target account:

```
CI Runner (Shared Account)
    |
    +-- sts:AssumeRole --> arn:aws:iam::<PROD_ACCOUNT>:role/TerraformDeployRole
    |                          |
    |                          +-- S3 state bucket access
    |                          +-- DynamoDB lock table access
    |                          +-- Resource provisioning permissions
    |
    +-- sts:AssumeRole --> arn:aws:iam::<STAGING_ACCOUNT>:role/TerraformDeployRole
```

The `TerraformDeployRole` has a trust policy that allows assumption only from the CI runner's IAM role, with an external ID condition for additional security.

## Secret Injection Path

Secrets are managed entirely outside of Terraform state. The flow from secret storage to pod consumption is:

```
+---------------------+     +---------------------------+     +----------------+
|  AWS Secrets Manager | --> | External Secrets Operator | --> | K8s Secret     |
|                     |     | (ESO, in-cluster)         |     | (etcd, encrypted|
|  examplepay/prod/      |     |                           |     |  at rest via   |
|  payment-service/   |     | SecretStore + ExternalSecret   |  KMS envelope) |
|  stripe             |     | CRDs define mapping       |     |                |
+---------------------+     +---------------------------+     +-------+--------+
                                                                      |
                                                              +-------v--------+
                                                              | Pod            |
                                                              | (envFrom:      |
                                                              |  secretRef)    |
                                                              +----------------+
```

### Why Secrets Never Touch Terraform State

1. **Terraform state is plaintext JSON.** Even with S3 encryption at rest, anyone with read access to the state bucket can extract secret values from `terraform.tfstate`.

2. **State is versioned.** Deleting a secret from Terraform does not remove it from historical state versions stored in S3.

3. **State is shared.** Multiple team members and CI pipelines read state. Secret access should follow least-privilege, not blanket state-reader permissions.

4. **Rotation is independent.** Secrets rotate on their own schedule (Secrets Manager automatic rotation). Terraform should not need to run for a secret rotation to take effect.

By using External Secrets Operator, the Terraform codebase only references the *path* to secrets (e.g., `examplepay/prod/payment-service/stripe`), never the values. ESO syncs the actual values from Secrets Manager into Kubernetes Secrets on a configurable refresh interval (default: 1 hour). The Kubernetes Secrets themselves are encrypted at rest in etcd via the KMS envelope encryption configured on the EKS cluster.

## State File Layout

```
examplepay-prod-tfstate-us-east-1/
  eks/terraform.tfstate          # EKS cluster, VPC, node groups
  dns/terraform.tfstate          # Route 53 records, health checks
  monitoring/terraform.tfstate   # CloudWatch dashboards, alarms

examplepay-prod-tfstate-eu-west-1/
  eks/terraform.tfstate          # DR region EKS cluster, VPC
  transit-gateway/terraform.tfstate  # Cross-region TGW peering
```

This separation allows the platform team to apply changes to networking independently of compute, and the DR region can be managed without touching primary region state.
