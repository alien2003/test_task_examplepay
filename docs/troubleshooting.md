# Troubleshooting Guide

## Scenario A: Pods Stuck in Pending State

### Symptoms

- `kubectl get pods -n payments` shows `payment-service` pods in `Pending` state for > 5 minutes
- `kubectl describe pod <pod-name> -n payments` shows events like:
  ```
  Warning  FailedScheduling  0/12 nodes are available: 12 node(s) didn't match Pod's node affinity/selector, 12 node(s) had untolerated taint {dedicated: payments:NoSchedule}
  ```
- Karpenter logs show no provisioning activity for the `payments` NodePool

### Root Cause

Two issues combine to prevent scheduling:

1. **Missing toleration**: The pod spec does not include a toleration for the `dedicated=payments:NoSchedule` taint applied by the payments Karpenter NodePool. Without this toleration, the scheduler rejects all payment-dedicated nodes.

2. **Overly restrictive node affinity**: The pod's `nodeSelector` or `topologySpreadConstraints` restrict scheduling to a single availability zone (e.g., `us-east-1a`), but all available capacity in that AZ is consumed. The scheduler cannot place pods in other AZs.

### Fix

Add the missing toleration to the pod template and expand the AZ list:

```yaml
spec:
  template:
    spec:
      tolerations:
        - key: dedicated
          value: payments
          effect: NoSchedule
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: payment-service
      # Ensure nodeSelector allows all AZs labeled by Karpenter
      nodeSelector:
        workload-type: latency-sensitive
```

Verify the fix:

```bash
kubectl get pods -n payments -w
# Pods should transition from Pending -> ContainerCreating -> Running

kubectl get nodes -l workload-type=latency-sensitive
# Nodes should exist in multiple AZs
```

### Prevention

1. **Kyverno policy**: Deploy a ClusterPolicy that validates all pods in the `payments` namespace include the required toleration:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-payments-toleration
   spec:
     validationFailureAction: Enforce
     rules:
       - name: check-toleration
         match:
           resources:
             kinds: ["Pod"]
             namespaces: ["payments"]
         validate:
           message: "Pods in the payments namespace must tolerate dedicated=payments:NoSchedule"
           pattern:
             spec:
               tolerations:
                 - key: dedicated
                   value: payments
                   effect: NoSchedule
   ```

2. **CI linting**: Add `kubeconform` with custom schemas that check for required tolerations before merge. Include a `conftest` policy that validates `topologySpreadConstraints` reference all three AZs.

---

## Scenario B: Terraform Dependency Cycle

### Symptoms

- `terraform plan` fails with:
  ```
  Error: Cycle: aws_eks_addon.vpc_cni, aws_eks_node_group.karpenter_bootstrap,
  aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy
  ```
- The cycle prevents any Terraform operations (plan, apply, destroy)

### Root Cause

The dependency graph contains a circular reference:

```
aws_eks_addon.vpc_cni
    depends_on: aws_eks_node_group.karpenter_bootstrap
        depends_on: aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy
            depends_on: aws_eks_addon.vpc_cni   <-- CYCLE
```

This happens when someone adds an explicit `depends_on` to the `aws_iam_role_policy_attachment` resource referencing the addon, typically to "ensure the CNI addon is ready before attaching policies." This dependency is unnecessary because `aws_iam_role_policy_attachment` only needs the IAM role (which exists independently of the addon).

### Fix

Remove the circular `depends_on` from the policy attachment resource. The correct dependency chain is:

```
aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy
    depends_on: aws_iam_role.node  (implicit via role = aws_iam_role.node.name)

aws_eks_node_group.karpenter_bootstrap
    depends_on: aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy  (explicit)

aws_eks_addon.vpc_cni
    depends_on: aws_eks_node_group.karpenter_bootstrap  (explicit)
```

The policy attachment does not depend on the addon. It depends only on the IAM role, which Terraform infers automatically from the resource reference.

```hcl
# WRONG - creates cycle
resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name

  depends_on = [aws_eks_addon.vpc_cni]  # REMOVE THIS LINE
}

# CORRECT - no explicit depends_on needed
resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}
```

After fixing, verify:

```bash
terraform validate
# Success! The configuration is valid.

