#!/usr/bin/env bash
set -euo pipefail

SIDE="${1:?usage: rotate-secret.sh <producer|consumer> [dev]}"
ENV_SUFFIX=""; [ "${2:-}" = "dev" ] && ENV_SUFFIX="-dev"
KV_PATH="kv/${SIDE}${ENV_SUFFIX}"
NAMESPACE="apps"; [ "${2:-}" = "dev" ] && NAMESPACE="apps-dev"

KUBECTL="${KUBECTL:-kubectl --kubeconfig=${KUBECONFIG:-/etc/kubernetes/admin.conf}}"
VAULT_NS=vault
INIT_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/vault-init.json"
NEW_TOKEN="rotated-$(openssl rand -hex 12)"
TIMEOUT_SECONDS=600

ROOT_TOKEN=$(grep -o '"root_token":"[^"]*"' "${INIT_FILE}" | cut -d'"' -f4)
v() { ${KUBECTL} -n "${VAULT_NS}" exec vault-0 -c vault -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${ROOT_TOKEN}" vault "$@"; }

echo "==> [1/3] Old value (as seen inside a running pod)"
POD=$(${KUBECTL} -n "${NAMESPACE}" get pod -l app="${SIDE}" -o jsonpath='{.items[0].metadata.name}')
echo "    pod: ${POD}"
${KUBECTL} -n "${NAMESPACE}" exec "${POD}" -c "${SIDE}" -- cat "/vault/secrets/kafka-creds" || true

echo "==> [2/3] Rotating ${KV_PATH}"
v kv put "${KV_PATH}" token="${NEW_TOKEN}" rotated_at="$(date -u +%FT%TZ)" >/dev/null
echo "    new token written: ${NEW_TOKEN}"

echo "==> [3/3] Waiting up to ${TIMEOUT_SECONDS}s for the agent to re-render the file"
START=$(date +%s)
while true; do
  CONTENT=$(${KUBECTL} -n "${NAMESPACE}" exec "${POD}" -c "${SIDE}" -- cat "/vault/secrets/kafka-creds" 2>/dev/null || true)
  if echo "${CONTENT}" | grep -q "${NEW_TOKEN}"; then
    echo "    SUCCESS - new value visible in the running pod:"
    echo "    ${CONTENT}"
    break
  fi
  if [ $(( $(date +%s) - START )) -ge "${TIMEOUT_SECONDS}" ]; then
    echo "    TIMEOUT - the agent did not re-render within ${TIMEOUT_SECONDS}s." >&2
    echo "    Fallback (still zero downtime): the RollingUpdate strategy with" >&2
    echo "    maxUnavailable=0 restarts pods one by one - see docs/runbooks/secret-rotation.md" >&2
    exit 1
  fi
  sleep 5
done

echo "==> Application log evidence (new token detected):"
${KUBECTL} -n "${NAMESPACE}" logs "${POD}" -c "${SIDE}" --tail=20 | grep -i "secret" || true
echo "==> Rotation completed for ${KV_PATH}"
