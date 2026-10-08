#!/usr/bin/env bash
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl --kubeconfig=${KUBECONFIG:-/etc/kubernetes/admin.conf}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/docs/evidence/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${OUT}"

run() { echo "==> $1"; bash -c "$1" > "${OUT}/$2" 2>&1 || true; }

run "${KUBECTL} get nodes -o wide"                                   01-nodes.txt
run "${KUBECTL} get pods -A -o wide"                                 02-pods-all.txt
run "${KUBECTL} get events -A --sort-by=.lastTimestamp | tail -80"   03-events.txt
run "${KUBECTL} get applications.argoproj.io -n argocd -o wide"      04-argocd-apps.txt
run "${KUBECTL} get kafka,kafkanodepool,kafkatopic -n kafka -o wide" 05-kafka.txt
run "${KUBECTL} get kafkabrokers -n kafka -o yaml"                   06-kafka-brokers.txt
run "${KUBECTL} -n monitoring get prometheusrule,servicemonitor"     07-monitoring-crds.txt
run "${KUBECTL} -n monitoring get prometheus -o yaml | grep -A5 status" 08-prometheus-status.txt
run "${KUBECTL} get peerauthentications -A -o wide"                  09-mtls-policy.txt
run "${KUBECTL} -n istio-system get pods"                            10-istio.txt
run "${KUBECTL} -n vault get pods"                                   11-vault-pods.txt
run "${KUBECTL} -n ingress-nginx get pods,svc"                       12-ingress.txt
run "${KUBECTL} -n apps get pods -o wide"                            13-apps.txt
run "${KUBECTL} -n apps logs -l app=producer --tail=100"             14-producer-logs.txt
run "${KUBECTL} -n apps logs -l app=consumer --tail=100"             15-consumer-logs.txt

run "${KUBECTL} -n monitoring exec statefulset/prometheus-kube-prometheus-stack-prometheus -- \
     promtool query alerts http://localhost:9090 | grep -E 'Severity|State' || true"   16-alerts.txt

for pair in "lb-api-1:${API_MASTER_IP:-}" "lb-ing-1:${ING_MASTER_IP:-}"; do
  name="${pair%%:*}"; ip="${pair##*:}"
  [ -z "${ip}" ] && continue
  run "ssh -o StrictHostKeyChecking=no root@${ip} 'systemctl is-active haproxy keepalived; ip -br addr | grep -E \"${API_VIP:-x}|${ING_VIP:-x}\" || true; printf \"show stat\n\" | socat stdio /var/run/haproxy.sock | head -20'" "17-${name}-lb.txt"
done

echo "==> Evidence written to: ${OUT}"
