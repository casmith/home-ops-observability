# Loki Scaling & Performance Guide

## Summary of Changes

### 1. New Loki Performance Dashboard
Created a comprehensive Grafana dashboard (`loki-performance.yaml`) that monitors:
- Pod status and health
- Memory and CPU usage with gauges showing percentage of limits
- Ingestion rate (logs/sec)
- Request rate by route
- Request latency (p99)
- Flush queue length (key indicator of backlog)
- Cache hit rates
- Disk usage

**Access**: Navigate to Grafana at `https://grafana-obs.kalde.in` and look for "Loki Performance & Health" dashboard.

### 2. Increased Loki Resources

**Previous Configuration:**
- CPU: 100m request, no limit
- Memory: 512Mi request, 2Gi limit

**New Configuration:**
- CPU: 500m request, 2000m (2 cores) limit
- Memory: 2Gi request, 6Gi limit

This provides **3x more memory** and establishes proper CPU limits to handle multiple Promtail connections.

### 3. Increased Ingestion Limits

Added the following limits to handle multiple Promtail instances:
- `ingestion_rate_mb`: 20MB/s per tenant
- `ingestion_burst_size_mb`: 30MB burst capacity
- `per_stream_rate_limit`: 10MB/s per stream
- `per_stream_rate_limit_burst`: 20MB burst per stream
- `max_streams_per_user`: 0 (unlimited)
- `max_global_streams_per_user`: 0 (unlimited)

## Deployment

Apply the changes using Flux:
```bash
# Flux will automatically detect and apply the changes
# You can force reconciliation with:
flux reconcile kustomization observability-loki
flux reconcile helmrelease -n observability loki

# Monitor the rollout
kubectl rollout status deployment/loki -n observability
```

## Monitoring the Fix

### Key Metrics to Watch

1. **Memory Usage**: Should stay well below 6Gi. If consistently above 4-5Gi, further scaling needed.
2. **Ingestion Rate**: Monitor for drops or spikes
3. **Flush Queue Length**: Should remain low (< 100). High values indicate ingestion backlog.
4. **Request Latency**: p99 should be < 1s for healthy operation
5. **Pod Restarts**: Should be 0 after the upgrade

### Check Promtail Connectivity

From the main cluster, verify Promtail can connect:
```bash
# Check Promtail logs for connection errors
kubectl logs -n observability -l app=promtail --tail=100

# Test DNS resolution
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup loki-obs.kalde.in

# Test HTTP connectivity
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- curl -v http://loki-obs.kalde.in/ready
```

## If Single Binary Still Struggles

If you continue to see connection failures or OOM kills, consider migrating to **distributed mode** with horizontal scaling:

### Option A: SimpleScalable Mode (Recommended for Medium Load)

This mode splits Loki into read and write paths with separate scaling:

```yaml
deploymentMode: SimpleScalable

write:
  replicas: 3  # Scale write path for ingestion
  resources:
    requests:
      cpu: 500m
      memory: 2Gi
    limits:
      cpu: 1000m
      memory: 4Gi

read:
  replicas: 2  # Scale read path for queries
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 1000m
      memory: 2Gi

backend:
  replicas: 1  # Backend for compaction, etc.
  resources:
    requests:
      cpu: 500m
      memory: 2Gi
    limits:
      cpu: 1000m
      memory: 4Gi
```

**Important**: SimpleScalable mode requires object storage (S3, MinIO, etc.) instead of filesystem storage. You'll need to set up MinIO or use cloud object storage.

### Option B: Microservices Mode (For High Load)

Full distributed architecture with separate components:
- Ingester (3+ replicas)
- Distributor (2+ replicas)
- Querier (2+ replicas)
- Query Frontend (2+ replicas)
- Compactor (1 replica)

This is overkill for most home labs but provides maximum scalability.

## Current Architecture

```
Main Cluster Promtail
    ↓ (HTTP)
loki-obs.kalde.in (192.168.10.242)
    ↓ (Internal Gateway)
loki-gateway service
    ↓
loki-0 pod (SingleBinary)
    ↓
NFS Storage (192.168.10.3:/volume1/cluster/loki)
```

## Troubleshooting

### Promtail Connection Refused
- Check if loki-gateway service exists: `kubectl get svc -n observability loki-gateway`
- Verify HTTPRoute: `kubectl get httproute -n observability loki`
- Check Pi-hole has DNS entry for loki-obs.kalde.in → 192.168.10.242

### OOMKilled Pods
- Check memory usage in dashboard
- Reduce cache sizes in helmrelease.yaml (currently 512MB + 256MB = 768MB)
- Increase memory limits further or migrate to distributed mode

### High Latency
- Check disk I/O on NFS server (192.168.10.3)
- Consider local SSD storage instead of NFS for better performance
- Enable query caching

### Ingestion Lag
- Monitor flush queue length in dashboard
- Increase ingestion limits if hitting rate limits
- Scale to SimpleScalable or Microservices mode

## Additional Optimizations

### Enable Query Parallelization
```yaml
loki:
  querier:
    max_concurrent: 4
  query_scheduler:
    max_outstanding_requests_per_tenant: 2048
```

### Tune Chunk Encoding
```yaml
loki:
  ingester:
    chunk_encoding: snappy
    chunk_idle_period: 30m
    chunk_retain_period: 1m
```

### Add Request Limits by Client
If specific Promtail instances are too aggressive:
```yaml
limits_config:
  per_stream_rate_limit: 5MB
  per_stream_rate_limit_burst: 10MB
```

## Resource Requirements Summary

| Mode | Min CPU | Min Memory | Recommended CPU | Recommended Memory |
|------|---------|------------|-----------------|-------------------|
| **SingleBinary (current)** | 500m | 2Gi | 1-2 cores | 4-6Gi |
| SimpleScalable | 1.5 cores | 5Gi | 3-4 cores | 10-12Gi |
| Microservices | 3 cores | 8Gi | 6-8 cores | 16-24Gi |

## Next Steps

1. ✅ Apply the HelmRelease changes
2. ✅ Monitor the new Loki Performance dashboard for 24-48 hours
3. ✅ Check Promtail logs for connection improvements
4. ⏳ If issues persist, plan migration to SimpleScalable mode with MinIO
