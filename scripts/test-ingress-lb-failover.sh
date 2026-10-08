#!/usr/bin/env bash
set -euo pipefail

ING1="${ING1:-95.182.87.236}"
ING2="${ING2:-217.60.5.153}"
VIP="${VIP:-95.182.87.250}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10}"
EVIDENCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docs/evidence"
LOG="${EVIDENCE_DIR}/ingress-lb-failover-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${EVIDENCE_DIR}"
exec > >(tee -a "${LOG}") 2>&1
echo "=== Ingress LB failover test - $(date -u +%FT%TZ) ==="

ssh_run() {
  ssh ${SSH_OPTS} "root@$1" "$2"
}

H1=$(ssh_run "$ING1" "ip -4 addr show | grep -c ${VIP} || true" || true)
H2=$(ssh_run "$ING2" "ip -4 addr show | grep -c ${VIP} || true" || true)
echo "    vip holder probe: ing1=${H1:-?} ing2=${H2:-?}"
if [ "${H1:-0}" -ge 1 ]; then MASTER=$ING1; BACKUP=$ING2; else MASTER=$ING2; BACKUP=$ING1; fi
echo "    master=$MASTER backup=$BACKUP"

echo "--- probing VIP from BACKUP while stopping the MASTER (80 x 0.5s)"
ssh_run "$BACKUP" 'for i in $(seq 1 80); do if curl -s -o /dev/null -m 2 http://'"$VIP"':80/ 2>/dev/null || timeout 2 bash -c ">/dev/tcp/'"$VIP"'/80" 2>/dev/null; then echo OK; else echo FAIL; fi; sleep 0.5; done' > /tmp/sc5_probes.txt &
PROBER=$!
sleep 2
echo "--- stopping keepalived+haproxy on MASTER $MASTER"
ssh_run "$MASTER" "systemctl stop keepalived haproxy; date -u +%FT%TZ"
sleep 12
echo "--- restarting services on MASTER $MASTER (fail-back)"
ssh_run "$MASTER" "systemctl start haproxy keepalived; date -u +%FT%TZ"
sleep 8
wait $PROBER 2>/dev/null || true
echo "--- probe results"
awk '/^FAIL/{c++; if(c>m)m=c; next} {c=0} END{printf "    longest outage: %.1f s (%d consecutive FAILs)\n", m*0.5, m}' /tmp/sc5_probes.txt
echo "    OK probes:   $(grep -c '^OK$' /tmp/sc5_probes.txt || true)"
echo "    FAIL probes: $(grep -c '^FAIL$' /tmp/sc5_probes.txt || true)"
echo "--- VIP owner after recovery"
ssh_run "$ING1" "ip -4 addr show | grep ${VIP} || echo '    not on ing1'"
ssh_run "$ING2" "ip -4 addr show | grep ${VIP} || echo '    not on ing2'"
sleep 3
echo "=== test finished - evidence: ${LOG} ==="
