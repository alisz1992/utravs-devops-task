# Architecture decisions and Trade-offs

> The task asks what would be done **differently in production** - this file
> answers exactly that, with the reasoning behind every choice.

## 1. Decisions made in this assignment

| Decision | Why | Alternative considered |
|---|---|---|
| **kubeadm** for the cluster | official CNCF pattern for On-Premise; full control of PKI, HA and upgrade paths | k3s (too opinionated for a 3-CP exercise) |
| **Stacked etcd on the CP nodes** | assignment requires only 3 CP + 2 workers and accepts an equivalent HA design; external etcd was dropped when the provider capped instances at 10 per region - kubeadm then owns etcd PKI, snapshots and recovery for free | external etcd on 3 dedicated nodes (the first iteration of this repo): isolates the most fragile stateful component from control-plane resource pressure; our production recommendation |
| **HAProxy + Keepalived (2 pairs)** | explicitly suggested by the task; VIP semantics are easy to demonstrate and to test; unicast VRRP works on most VPS networks | DNS round-robin (slow TTL propagation), cloud LB (not On-Premise) |
| **HTTP `/healthz` check on the API pair** | a TCP check would still route to an apiserver whose etcd path is dead - exactly the failure mode of this design | TCP check (cheaper, less precise) |
| **Cilium** as CNI | network policies + Hubble for network observability (bonus), eBPF performance | Calico (also fine, weaker observability story) |
| **Strimzi Operator** for Kafka | task allows a reputable Operator; it owns rolling upgrades, node pools, failover and CRD-driven config - the GitOps-friendly way | Bitnami Kafka chart (no reconciliation of Kafka internals) |
| **KRaft (no ZooKeeper)** | ZooKeeper is removed upstream; one less quorum to operate | ZK mode (legacy) |
| **ArgoCD App-of-Apps + sync-waves** | one root Application discovers all others; waves guarantee CRD order (monitoring/istio first) | plain `argocd app apply` list (no drift semantics) |
| **Multi-source Applications** for services | chart and per-environment values are both read from Git (`$values` ref) - values never live only in the Application object | inline `helm.values` (mixes config into wiring) |
| **Vault Agent injection** | secrets arrive at runtime in an ephemeral volume; nothing static in Git/ConfigMaps; Kubernetes auth binds role→service account→namespace | K8s Secrets synced by an operator (longer-lived material on disk) |
| **mTLS STRICT mesh-wide** with sidecars on ingress-nginx | edge proxies must join the mesh, otherwise STRICT would break edge→app traffic | PERMISSIVE at the edge (weakens the security claim) |

## 2. What would change in production

| Area | This assignment | Production-grade |
|---|---|---|
| **Vault TLS** | listener TLS disabled inside the pod; encryption provided by Istio mTLS | native Vault TLS (cert-manager or Vault PKI), auto-unseal via cloud KMS or HSM, explicit seal-status monitoring |
| **Unseal material** | 5/3 keys in `vault-init.json` on the operator host | transit/CloudKMS auto-unseal; keys in a real secret manager; split knowledge |
| **Kafka auth** | internal listener without auth (mesh mTLS protects transport) | mTLS listener + SCRAM/OAuth2 (e.g. Vault or Keycloak), per-client ACLs, NetworkPolicies |
| **Registry** | public registries (Docker Hub, GHCR) | private Harbor with image signing (Cosign) and admission policy |
| **GitOps source** | GitHub | self-hosted GitLab/Gitea inside the perimeter if the platform must work air-gapped |
| **Ingress TLS** | one Let's Encrypt wildcard (`*.unit5chd.qzz.io`) via cert-manager DNS-01 (Cloudflare), served by ingress-nginx `--default-ssl-certificate`; HAProxy → controller hop still plain HTTP | per-host certificates or one per namespace, TLS re-encryption HAProxy → controller, short-lived/automated cert rotation with OCSP |
| **Monitoring** | single Prometheus, 7d retention, lab password | Thanos/Mimir long-term store, HA Alertmanager, receivers (email/Telegram), SLO dashboards, on-call routing |
| **Nodes** | 2 workers (task minimum + cost) | ≥3 workers with dedicated taints for Kafka/Vault, pod anti-affinity requiring a third replica, separate monitoring/registry nodes |
| **Backup** | none in scope | Velero for cluster state + etcd/Vault snapshots to object storage, regularly restored |
| **Upgrades** | pinned versions, manual plan | kubeadm upgrade plan + Strimzi rolling upgrades + GitOps-driven version bumps with CI checks |
| **Access** | SSH root from the operator | SSH via bastion + keys, no root login, RBAC + OIDC for Kubernetes, Ansible Vault for all secrets |
| **Policy** | securityContext/resources in charts | Kyverno/OPA gatekeeper with Policy-as-Code (image whitelist, required labels, resource quotas) - bonus item of the task |

## 3. Known limitations (transparent)

1. **VRRP between VPS nodes** depends on the provider allowing IP protocol 112
   in unicast mode. Step 0 of the runbook verifies it; if it is blocked, the
   documented equivalent is Keepalived with `check` scripts per node plus a
   DNS-based endpoint swap - the task explicitly allows an equivalent
   solution as long as it is justified.
2. **Vault agent re-render timing** for static KV secrets depends on the agent
   template refresh; `scripts/rotate-secret.sh` waits up to 10 minutes and the
   runbook documents the zero-downtime rolling fallback.
3. **Chart/operator versions** are pinned in the files; `VERSIONS.md` documents
   the verification step performed during environment bootstrap.
