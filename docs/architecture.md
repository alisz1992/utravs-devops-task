# Architecture

Event-driven platform on Kubernetes with high availability, deployed entirely
as code (Ansible for the infrastructure, ArgoCD/GitOps for everything inside
the cluster).

## 1. Global view (9 nodes)

```mermaid
flowchart TB
    subgraph EDGE["Edge / Load balancing - 4 nodes"]
        direction LR
        V1(["VIP-API<br/>:6443"]) --> A1["lb-api-1<br/>HAProxy+Keepalived<br/>MASTER"]
        V1 --> A2["lb-api-2<br/>HAProxy+Keepalived<br/>BACKUP"]
        V2(["VIP-Ingress<br/>:80/:443"]) --> I1["lb-ing-1<br/>MASTER"]
        V2 --> I2["lb-ing-2<br/>BACKUP"]
    end
    subgraph CP["Control Plane - 3 nodes, stacked etcd (Quorum 2/3)"]
        C1[cp1] --- C2[cp2] --- C3[cp3]
    end
    subgraph W["Workers - 2 nodes"]
        direction TB
        ING["ingress-nginx (NodePort 30080/30443)"]
        KAFKA["Kafka x3 (Strimzi/KRaft)<br/>+ kafka-exporter"]
        VAULT["Vault x3 (Raft HA)"]
        MESH["Istio istiod + sidecars (mTLS STRICT)"]
        OBS["Prometheus + Alertmanager + Grafana<br/>Jaeger + OTel Collector"]
        CD["ArgoCD"]
        APPS["producer + consumer"]
    end
    A1 & A2 -->|/healthz TLS| C1 & C2 & C3
    I1 & I2 -->|TCP health check| ING
    ING --> APPS
    APPS --> KAFKA
    APPS --> VAULT
    APPS & KAFKA & VAULT -. "mTLS in-mesh" .- MESH
    APPS -->|"OTLP traces"| OBS
```

## 2. Traffic paths

```mermaid
flowchart LR
    subgraph kubectlPath["kubectl path"]
        K[kubectl] --> KV["VIP-API :6443"] --> H1["HAProxy pair<br/>GET /healthz"] --> CP["healthy CP<br/>kube-apiserver"] --> ET2["stacked etcd<br/>local TLS"]
    end
    subgraph ingressPath["service ingress path"]
        B[browser] --> IV["VIP-Ingress :443"] --> H2["HAProxy pair<br/>TCP check"] --> NG[ingress-nginx<br/>NodePort] --> SVC[producer / consumer<br/>ClusterIP]
    end
```

## 3. Delivery pipeline (GitOps)

```mermaid
flowchart LR
    DEV[developer] -->|"git push"| GH[(private GitHub)]
    GH -->|"webhook/poll"| ARGO[ArgoCD]
    ARGO -->|"sync"| K8S[Kubernetes resources]
    ARGO -.->|"drift detection"| K8S
    ANS[Ansible<br/>operator host] -->|"bootstrap"| INFRA["OS, containerd,<br/>kubeadm, LB"]
    INFRA --> K8S
    ANS -.->|"CNI only"| K8S
```

- **Bootstrap (one-time, scripted):** `ansible/playbooks/site.yml` →
  `gitops/argocd/bootstrap/install-argocd.sh` → `scripts/setup-vault.sh`
- **Steady state:** every change goes through Git; ArgoCD reconciles and prunes
  drift. Manual `kubectl apply` is never part of the normal path.

## 4. Security architecture

| Layer | Mechanism |
|---|---|
| East-west traffic | Istio **mTLS STRICT** (mesh-wide `PeerAuthentication`) |
| Ingress edge | ingress-nginx stays **outside** the mesh (it must take plain HTTP from HAProxy/VIP clients and addresses backends by pod IP with the original Host), so the four ingress-exposed workloads carry a workload-scoped **PERMISSIVE** `PeerAuthentication` (`allow-ingress-plaintext-{jaeger,producer,consumer,vault}`) - everything else, and all meshed-to-meshed traffic, stays STRICT |
| Secrets | HashiCorp **Vault (3-node Raft HA)** + Kubernetes auth, short TTL (1h) roles |
| Secret delivery | Vault **Agent sidecar injection** - secrets exist only at runtime (`/vault/secrets/...`) |
| Git hygiene | No secret in Git/Helm values/ConfigMaps (enforced by `.gitignore` + review) |
| Rotation | `scripts/rotate-secret.sh` - new value without redeploying |
| Edge | HAProxy with TLS health checks; API certificate SANs include the VIP |
| Workload | non-root securityContext, dropped capabilities, resource limits |

## 5. Observability architecture

```mermaid
flowchart LR
    subgraph producers["signal producers"]
        P[producer app] -->|"OTLP traces"| COL[OTel Collector]
        C[consumer app] -->|"OTLP traces"| COL
        KF[kafka-exporter] -->|"/metrics"| PROM[Prometheus]
        V[vault :9102] -->|"/metrics"| PROM
        NODE[node-exporter / kube-state] --> PROM
        ISTIO[istio metrics] --> PROM
    end
    COL --> JAEGER[Jaeger UI - end-to-end trace]
    PROM --> AM[Alertmanager]
    PROM --> G[Grafana]
```

**Required critical alerts** (in `gitops/components/monitoring/prometheus-rules.yaml`):

1. `KafkaConsumerLagCritical` - consumer lag > 10000 for 5m
2. `VaultSealedCritical` - `vault_core_unsealed == 0` for 2m
3. `IstioMeshHighErrorRate` - mesh 5xx rate > 5% for 5m

Bonus: `IstiodDown`, `KafkaBrokerDown`, `KubeApiServerHighErrorRate`,
`IstioPodWithoutSidecarTraffic` (mTLS bypass detection).

## 6. Message path semantics

- **Delivery: at-least-once.** Producer: `acks=all` + idempotent producer +
  retries. Consumer: `enable.auto.commit=false`, offset committed **after**
  processing, and an idempotency buffer ignores redelivered ids.
- Traces travel in Kafka headers → one end-to-end trace across services.
