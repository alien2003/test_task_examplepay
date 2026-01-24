# CI/CD Pipeline

## Pipeline Overview

```
+-----------+     +-----------------+     +------------------+     +----------------+     +---------------+
|           |     |                 |     |                  |     |                |     |               |
|  Commit   +---->+ Build & Test    +---->+ Security Scan    +---->+ Deploy Staging +---->+ Promote Prod  |
|           |     |                 |     |                  |     |                |     |               |
+-----+-----+     +-------+---------+     +--------+---------+     +-------+--------+     +-------+-------+
      |                   |                        |                       |                       |
      v                   v                        v                       v                       v
 +----------+      +-------------+          +-------------+         +-------------+        +--------------+
 | lint     |      | unit tests  |          | Trivy scan  |         | helm upgrade|        | Argo Rollouts|
 | validate |      | integration |          | Snyk SAST   |         | smoke tests |        | blue/green   |
 | fmt check|      | coverage    |          | SBOM (Syft) |         | integration |        | analysis     |
 | tflint   |      | docker build|          | cosign sign |         | soak (30m)  |        | manual gate  |
 +----------+      | push to ECR |          +-------------+         +-------------+        +--------------+
                   +-------------+
```

## Stage Details

### Stage 1: Commit

**Trigger**: Push to any branch or pull request opened against `main`.

| Step | Tool | Details |
|------|------|---------|
| Lint Go code | `golangci-lint` | Runs 50+ linters including `errcheck`, `gosec`, `govet` |
| Lint Terraform | `tflint` + `terraform fmt -check` | Validates HCL syntax and enforces formatting |
| Lint Kubernetes | `kubeconform` + `kustomize build` | Validates manifests against Kubernetes JSON schemas |
| Lint Helm charts | `helm lint` + `helm template` | Catches template rendering errors before deploy |
| Commit message | `commitlint` | Enforces Conventional Commits format |

**Gate**: All lint checks must pass. PR cannot be merged without green status.
**Failure action**: Developer fixes locally and pushes updated commits.
**Artifacts**: None.

### Stage 2: Build & Test

**Trigger**: Commit stage passes.

| Step | Tool | Details |
|------|------|---------|
| Unit tests | `go test -race -coverprofile` | Race detector enabled, minimum 80% coverage required |
| Integration tests | `go test -tags=integration` | Runs against containerized dependencies (PostgreSQL, Redis, SQS via LocalStack) |
| Docker build | `docker buildx build` | Multi-stage build, distroless base image, `--provenance=true` for SLSA |
| Push image | `docker push` to ECR | Tagged with git SHA and semantic version |

**Gate**: All tests pass, coverage >= 80%, Docker build succeeds.
**Failure action**: Pipeline stops. Developer reviews test failures in CI logs.
**Artifacts**: Container image in ECR, test coverage report, build provenance attestation.

### Stage 3: Security Scanning

**Trigger**: Build stage passes.

| Step | Tool | Details |
|------|------|---------|
| Container vulnerability scan | **Trivy** | Scans OS packages and application dependencies. Fails on HIGH/CRITICAL CVEs with no fix available for > 30 days |
| Static analysis (SAST) | **Snyk Code** | Identifies insecure code patterns (SQL injection, hardcoded secrets, etc.) |
| SBOM generation | **Syft** | Produces CycloneDX SBOM, attached to image as OCI artifact |
| Image signing | **cosign** | Signs the image digest with a KMS-backed key, attaches signature to ECR |
| License compliance | **Syft** + policy engine | Flags GPL-licensed dependencies in non-GPL projects |

**Gate**: Zero HIGH/CRITICAL vulnerabilities without accepted risk exceptions. Image must be signed.
**Failure action**: Security team notified via Slack. Developer must remediate or file a risk acceptance with justification and expiry date.
**Artifacts**: Trivy scan report (JSON), SBOM (CycloneDX JSON), cosign signature, Snyk report.

### Stage 4: Deploy Staging

**Trigger**: Security scan passes on `main` branch.

