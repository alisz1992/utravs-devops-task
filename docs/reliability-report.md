# Reliability Report

> Evidence-driven report of the controlled failure scenarios. Every scenario
> follows the same structure: **before / during / after + recovery time**.
> Raw outputs collected by `scripts/collect-evidence.sh` and the individual
> test scripts live in [`evidence/`](evidence/).

**Cluster:** utravs-event-cluster - 4 LB + 3 CP (stacked etcd) + 2 workers
**Date:** 2026-10-07 | **Operator:** automated evidence collection (scripts/)

---

## Summary

| # | Scenario | Result | Recovery time | Evidence |
|---|---|---|---|---|
| 1 | API LB MASTER down (keepalived+haproxy stopped) | PASSED | **0.0 s** (no failed probe) | `evidence/api-failover-20261007-101923.log` |
| 2 | One Control Plane node stopped (kubelet down) | PASSED | **2.5 s** | `evidence/api-failover-20261007-101923.log` |
| 3 | Kafka leader broker killed | PASSED | **20 s** leader election / **63 s** all 3 brokers Ready | `evidence/kafka-failover-20261007-123456.log` |
| 4 | Active Vault node stepped down | PASSED | **9 s** | `evidence/vault-failover-20261007-114000.log` |
| 5 | Ingress LB MASTER down (keepalived+haproxy stopped) | PASSED | **0.5 s** (1 failed probe of 80, across failover AND fail-back) | `evidence/ingress-lb-failover-20261007.log` |

---

## Scenario 1+2 - Kubernetes API availability

**How:** `scripts/test-k8s-api-failover.sh` probes
`https://<VIP>:6443/readyz` every 500 ms while:
A) `systemctl stop keepalived haproxy` runs on `lb-api-1` (VIP holder),
B) `systemctl stop kubelet` runs on a Control Plane node.

| Check | Before | During | After |
|---|---|---|---|
| `kubectl get nodes` via VIP | OK | must recover ≤ seconds | OK |
| VIP owner | lb-api-1 | lb-api-2 (VRRP takeover) | lb-api-1 (nopreempt) |
| API `/readyz` | 200 | short FAIL window, then 200 | 200 |

**Measured outage window:**

| Sub-scenario | Longest failed-probe window | Result |
|---|---|---|
| A - keepalived+haproxy stopped on the API LB MASTER (`95.182.116.206`) | **0.0 s** | `kubectl` through the endpoint stayed OK; the VIP moved to `lb-api-2` with zero failed probes (VRRP advertisement interval is faster than the 500 ms probe) |
| B - kubelet stopped on control-plane `104.253.79.218` (cp2) | **2.5 s** | API stayed healthy through the endpoint; HAProxy health-check (`GET /healthz`) pulled the dead apiserver out of the pool, probes recovered after 2.5 s |

After recovery all 5 nodes returned to `Ready` and the kubelet restart on cp2
rejoined without any manual intervention.

**Why it works:** HAProxy health-checks each apiserver with `GET /healthz`
over TLS, so an apiserver whose etcd path is broken also leaves the pool;
Keepalived moves the VIP to the peer whose haproxy process is alive.

---

## Scenario 3 - Kafka leader broker failure

**How:** `scripts/test-kafka-leader-failover.sh` resolves the leader of
topic `orders`, deletes that broker pod, then polls for a new leader.

| Check | Before | During | After |
|---|---|---|---|
| Leader pod | e.g. kafka-1 | election in progress | new pod id |
| `kafka_brokers` metric | 3 | 2 | 3 |
| Consumer lag | low | bounded growth | decreasing again |
| Producer/Consumer logs | producing | retry (idempotent) | producing |

**Measured failover time:**

| Check | Before | During | After |
|---|---|---|---|
| Leader pod | `utravs-kafka-dual-role-pool-2` | deleted at `12:35:11Z` | new leader `utravs-kafka-dual-role-pool-0` (elected ≤ **20 s**) |
| Ready broker pods (kubectl) | 3 | 2 | 3 (all Ready again after **63 s**) |
| Consumer lag (kafka-consumer-groups CLI) | 0–5 | bounded | 2 + 5 across partitions (caught up immediately) |
| Producer/Consumer logs | producing | retry (idempotent) | producing - no message loss |

