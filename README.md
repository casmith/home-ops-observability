# home-ops-observability

Dedicated 3-node Talos Kubernetes cluster for monitoring the main `home-ops` cluster. This cluster runs Prometheus, Grafana, and Loki to provide comprehensive observability.

## Cluster Details

- **Cluster Name**: observability
- **Nodes**: 3 control plane nodes (all schedulable)
  - obs-cp-1: 192.168.10.47
  - obs-cp-2: 192.168.10.48
  - obs-cp-3: 192.168.10.49
- **Kubernetes API VIP**: 192.168.10.244
- **Gateway VIP (Internal)**: 192.168.10.242
- **Gateway VIP (External)**: 192.168.10.241
- **Domain**: obs.kalde.in
- **Pod CIDR**: 10.52.0.0/16
- **Service CIDR**: 10.53.0.0/16

## Storage

- **NFS Server**: 192.168.10.3
- **NFS Path**: /volume1/cluster/*
  - Grafana: /volume1/cluster/grafana
  - Prometheus: /volume1/cluster/prometheus
  - Loki: /volume1/cluster/loki

## Prerequisites

Before bootstrapping the cluster, ensure you have:

1. **VM Infrastructure**:
   - 3 VMs created with IPs 192.168.10.47-49
   - 4 cores / 8 GB RAM / 50 GB SSD per node
   - Talos Linux ISO booted on all nodes

2. **Network Configuration**:
   - VIPs (.244, .242, .241) available
   - NFS share created at 192.168.10.3:/volume1/cluster/
   - DNS entries for *.obs.kalde.in pointing to gateway VIP

3. **Local Workstation**:
   - mise installed and trusted
   - GitHub CLI authenticated
   - Cloudflare API token ready

## Bootstrap Process

### Stage 1: Prepare Secrets

1. **Add Cloudflare credentials** to `kubernetes/components/common/sops/cluster-secrets.sops.yaml`:
   ```yaml
   SECRET_CLOUDFLARE_EMAIL: your-email@example.com
   SECRET_CLOUDFLARE_API_TOKEN: your-cloudflare-token
   ```

2. **Encrypt SOPS secrets**:
   ```bash
   sops -e -i kubernetes/components/common/sops/cluster-secrets.sops.yaml
   sops -e -i kubernetes/components/common/sops/sops-age.sops.yaml
   ```

3. **Create GitHub deploy key**:
   ```bash
   ssh-keygen -t ed25519 -f github-deploy.key -C "flux-observability"
   # Add github-deploy.key.pub as a deploy key to your GitHub repo (read/write access)
   ```

4. **Create GitHub deploy key secret**:
   ```bash
   cat > bootstrap/github-deploy-key.sops.yaml <<EOF
   apiVersion: v1
   kind: Secret
   metadata:
     name: flux-system
     namespace: flux-system
   stringData:
     identity: |
   $(cat github-deploy.key | sed 's/^/      /')
     identity.pub: $(cat github-deploy.key.pub)
     known_hosts: |
       github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
   EOF

   sops -e -i bootstrap/github-deploy-key.sops.yaml
   rm github-deploy.key github-deploy.key.pub
   ```

### Stage 2: Bootstrap Talos

1. **Install tools**:
   ```bash
   cd ~/work/home-ops-observability
   mise trust
   mise install
   ```

2. **Generate Talos configuration**:
   ```bash
   task talos:generate-config
   ```

3. **Bootstrap Talos nodes**:
   ```bash
   task bootstrap:talos
   ```

4. **Verify cluster is up**:
   ```bash
   talosctl health --nodes 192.168.10.47,192.168.10.48,192.168.10.49
   kubectl get nodes
   ```

5. **Commit encrypted secrets**:
   ```bash
   git add talos/talsecret.sops.yaml
   git commit -m "chore: add talhelper encrypted secret"
   git push
   ```

### Stage 3: Bootstrap Applications

1. **Bootstrap core apps** (Cilium, CoreDNS, Flux):
   ```bash
   task bootstrap:apps
   ```

2. **Watch Flux reconcile**:
   ```bash
   watch flux get kustomizations -A
   ```

3. **Verify core components**:
   ```bash
   cilium status
   flux check
   kubectl get pods -n flux-system
   ```

### Stage 4: Deploy Monitoring Stack

The monitoring applications will be deployed via Flux once you add them to `kubernetes/apps/`.

**TODO**: You still need to create the application manifests for:
- NFS CSI provisioner or nfs-subdir-external-provisioner
- kube-prometheus-stack (with federation config)
- Grafana Operator + Grafana instance
- Loki
- Cilium Gateway (internal & external)
- cert-manager

Refer to the plan at `.claude/plans/linked-swimming-squid.md` for detailed implementation steps.

## Monitoring Configuration

### Prometheus Federation

Prometheus in this cluster will federate metrics from the main cluster at `prometheus.kalde.in`.

### Loki Log Aggregation

Loki will store logs from both clusters. Deploy Promtail on the main cluster pointing to this Loki instance.

### Grafana Access

Once deployed, Grafana will be accessible at: **https://grafana.obs.kalde.in**

## Maintenance

### Force Flux Reconciliation

```bash
task reconcile
```

### Upgrade Talos

```bash
# Update talos/talenv.yaml with new version
task talos:upgrade-node IP=192.168.10.47
task talos:upgrade-node IP=192.168.10.48
task talos:upgrade-node IP=192.168.10.49
```

### Upgrade Kubernetes

```bash
# Update talos/talenv.yaml with new k8s version
task talos:upgrade-k8s
```

## Age Encryption Key

The age public key for this cluster is:
```
age189gqacgyls7puscnagahv8m0synjs3v8hkn8ur8w4c56g9vpdccshj2400
```

The private key is stored in `age.key` (gitignored).

**IMPORTANT**: Back up your `age.key` file securely. Without it, you cannot decrypt your secrets!

## Architecture

This cluster is designed to be independent from the main cluster to ensure monitoring survives main cluster failures.

- **Separate network CIDRs** prevent IP conflicts
- **External storage (NFS)** allows long-term metrics retention
- **Federation** pulls metrics from main cluster Prometheus
- **3-node HA** ensures observability during node failures

## Next Steps

1. Create application manifests in `kubernetes/apps/`
2. Configure NFS storage provisioner
3. Deploy kube-prometheus-stack with federation
4. Deploy Grafana and configure datasources
5. Deploy Loki for log aggregation
6. Configure Cilium Gateway for ingress
7. Set up cert-manager for TLS certificates

See the detailed plan in `.claude/plans/linked-swimming-squid.md` for step-by-step implementation guidance.
