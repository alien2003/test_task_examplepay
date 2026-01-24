# Disaster Recovery Runbook: us-east-1 Regional Failure

**Severity**: P1 - Critical
**RTO Target**: 15 minutes (DNS failover) / 30 minutes (full service restoration)
**RPO Target**: < 1 second (Aurora Global Database), < 5 minutes (SQS messages)

---

## Phase 1: Automated Actions

The following actions occur automatically when us-east-1 becomes unreachable:

### 1.1 DNS Failover (Route 53)

Route 53 health checks poll the primary ingress endpoint (`ingress.us-east-1.examplepay.internal`) every 10 seconds from three checker regions. After 3 consecutive failures (30 seconds), Route 53 marks the primary record as unhealthy and stops returning it in DNS responses.

- **TTL**: 30 seconds on latency-based routing records
- **Effective failover time**: 30s (health check failure) + 30s (TTL expiry) = ~60 seconds for most clients
- **No operator action required**

### 1.2 SQS Cross-Region Replication

The SQS event bridge rule in us-east-1 replicates payment events to the `examplepay-prod-payment-events-dr` queue in eu-west-1. During a regional failure:

- Messages already in the eu-west-1 DR queue are consumed by the DR region's payment processors
- Messages in-flight in us-east-1 at the time of failure may be lost (visibility timeout window)
- Estimated data loss window: 0-30 seconds of queued messages

### 1.3 Aurora Global Database

Aurora Global Database replicates from the us-east-1 primary cluster to the eu-west-1 secondary with typical replication lag < 1 second. During a regional failure:

- Aurora does NOT automatically promote the secondary cluster
- Automatic promotion can be enabled via the `Managed planned failover` feature, but for unplanned outages, manual promotion is required to prevent split-brain scenarios
- The secondary cluster continues serving read traffic if read replicas are configured

---

## Phase 2: Manual Verification Checklist

The on-call platform engineer must complete the following steps in order:

