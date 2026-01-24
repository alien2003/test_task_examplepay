# Observability Stack

## Tool Selection

| Pillar | Selected | Evaluated Alternatives | Decision Driver |
|--------|----------|----------------------|-----------------|
| Metrics | **Prometheus** (kube-prometheus-stack) | Datadog, Amazon CloudWatch | Open-source, no per-host licensing, native Kubernetes service discovery, PromQL ecosystem |
| Logs | **Fluent Bit** | Fluentd, CloudWatch Logs Agent | 10x lower memory footprint than Fluentd (~5MB vs ~50MB per node), native EKS addon support, sufficient plugin coverage |
| Traces | **AWS X-Ray** | Jaeger, Zipkin, Tempo | Native integration with AWS SDK (SQS, DynamoDB, Lambda), no additional infrastructure to operate, built-in service map |
| Profiling | **Pyroscope** | Parca, Datadog Continuous Profiler | Pull-based model matches Prometheus conventions, supports Go/Java/Python runtimes used by ExamplePay services, Grafana-native integration |

### Justifications

**Prometheus over Datadog**: Datadog's per-host pricing model becomes prohibitive at scale with Karpenter's dynamic node provisioning. A single Karpenter-managed cluster can fluctuate between 20 and 200 nodes during batch processing windows, which would result in unpredictable monthly bills. Prometheus with Thanos for long-term storage provides equivalent functionality at a fraction of the cost.

**Fluent Bit over Fluentd**: Fluent Bit is written in C and designed for constrained environments. With 3 Karpenter node pools (payments, batch, GPU) creating and destroying nodes frequently, the DaemonSet footprint matters. Fluent Bit's memory usage remains under 10MB per node versus Fluentd's 50-100MB. The plugin ecosystem covers all our destinations (S3, CloudWatch, OpenSearch).

**AWS X-Ray over Jaeger**: ExamplePay's payment processing pipeline relies heavily on AWS-managed services (SQS, Secrets Manager, Aurora). X-Ray provides automatic instrumentation for AWS SDK calls without additional code changes. Jaeger would require manual span creation for every AWS service interaction. X-Ray's service map also provides a real-time dependency graph that integrates with CloudWatch ServiceLens.

**Pyroscope over Parca**: Both are open-source continuous profiling tools. Pyroscope was selected for its mature Grafana data source plugin, which allows correlating profiles with Prometheus metrics and Loki logs in a single dashboard. Pyroscope also supports push and pull modes, giving flexibility per-service.

## Architecture

```
+------------------+     +------------------+     +-------------------+
| Application Pods |     | Application Pods |     | Application Pods  |
| (metrics: /metrics)    | (stdout/stderr)  |     | (X-Ray SDK)       |
+--------+---------+     +--------+---------+     +---------+---------+
         |                         |                         |
         v                         v                         v
+--------+---------+     +--------+---------+     +---------+---------+
| Prometheus        |     | Fluent Bit       |     | X-Ray Daemon      |
| (ServiceMonitor   |     | (DaemonSet)      |     | (DaemonSet)       |
|  + PodMonitor)    |     |                  |     |                   |
+--------+---------+     +----+----+--------+     +---------+---------+
         |                    |    |                         |
         v                   v    v                         v
+--------+---------+   +----+- --+--------+     +---------+---------+
| Thanos Sidecar   |   | S3     | OpenSearch    | AWS X-Ray         |
| --> Thanos Store  |   | (raw)  | (indexed)    | (managed)         |
| --> S3 (compact)  |   +--------+----------+    +-------------------+
+------------------+
         |
         v
+------------------+
| Grafana          |
| - Prometheus DS  |
| - Loki DS        |    <-- Fluent Bit can also forward to Loki
| - X-Ray DS       |
| - Pyroscope DS   |
+------------------+
```

### Data Flow Summary

1. **Metrics**: Application pods expose `/metrics` endpoints. Prometheus scrapes them via ServiceMonitor/PodMonitor CRDs. Thanos sidecar ships blocks to S3 for long-term storage. Thanos Query provides a unified query layer across regions.

2. **Logs**: Fluent Bit runs as a DaemonSet, tailing container stdout/stderr from `/var/log/containers/`. Logs are enriched with Kubernetes metadata (namespace, pod, labels) and forwarded to both S3 (raw archive) and OpenSearch (indexed for search).

3. **Traces**: Application services instrumented with the X-Ray SDK send trace segments to the X-Ray daemon running as a DaemonSet. The daemon batches and forwards segments to the X-Ray service endpoint.

4. **Profiles**: Pyroscope server scrapes profiling endpoints from annotated pods. Profiles are stored locally with S3 for long-term retention.

## Retention Policies

| Data Type | Hot Storage | Warm Storage | Cold/Archive | Total Retention |
|-----------|-------------|-------------|--------------|-----------------|
| Metrics (Prometheus) | 15 days (local SSD) | 90 days (Thanos S3) | 1 year (S3 Glacier) | 1 year |
| Logs (OpenSearch) | 7 days (hot nodes) | 30 days (warm nodes) | 1 year (S3 via ISM) | 1 year |
| Logs (S3 raw) | -- | 90 days (S3 Standard) | 7 years (S3 Glacier) | 7 years |
| Traces (X-Ray) | 30 days (X-Ray service) | -- | -- | 30 days |
| Profiles (Pyroscope) | 7 days (local) | 30 days (S3) | -- | 30 days |

The 7-year retention for raw logs in S3 Glacier satisfies PCI-DSS audit trail requirements for payment processing systems.

## Cost Considerations

### Prometheus + Thanos vs. Managed Solutions

| Component | Monthly Estimate (200-node peak) | Notes |
|-----------|----------------------------------|-------|
| Prometheus (2 replicas) | $0 (OSS) + ~$400 compute | 2x m6i.xlarge for Prometheus pods |
| Thanos (store, compact, query) | $0 (OSS) + ~$200 compute | Shared node pool |
| S3 storage (metrics) | ~$50/month | ~500GB compressed, S3 Standard |
| **Total** | **~$650/month** | |
| Datadog equivalent | **~$6,000-15,000/month** | $23/host/month infrastructure + $15/host/month APM, variable node count |

### Fluent Bit + OpenSearch vs. CloudWatch Logs

| Component | Monthly Estimate | Notes |
|-----------|------------------|-------|
| Fluent Bit | $0 (OSS) | Negligible DaemonSet overhead |
| OpenSearch (3 hot + 2 warm) | ~$1,200/month | m6g.xlarge.search instances |
| S3 archive | ~$100/month | Raw logs, lifecycle to Glacier |
| **Total** | **~$1,300/month** | |
| CloudWatch Logs equivalent | **~$3,000-5,000/month** | $0.50/GB ingestion at ~200GB/day |

### Key Savings Levers

- **Prometheus recording rules** pre-aggregate high-cardinality metrics, reducing Thanos storage by ~60%
- **Fluent Bit sampling** for debug-level logs in non-production namespaces
- **S3 Intelligent-Tiering** for metric blocks older than 30 days
- **OpenSearch ISM policies** automatically migrate indices from hot to warm to S3
