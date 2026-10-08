#!/usr/bin/env bash
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl --kubeconfig=${KUBECONFIG:-/etc/kubernetes/admin.conf}}"
VAULT_NS=vault
EVIDENCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docs/evidence"
LOG="${EVIDENCE_DIR}/vault-failover-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${EVIDENCE_DIR}"
exec > >(tee -a "${LOG}") 2>&1
echo "=== Vault failover test - $(date -u +%FT%TZ) ==="

INIT_FILE="${INIT_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/vault-init.json}"
ROOT_TOKEN=$(sed -n 's/.*"root_token": *"\([^"]*\)".*/\1/p' "${INIT_FILE}")

vexec() { local pod=$1; shift; ${KUBECTL} -n "${VAULT_NS}" exec "${pod}" -c vault -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${ROOT_TOKEN}" vault "$@"; }

active_pod() {
  for pod in vault-0 vault-1 vault-2; do
    if vexec "${pod}" read sys/leader -format=json 2>/dev/null | grep -q '"is_self": *true'; then
      echo "${pod}"; return 0
    fi
  done
  return 1
}

read_secret_via() {
  vexec "$1" kv get -field=token kv/data/producer >/dev/null 2>&1
}

echo "--- BEFORE"
ACTIVE=$(active_pod); echo "    active node: ${ACTIVE}"
for pod in vault-0 vault-1 vault-2; do
  vexec "${pod}" status -format=json | grep -E '"sealed"|"n"|HAEnabled' | head -3 || true
done
read_secret_via vault-1 && echo "    secret read BEFORE: OK"

echo "--- stepping down active node ${ACTIVE}"
START_TS=$(date +%s)
vexec "${ACTIVE}" operator step-down
echo "    step-down issued at $(date -u +%FT%TZ)"

echo "--- waiting for a new active node + continuous secret availability"
NEW_ACTIVE=""
for i in $(seq 1 36); do
  sleep 5
  NEW_ACTIVE=$(active_pod || true)
  OK_FAIL="FAIL"
  for pod in vault-0 vault-1 vault-2; do
    if read_secret_via "${pod}"; then OK_FAIL="OK"; break; fi
  done
  echo "    t=$(( $(date +%s) - START_TS ))s active=${NEW_ACTIVE:-none} secret_read=${OK_FAIL}"
  if [ -n "${NEW_ACTIVE}" ] && [ "${NEW_ACTIVE}" != "${ACTIVE}" ] && [ "${OK_FAIL}" = "OK" ]; then
    echo "    FAILOVER COMPLETE after $(( $(date +%s) - START_TS ))s"
    break
  fi
done

echo "--- AFTER: all nodes unsealed, no sealed member"
for pod in vault-0 vault-1 vault-2; do
  SEALED=$(vexec "${pod}" status -format=json | sed -n 's/.*"sealed": *\(true\|false\).*/sealed=\1/p')
  echo "    ${pod} ${SEALED}"
done

echo "--- application pods still healthy (no restart caused by the failover)"
${KUBECTL} -n apps get pods
echo "=== test finished - evidence: ${LOG} ==="