terraform plan
# Should complete without cycle errors
```

### Prevention

1. **CI validation**: Run `terraform validate` in the commit stage of the CI pipeline. This catches cycle errors before code reaches `main`.

2. **Graph visualization**: Periodically generate and review the dependency graph:
   ```bash
   terraform graph | dot -Tsvg > graph.svg
   ```
   Cycles appear as loops in the SVG output.

3. **Code review checklist**: Any PR adding `depends_on` should justify why implicit dependencies (via resource references) are insufficient. Most `depends_on` usage is unnecessary in Terraform and indicates a design issue.

---

## Scenario C: Intermittent 503 Errors During Deployments

### Symptoms

- During Argo Rollouts blue/green deployments, external clients receive 503 errors for 5-15 seconds
- Errors correlate with pods being terminated (old ReplicaSet scaling down)
- Application logs show requests arriving at pods that are mid-shutdown
- ALB target group health checks show brief periods of unhealthy targets

### Root Cause

When Kubernetes terminates a pod, it sends `SIGTERM` and begins removing the pod from the Service endpoints. However, the ALB target group deregistration takes 15-30 seconds to propagate. During this window:

1. Kubernetes sends `SIGTERM` to the pod
2. The pod begins shutting down and stops accepting connections
3. The ALB is still sending traffic to the pod (deregistration not yet complete)
4. Requests to the terminating pod receive 503 or connection refused errors

The pod's `terminationGracePeriodSeconds` is set correctly, but without a `preStop` lifecycle hook, the container exits immediately upon receiving `SIGTERM`, before the ALB has removed it from the target group.

### Fix

Add a `preStop` lifecycle hook that delays container shutdown, giving the ALB time to complete deregistration:

```yaml
spec:
  containers:
    - name: payment-service
      lifecycle:
        preStop:
          exec:
            command: ["/bin/sh", "-c", "sleep 15"]
```

The 15-second sleep ensures:
- The ALB deregistration drain completes (default: 10 seconds in our configuration)
- In-flight requests finish processing
- The pod only exits after traffic has been fully drained

Additionally, ensure the readiness probe is configured to fail quickly on shutdown. The application should stop responding to readiness checks when it receives `SIGTERM`:

```yaml
readinessProbe:
  httpGet:
    path: /ready
    port: 8080
  periodSeconds: 5
  failureThreshold: 3
```

This causes Kubernetes to remove the pod from the Service endpoints sooner, signaling the ALB to start deregistration.

### Verification

Deploy the fix and monitor during the next blue/green rollout:

```bash
# Watch for 503s during deployment
kubectl argo rollouts get rollout payment-service -n payments -w

# Check ALB target health transitions
aws elbv2 describe-target-health \
  --target-group-arn TARGET_GROUP_ARN \
  --region us-east-1

# Monitor error rate
curl -s http://prometheus:9090/api/v1/query?query=rate(http_requests_total{code="503",app="payment-service"}[1m])
```

Zero 503 errors during the subsequent deployment confirms the fix.

### Prevention

1. **Kyverno policy**: Enforce that all pods in production namespaces have a `preStop` lifecycle hook:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-prestop-hook
   spec:
     validationFailureAction: Enforce
     rules:
       - name: check-prestop
         match:
           resources:
             kinds: ["Pod"]
             namespaces: ["payments", "risk-engine", "fraud-detection"]
         validate:
           message: "All containers must have a preStop lifecycle hook for graceful shutdown"
           pattern:
             spec:
               containers:
                 - lifecycle:
                     preStop:
                       exec:
                         command: "?*"
   ```

2. **Pod readiness gates**: Configure ALB target group binding with `readinessGates` so the pod is not considered `Ready` until the ALB confirms registration:

   ```yaml
   apiVersion: elbv2.k8s.aws/v1beta1
   kind: TargetGroupBinding
   metadata:
     name: payment-service
   spec:
     targetGroupARN: arn:aws:elasticloadbalancing:...
     targetType: ip
     serviceRef:
       name: payment-service-active
       port: 8080
   ```

3. **Load test during deployments**: Include a deployment scenario in the staging soak test that performs a rollout under load and asserts zero 5xx responses.
