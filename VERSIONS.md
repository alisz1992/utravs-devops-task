# Version Catalog (VERSIONS) - environment reproducibility

> All versions are **pinned** so the evaluator can reproduce the environment exactly.
> If a pinned version is unavailable in the repository, a stable equivalent is used
> and **this file** is updated accordingly.

---

## 1. Infrastructure (9 servers - same location, same OS)

| Role | Count | Minimum resources | Operating system |
|---|---|---|---|
| Control Plane (stacked etcd) | 3 | 2 vCPU / 4 GB / 40 GB | Ubuntu 22.04 LTS |
| Worker | 2 | 4 vCPU / 16 GB / 160 GB | Ubuntu 22.04 LTS |
| LB - API | 2 | 1-2 vCPU / 2 GB / 20 GB | Ubuntu 22.04 LTS |
| LB - Ingress | 2 | 1-2 vCPU / 2 GB / 20 GB | Ubuntu 22.04 LTS |




---

## 2. Server Software Versions

| Component | Pinned version | Installed on |
|---|---|---|
| Kubernetes (kubeadm/kubelet/kubectl) | **1.31.x** (`1.31.4-1.1` apt) | all K8s nodes |
| containerd | **1.7.x** (`1.7.27-1` from the Docker repo) | Control Plane + Workers |
| runc | bundled with containerd.io | Control Plane + Workers |
| etcd (stacked) | **3.5.x** - ships with Kubernetes 1.31 (static pods) | 3 control-plane nodes |
| CNI: Cilium | **1.16.x** (`v1.16.6`) | cluster (bootstrap via Ansible) |
| HAProxy | **2.4.x** (Ubuntu 22.04 repo) | 4 LB nodes |
| Keepalived | **2.2.x** (Ubuntu 22.04 repo) | 4 LB nodes |
| Helm | **3.16.x** (`3.16.4`) | operator + cluster |
| ArgoCD | **2.13.x** | cluster (GitOps) |
| Istio | **1.24.x** | cluster (GitOps) |
| Kafka: Strimzi Operator | **0.4x.x** (KRaft) | cluster (GitOps) |
| Vault | **1.18.x** | cluster (GitOps) |
| kube-prometheus-stack | **6x.x** | cluster (GitOps) |
| OpenTelemetry Collector | chart **0.112.0** → app/image **0.116.1** | cluster (GitOps) |
| Jaeger | **1.6x.x** | cluster (GitOps) |
| ingress-nginx | **1.11.x / 1.12.x** | cluster (GitOps) |
| local-path-provisioner | **v0.0.37** | cluster (GitOps, storage) |

---

## 3. Operator Prerequisites

| Tool | Version | Notes |
|---|---|---|
| python3 | >= 3.10 | ansible prerequisite |
| ansible-core | >= 2.17 | `pip3 install ansible-core` + `ansible-galaxy collection install -r ansible/collections/requirements.yml` |
| openssh-client | any stable | connections to servers |
| git | >= 2.30 | push to GitHub |
| helm (optional) | 3.16.x | ad-hoc chart management |

---

## 4. Architecture Choices and Rationale

| Choice | Rationale |
|---|---|
| **kubeadm** | official CNCF standard for On-Premise clusters; full control over PKI and HA |
| **stacked etcd** (kubeadm default) | provider caps instances at 10 per region and the assignment only demands 3 CP + 2 workers; kubeadm owns etcd PKI, snapshots and recovery. *Production alternative: external etcd on 3 dedicated nodes (resource isolation, independent scaling) - this repo's original design, dropped for the lab* |
| **HAProxy + Keepalived** | the exact solution suggested by the task, lightweight and automatable |
| **Cilium** instead of Calico | network policies + Hubble for network observability (bonus points) |
| **Strimzi Operator** instead of a plain Kafka chart | a reputable Operator (explicitly allowed by the task) with professional version lifecycle, reconciliation and failover handling |
| **Raft Vault, 3 nodes** | HA requirement and failover test of the task |
| **Private GitHub** | GitOps without consuming server resources (zero cost) |
