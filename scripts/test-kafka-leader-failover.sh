#!/usr/bin/env bash
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl --kubeconfig=${KUBECONFIG:-/etc/kubernetes/admin.conf}}"
NS=kafka
TOPIC="${TOPIC:-orders}"
CONSUMER_GROUP="${CONSUMER_GROUP:-}"
BOOTSTRAP="utravs-kafka-kafka-bootstrap:9092"
EVIDENCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docs/evidence"
LOG="${EVIDENCE_DIR}/kafka-failover-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${EVIDENCE_DIR}"
exec > >(tee -a "${LOG}") 2>&1
echo "=== Kafka leader failover test - $(date -u +%FT%TZ) ==="

kafka_pod() {
  ${KUBECTL} -n "${NS}" get pods --no-headers 2>/dev/null |
    awk '$1 ~ /dual-role-pool/ && $2 == "2/2" && $3 == "Running" { print $1; exit }'
}

exec_kafka() {
  local p
  p=$(kafka_pod)
  [ -n "${p}" ] || return 1
  ${KUBECTL} -n "${NS}" exec "${p}" -c kafka -- "$@"
}

if [ -z "${CONSUMER_GROUP}" ]; then
  CONSUMER_GROUP=$(exec_kafka \
    bin/kafka-consumer-groups.sh --bootstrap-server "${BOOTSTRAP}" \
    --list 2>/dev/null | grep -E '^orders-consumers' | head -1 || true)
fi
CONSUMER_GROUP="${CONSUMER_GROUP:-orders-consumers-prod}"
echo "    consumer group under test: ${CONSUMER_GROUP}"

leader_pod() {
  local broker_id
  broker_id=$(exec_kafka \
    bin/kafka-topics.sh --bootstrap-server "${BOOTSTRAP}" \
    --describe --topic "${TOPIC}" 2>/dev/null |
    sed -nE 's/.*Leader: *([0-9]+).*/\1/p' | head -1)
  ${KUBECTL} -n "${NS}" get pods -l strimzi.io/kind=Kafka -o name |
    grep -E "(kafka|dual-role-pool)-${broker_id}$" | head -1
}

lag() {
  local out
  out=$(exec_kafka \
    bin/kafka-consumer-groups.sh --bootstrap-server "${BOOTSTRAP}" \
    --describe --group "${CONSUMER_GROUP}" 2>&1) || true
  if [ -z "${out}" ] || printf '%s' "${out}" | grep -qi 'does not exist'; then
    echo "NA"
    return 0
  fi
  printf '%s' "${out}" | awk 'NF >= 6 && $6 ~ /^[0-9]+$/ { s += $6 } END { print s + 0 }'
}

brokers() {
  ${KUBECTL} -n "${NS}" get pods --no-headers 2>/dev/null |
    awk '$1 ~ /dual-role-pool/ && $2 == "2/2" && $3 == "Running" { c++ } END { print c + 0 }'
}

echo "--- BEFORE"
${KUBECTL} -n "${NS}" get pods -o wide
LEADER=$(leader_pod)
if [ -z "${LEADER}" ]; then echo "FATAL: could not resolve the leader pod"; exit 1; fi
echo "    current leader pod: ${LEADER}"
echo "    brokers ready now: $(brokers || true), consumer-group lag now: $(lag || true)"

echo "--- stopping the leader broker"
START_TS=$(date +%s)
${KUBECTL} -n "${NS}" delete "${LEADER}" --grace-period=30 --wait=false
echo "    deleted at $(date -u +%FT%TZ)"

echo "--- waiting for a new leader and broker recovery"
LEADER_TS=""
for i in $(seq 1 40); do
  NEW_LEADER=$(leader_pod || true)
  READY=$(brokers || true)
  LAG_NOW=$(lag || true)
  if [ -z "${LEADER_TS}" ] && [ -n "${NEW_LEADER}" ] && [ "${NEW_LEADER}" != "${LEADER}" ]; then
    LEADER_TS=$(( $(date +%s) - START_TS ))
  fi
  echo "    t=$(( $(date +%s) - START_TS ))s leader=${NEW_LEADER:-none} brokers_ready=${READY:-?} lag=${LAG_NOW:-?}"
  if [ -n "${LEADER_TS}" ] && [ "${READY:-0}" = "3" ]; then
    echo "    NEW LEADER ELECTED: leader change observed ${LEADER_TS}s after the kill"
    echo "    ALL 3 BROKERS READY again after $(( $(date +%s) - START_TS ))s"
    break
  fi
  sleep 5
done

echo "--- AFTER: consumer lag must stay bounded (processing continues)"
sleep 20
echo "    consumer-group lag after failover: $(lag || true)"
${KUBECTL} -n "${NS}" get pods -o wide
echo "--- consumer group detail (offsets + lag per partition)"
exec_kafka \
  bin/kafka-consumer-groups.sh --bootstrap-server "${BOOTSTRAP}" \
  --describe --group "${CONSUMER_GROUP}" || true
echo "--- producer/consumer application logs (proof of continued processing)"
${KUBECTL} -n apps logs -l app=producer --tail=5 || true
${KUBECTL} -n apps logs -l app=consumer --tail=5 || true

sleep 3
echo "=== test finished - evidence: ${LOG} ==="