| Step | Tool | Details |
|------|------|---------|
| Deploy to staging EKS | **Helm** via ArgoCD | ArgoCD Application syncs from the Git repository |
| Smoke tests | **k6** | 50 RPS for 2 minutes against key endpoints, assert P99 < 500ms and error rate < 0.1% |
| Integration tests | **Postman/Newman** | Full payment flow: create payment intent, process, verify webhook delivery |
| Soak test | **k6** | 200 RPS sustained for 30 minutes, monitoring for memory leaks and connection pool exhaustion |

**Gate**: All tests pass. No alert firing in staging Prometheus during the soak period.
**Failure action**: Staging deployment is rolled back via ArgoCD. Developer investigates.
**Artifacts**: k6 test results, Grafana snapshot link.

### Stage 5: Promote to Production

**Trigger**: Manual approval from the on-call tech lead after staging validation.

| Step | Tool | Details |
|------|------|---------|
| Blue/green deploy | **Argo Rollouts** | Preview stack receives production traffic subset |
| Pre-promotion analysis | **Argo AnalysisTemplate** | 10 measurements over 5 minutes: P99 latency < 250ms, error rate < 0.1% |
| Manual promotion gate | **Argo Rollouts UI** | On-call engineer reviews analysis results and promotes or aborts |
| Post-deploy verification | **Synthetic monitors** | External canary checks payment flow from multiple regions |

**Gate**: AnalysisTemplate passes, manual promotion confirmed.
**Failure action**: Argo Rollouts automatically aborts if analysis fails. Active service remains on previous version. scaleDownDelaySeconds (300s) gives time to investigate before preview pods are removed.
**Artifacts**: Argo Rollouts analysis report, deployment record in ArgoCD.

## Supply Chain Security

### Image Signing with cosign

Every container image pushed to ECR is signed using `cosign` with a KMS-backed signing key:

```bash
# Signing (in CI)
cosign sign --key awskms:///arn:aws:kms:us-east-1:ACCOUNT:key/KEY_ID \
  ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/examplepay/payment-service@sha256:DIGEST

# Verification (by Kyverno in cluster)
cosign verify --key cosign.pub \
  ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/examplepay/payment-service@sha256:DIGEST
```

The signing key is stored in AWS KMS and never leaves the HSM. Only the CI pipeline's IAM role has `kms:Sign` permission.

### SBOM with Syft

```bash
syft ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/examplepay/payment-service:TAG \
  -o cyclonedx-json > sbom.json

# Attach SBOM as OCI artifact
cosign attach sbom --sbom sbom.json \
  ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/examplepay/payment-service@sha256:DIGEST
```

SBOMs are stored alongside images in ECR and can be retrieved for audit or vulnerability scanning at any time.

### Kyverno Admission Control

The `verify-image-signatures` ClusterPolicy (deployed via `kubernetes/deployments/kyverno-image-verification.yaml`) enforces:

1. All images in production namespaces (`payments`, `risk-engine`, `fraud-detection`) must have a valid cosign signature
2. All images must originate from the approved ECR registry (`*.dkr.ecr.*.amazonaws.com/examplepay/*`)
3. Image tags are mutated to digests to prevent tag mutation attacks

Unsigned or unverified images are rejected at admission time and never scheduled.

## Rollback Procedures

### Automatic Rollback

Argo Rollouts automatically aborts a deployment if the pre-promotion analysis fails. The active service continues pointing to the previous ReplicaSet. No operator action required.

### Manual Rollback

If issues are detected after promotion:

```bash
# Abort current rollout (if still in progress)
kubectl argo rollouts abort payment-service -n payments

# Roll back to previous revision
kubectl argo rollouts undo payment-service -n payments

# Or target a specific revision
kubectl argo rollouts undo payment-service --to-revision=3 -n payments
```

### Terraform Rollback

For infrastructure changes:

```bash
# Identify the last known-good state version
aws s3api list-object-versions \
  --bucket examplepay-prod-tfstate-us-east-1 \
  --prefix eks/terraform.tfstate

# Revert to previous state and re-apply
terraform plan -out=rollback.tfplan
terraform apply rollback.tfplan
```

Infrastructure rollbacks should be paired with application rollbacks when the two are coupled (e.g., new IAM permissions required by a new application version).