1. **Confirm the regional failure is genuine** - Check the AWS Health Dashboard (https://health.aws.amazon.com) and ExamplePay's external monitoring (Pingdom/StatusCake) to rule out a localized network issue or monitoring false positive.

2. **Verify Route 53 failover has occurred** - Run `dig api.examplepay.com` from multiple geographic locations and confirm responses point to the eu-west-1 ALB. Check the Route 53 health check status in the console.

3. **Check eu-west-1 EKS cluster health** - Run `kubectl get nodes --context examplepay-prod-eu` and verify all nodes are `Ready`. Check that Karpenter is operational and can provision new nodes if needed.

4. **Verify eu-west-1 pod readiness** - Run `kubectl get pods -n payments --context examplepay-prod-eu` and confirm all payment-service replicas are `Running` and `Ready`.

5. **Promote Aurora secondary to primary** - Execute the Aurora Global Database detach and promote:
   ```bash
   aws rds remove-from-global-cluster \
     --global-cluster-identifier examplepay-global \
     --db-cluster-identifier examplepay-prod-eu-cluster \
     --region eu-west-1

   aws rds failover-global-cluster \
     --global-cluster-identifier examplepay-global \
     --target-db-cluster-identifier examplepay-prod-eu-cluster \
     --region eu-west-1
   ```
   Confirm the eu-west-1 cluster is now `available` with `read/write` capability.

6. **Promote ElastiCache Global Datastore** - Promote the eu-west-1 ElastiCache replication group:
   ```bash
   aws elasticache failover-global-replication-group \
     --global-replication-group-id examplepay-sessions \
     --primary-region eu-west-1 \
     --primary-replication-group-id examplepay-prod-eu-sessions
   ```

7. **Update application connection strings** - If applications use region-specific endpoints (not Global Database reader/writer endpoints), update the Kubernetes ConfigMaps or ExternalSecrets to point to eu-west-1 database endpoints. Restart affected pods.

8. **Verify payment processing end-to-end** - Execute a synthetic payment transaction through the preview/staging pipeline in eu-west-1 to confirm the full stack (API -> SQS -> processor -> Aurora -> response) is functional.

9. **Drain the SQS DR queue** - Monitor the `examplepay-prod-payment-events-dr` queue in eu-west-1. Ensure consumer pods are processing messages and the queue depth is decreasing.

10. **Scale up eu-west-1 capacity** - The DR region runs at reduced capacity during normal operations. Increase Karpenter NodePool limits and verify Argo Rollouts replicas match production levels:
    ```bash
    kubectl patch rollout payment-service -n payments \
      --type merge -p '{"spec":{"replicas":12}}' \
      --context examplepay-prod-eu
    ```

11. **Notify downstream partners** - Send webhook notifications to payment gateway partners (Stripe, bank integrations) that traffic is now originating from EU IP ranges. Some partners maintain IP allowlists that may need updating.

12. **Enable enhanced monitoring** - Increase Prometheus scrape frequency for payment-service metrics to 10s (from 30s) and lower alert thresholds during the degraded operation period.

---

## Phase 3: Data Tier Failover Details

### Aurora Global Database

| Metric | Value |
|--------|-------|
| Typical replication lag | < 1 second |
| Maximum observed lag | 5 seconds (during bulk write bursts) |
| Promotion time | 1-2 minutes |
| Data loss (RPO) | < 1 second under normal conditions |

**Risk**: If us-east-1 fails during a period of high replication lag, up to 5 seconds of committed transactions may be lost. The Aurora Global Database tracks `GlobalReplicationLag` as a CloudWatch metric; an alarm fires if lag exceeds 2 seconds.

**Mitigation**: Payment-service uses idempotency keys for all transactions. After failover, any "lost" transactions will be retried by clients and deduplicated on the server side.

### ElastiCache Global Datastore

| Metric | Value |
|--------|-------|
| Typical replication lag | < 1 second |
| Promotion time | < 1 minute |
| Data loss risk | Session data only (non-critical) |

ElastiCache stores session tokens and rate-limiting counters. Loss of this data during failover means:
- Active user sessions will require re-authentication (acceptable)
- Rate limiting counters reset (monitor for abuse spikes post-failover)

---

## Phase 4: Failback Procedure

Once us-east-1 is restored, follow this procedure to return to the primary region:

### 4.1 Validation Gates

Each gate must pass before proceeding to the next step:

**Gate 1: Region Health** - us-east-1 must have been stable for at least 30 minutes with no AWS Health Dashboard incidents.

**Gate 2: EKS Cluster Recovery** - Verify the us-east-1 EKS cluster API server is responsive and all managed node groups are healthy.

**Gate 3: Aurora Re-Replication** - Re-add the us-east-1 cluster as a secondary to the Aurora Global Database. Wait until `GlobalReplicationLag` is consistently < 1 second for at least 15 minutes.

**Gate 4: Data Consistency** - Run the data reconciliation job (`examplepay-reconciler`) to compare transaction records between the eu-west-1 primary and the us-east-1 secondary. All records must match.

**Gate 5: Synthetic Traffic** - Route 5% of production traffic to us-east-1 via weighted Route 53 records. Monitor error rates and latency for 15 minutes.

### 4.2 Cutover Steps

1. Promote Aurora us-east-1 back to primary using managed planned failover (zero-downtime).
2. Update Route 53 records to restore latency-based routing with us-east-1 as healthy.
3. Scale eu-west-1 back to DR capacity levels.
4. Re-enable cross-region SQS replication from us-east-1 to eu-west-1.
5. Run a final reconciliation pass to verify zero data loss.

---

## Phase 5: Communication Template

### Internal Stakeholders (Slack #incident-response)

```
INCIDENT: Regional service degradation - us-east-1
STATUS: [INVESTIGATING | IDENTIFIED | MITIGATING | RESOLVED]
IMPACT: Payment processing latency increased. DR failover [in progress | complete].
NEXT UPDATE: [time]
COMMANDER: [name]
```

### External Partners (Email / Status Page)

```
Subject: ExamplePay Service Update - [Date]

We are currently experiencing a service disruption in our primary
processing region. Our disaster recovery systems have been activated
and payment processing continues from our secondary region.

Current status:
- Payment API: Operational (elevated latency, <500ms)
- Webhook deliveries: Delayed by up to 5 minutes
- Dashboard: Operational

We will provide updates every 30 minutes until full resolution.

For urgent inquiries: ops@examplepay.com | +1-XXX-XXX-XXXX
```

### Post-Incident

A blameless post-mortem must be published within 72 hours of resolution, covering:
- Timeline of events
- What automated systems did and did not work
- Data loss accounting (if any)
- Action items with owners and deadlines