- **New leader elected:** observed 20 s after the kill (KRaft election + metadata
  propagation on the client side).
- **Full cluster recovery:** all 3 brokers `2/2 Running` again 63 s after the kill
  (pod re-scheduling + broker start + partition re-join).
- **Consumer group `orders-consumers-prod`** kept its offsets; post-failover
  `--describe` shows `CURRENT-OFFSET` ≈ `LOG-END-OFFSET` on every partition.

**Delivery semantics:** at-least-once - with `acks=all` + idempotent producer
the retry window may redeliver; consumers deduplicate by message id
(logs show `duplicate message id=... ignored (idempotent)` during the window).

> **Note on metrics:** `kafka-exporter` metrics are not reachable from node
> networks (in-mesh ClusterIP only), so the test validates lag **via the Kafka
> CLI** (`bin/kafka-consumer-groups.sh --describe`) and broker count via
> `kubectl get pods` - no phantom zeroes in the evidence.

---

## Scenario 4 - Active Vault node failure

**How:** `scripts/test-vault-failover.sh` runs `vault operator step-down` on
the raft leader and continuously reads `kv/data/producer` through every node.

| Check | Before | During | After |
|---|---|---|---|
| Active node | vault-0 | election (~seconds) | vault-1/2 |
| Secret readable | OK | OK (brief retry) | OK |
| Sealed nodes | 0 | 0 | 0 |
| App pods restarts | 0 | 0 | 0 |

**Measured failover time: 9 s** (step-down at `11:40:06Z` → new active node
answering reads 9 s later).

| Check | Before | During | After |
|---|---|---|---|
| Active node | vault-0 | election (~seconds) | **vault-2** |
| Secret read (`kv/data/producer`) | OK | OK (continuous polling, no failed read) | OK |
| Sealed nodes | 0 | 0 | 0 |
| App pods restarts | 0 | 0 | **0** (all 4 pods `2/2 Running`, `RESTARTS 0`) |

---

## Scenario 5 - Ingress LB MASTER failure

**How:** `scripts/test-ingress-lb-failover.sh` probes `http://<ingress_vip>:80`
every 500 ms **from the BACKUP LB member** while `systemctl stop keepalived haproxy`
runs on the current VIP holder, then restarts the services and keeps probing
through the fail-back as well.

| Check | Before | During | After |
|---|---|---|---|
| VIP owner | lb-ing-2 (`217.60.5.153`) | lb-ing-1 (VRRP takeover) | re-elected owner, VIP bound again |
| HTTP probe via VIP | OK | ≤ 1 failed probe | OK |

**Measured outage window: 0.5 s** - 79/80 probes succeeded across the whole
failover *and* fail-back window. The single failed probe is the VRRP
advertisement + gratuitous-ARP refresh on the new owner; both VRRP moves
(owner → backup and back) stayed within one 500 ms probe interval.

`ingress-nginx` kept serving HTTP on both ports throughout; no pod restarts were
triggered by the VIP move.

---

## Security assertions during failures

Verified in every scenario (checked by `collect-evidence.sh` output `09-mtls-policy.txt`):

- The mesh-wide `PeerAuthentication` remains **STRICT** - no PERMISSIVE fallback was introduced during these runs (2026-10-07). Since 2026-10-08 four *workload-scoped* PERMISSIVE policies exist for the ingress-exposed backends only (see docs/architecture.md §4); they do not change any of the measurements above.
- No secret was copied into ConfigMaps/Helm values during recovery.
- `mTLS bypass` alert (`IstioPodWithoutSidecarTraffic`) stayed silent.

---

## How to reproduce

```bash
./scripts/test-k8s-api-failover.sh      # scenarios 1+2
./scripts/test-kafka-leader-failover.sh # scenario 3
./scripts/test-vault-failover.sh        # scenario 4
./scripts/test-ingress-lb-failover.sh   # scenario 5
./scripts/collect-evidence.sh           # snapshot for the report
```
