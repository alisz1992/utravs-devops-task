#!/usr/bin/env bash
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl --kubeconfig=${KUBECONFIG:-/etc/kubernetes/admin.conf}}"
VAULT_NS="${VAULT_NS:-vault}"
INIT_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/vault-init.json"
KEY_SHARES=5
KEY_THRESHOLD=3

v() {
  local pod=$1; shift
  ${KUBECTL} -n "${VAULT_NS}" exec -i "${pod}" -c vault -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${ROOT_TOKEN:-}" vault "$@"
}

echo "==> [1/6] Waiting for Vault pods to be Ready"
${KUBECTL} -n "${VAULT_NS}" wait --for=condition=Ready pod -l app.kubernetes.io/name=vault --timeout=300s

echo "==> [2/6] Initialization check"
if [ -f "${INIT_FILE}" ]; then
  echo "    ${INIT_FILE} exists - reusing it (no re-init)"
else
  if v vault-0 status 2>/dev/null | grep -q 'Sealed: false'; then
    echo "    Vault is already initialized but no ${INIT_FILE} exists."
    echo "    Provide unseal keys + root token manually and re-run." >&2
    exit 1
  fi
  v vault-0 operator init -key-shares="${KEY_SHARES}" -key-threshold="${KEY_THRESHOLD}" -format=json > "${INIT_FILE}"
  chmod 600 "${INIT_FILE}"
  echo "    initialized - keys stored in ${INIT_FILE} (keep it safe, never commit it)"
fi

ROOT_TOKEN=$(python3 -c "import json;print(json.load(open('${INIT_FILE}'))['root_token'])")
mapfile -t _UNSEAL_KEYS < <(python3 -c "import json;print(*json.load(open('${INIT_FILE}'))['unseal_keys_b64'][:3], sep='\n')")
U1="${_UNSEAL_KEYS[0]}"
U2="${_UNSEAL_KEYS[1]}"
U3="${_UNSEAL_KEYS[2]}"

echo "==> [3/6] Unsealing every node"
for pod in vault-0 vault-1 vault-2; do
  if ${KUBECTL} -n "${VAULT_NS}" exec "${pod}" -c vault -- env VAULT_ADDR=http://127.0.0.1:8200 vault status -format=json 2>/dev/null \
      | grep -q '"sealed":true'; then
    echo "    unsealing ${pod}"
    for key in "${U1}" "${U2}" "${U3}"; do
      ${KUBECTL} -n "${VAULT_NS}" exec "${pod}" -c vault -- env VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal "${key}" >/dev/null
    done
  else
    echo "    ${pod} already unsealed"
  fi
done

echo "==> [4/6] kv v2 engine + Kubernetes auth"
v vault-0 secrets enable -path=kv -version=2 kv 2>/dev/null || echo "    kv engine already enabled"
v vault-0 auth enable kubernetes 2>/dev/null || echo "    kubernetes auth already enabled"
v vault-0 write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc" >/dev/null

echo "==> [5/6] Policies and roles"
for side in producer consumer; do
  v vault-0 policy write "${side}-policy" - <<EOF
path "kv/data/${side}"            { capabilities = ["read"] }
path "kv/data/${side}-dev"        { capabilities = ["read"] }
path "kv/metadata/${side}"        { capabilities = ["list"] }
EOF
  for suffix in "" "-prod" "-dev"; do
    ns="apps"; [ "${suffix}" = "-dev" ] && ns="apps-dev"
    v vault-0 write "auth/kubernetes/role/${side}${suffix}" \
      policies="${side}-policy" \
      bound_service_account_names="default,${side}" \
      bound_service_account_namespaces="${ns}" \
      ttl=1h >/dev/null
    echo "    role ${side}${suffix} -> sa default/${side} in ns ${ns}"
  done
done

echo "==> [6/6] Initial secrets (rotated later by scripts/rotate-secret.sh)"
for side in producer consumer; do
  for suffix in "" "-dev"; do
    TOKEN=$(openssl rand -hex 16)
    v vault-0 kv put "kv/${side}${suffix}" token="${TOKEN}" rotated_at="$(date -u +%FT%TZ)" >/dev/null
    echo "    wrote kv/${side}${suffix} (API path kv/data/${side}${suffix})"
  done
done

echo "==> Vault bootstrap complete."
echo "    Root token: ${ROOT_TOKEN} (stored in ${INIT_FILE})"
