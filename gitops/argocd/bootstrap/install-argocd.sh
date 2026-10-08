#!/usr/bin/env bash
set -euo pipefail

GIT_REPO="${GIT_REPO:-https://github.com/CHANGE_ME/utravs-devops-task.git}"
GIT_REVISION="${GIT_REVISION:-main}"
ARGO_NAMESPACE="argocd"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECTL="kubectl --kubeconfig=${KUBECONFIG:-/etc/kubernetes/admin.conf}"

echo "==> [1/4] Installing ArgoCD (pinned Helm chart)"
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update
helm upgrade --install argocd argo/argo-cd \
  --namespace "${ARGO_NAMESPACE}" --create-namespace \
  --version 7.7.12 \
  --set server.service.type=ClusterIP \
  --set configs.params."server\.insecure"=true \
  --wait --timeout 10m

echo "==> [2/4] Waiting for ArgoCD components"
${KUBECTL} -n ${ARGO_NAMESPACE} wait --for=condition=Available deploy --all --timeout=600s

echo "==> [2b/4] Excluding operator-created PVCs from ArgoCD tracking"
${KUBECTL} -n ${ARGO_NAMESPACE} patch configmap argocd-cm --type merge -p "$(cat <<'PATCH'
data:
  resource.exclusions: |
    - apiGroups: [""]
      kinds: ["PersistentVolumeClaim"]
PATCH
)"

echo "==> [3/4] Registering the Git repository and creating the root Application"
${KUBECTL} -n ${ARGO_NAMESPACE} create configmap git-repo-cm \
  --from-literal=repoUrl="${GIT_REPO}" \
  --dry-run=client -o yaml | ${KUBECTL} apply -f -

sed -e "s#REPLACE_GIT_REPO#${GIT_REPO}#g" \
    -e "s#REPLACE_GIT_REVISION#${GIT_REVISION}#g" \
    "${SCRIPT_DIR}/root-application.yaml" | ${KUBECTL} apply -f -

echo "==> [4/4] ArgoCD bootstrap complete"
echo "    Initial admin password:"
${KUBECTL} -n ${ARGO_NAMESPACE} get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
echo "    Port-forward UI: kubectl -n argocd port-forward svc/argocd-server 8080:80"
