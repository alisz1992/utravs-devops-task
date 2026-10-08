#!/usr/bin/env bash
set -euo pipefail

API_VIP="${API_VIP:?set API_VIP (the API VIP address)}"
API_MASTER_IP="${API_MASTER_IP:?set API_MASTER_IP (lb-api-1 address)}"
CP1_IP="${CP1_IP:?set CP1_IP (control-plane node to stop)}"
SSH_USER="${SSH_USER:-root}"
EVIDENCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docs/evidence"
LOG="${EVIDENCE_DIR}/api-failover-$(date +%Y%m%d-%H%M%S).log"
PROBE_LOG="${LOG}.probes"
mkdir -p "${EVIDENCE_DIR}"

exec > >(tee -a "${LOG}") 2>&1
echo "=== kube-apiserver failover test - $(date -u +%FT%TZ) ==="
echo "VIP=${API_VIP}  master=${API_MASTER_IP}  cp=${CP1_IP}"

ssh_opts=(-o StrictHostKeyChecking=no -o ConnectTimeout=5)

probe() {
  while true; do
    ts=$(date +%s.%N)
    if curl -sk --max-time 2 "https://${API_VIP}:6443/readyz" >/dev/null 2>&1; then
      echo "${ts} OK" >> "${PROBE_LOG}"
    else
      echo "${ts} FAIL" >> "${PROBE_LOG}"
    fi
    sleep 0.5
  done
}
probe &
PROBE_PID=$!
trap 'kill ${PROBE_PID} 2>/dev/null || true' EXIT

echo "--- collecting BEFORE state"
kubectl get nodes -o wide | tee /dev/stderr
sleep 10

measure() {
  awk '{ if ($2=="FAIL") { if (!in_fail) { start=$1; in_fail=1 } } else { if (in_fail) { d=$1-start; if (d>max) max=d; in_fail=0 } } } END { if (in_fail) { d=$1-start; if (d>max) max=d } printf "longest outage: %.1f s\n", max+0 }' "${PROBE_LOG}"
}

echo "--- SCENARIO A: stopping keepalived+haproxy on API LB MASTER ${API_MASTER_IP}"
STOP_TS=$(date +%s)
ssh "${ssh_opts[@]}" "${SSH_USER}@${API_MASTER_IP}" "systemctl stop keepalived haproxy"
echo "    stopped at $(date -u +%FT%TZ) - VIP should move to the BACKUP node"
sleep 15
echo "--- AFTER A"
kubectl get nodes >/dev/null && echo "    kubectl through VIP: OK"
measure
echo "    restarting services (recovery)"
ssh "${ssh_opts[@]}" "${SSH_USER}@${API_MASTER_IP}" "systemctl start haproxy keepalived"
sleep 10

echo "--- SCENARIO B: stopping kubelet on Control Plane ${CP1_IP}"
ssh "${ssh_opts[@]}" "${SSH_USER}@${CP1_IP}" "systemctl stop kubelet && crictl stop \$(crictl ps -q --name kube-apiserver) || true"
sleep 15
echo "--- AFTER B"
kubectl get nodes -o wide | grep -E "NAME|$(echo "${CP1_IP}" | cut -d. -f4)" || true
kubectl get --raw /readyz && echo "    API still healthy through VIP: OK"
measure

echo "--- recovery: restarting kubelet on ${CP1_IP}"
ssh "${ssh_opts[@]}" "${SSH_USER}@${CP1_IP}" "systemctl start kubelet"
sleep 20
kubectl get nodes -o wide

kill ${PROBE_PID} 2>/dev/null || true
echo "=== test finished - evidence: ${LOG} and ${PROBE_LOG} ==="
