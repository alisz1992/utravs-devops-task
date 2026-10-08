#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${1:?usage: set-repo-url.sh <git-repo-url> [revision]}"
REVISION="${2:-main}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> repoURL : ${REPO_URL}"
echo "==> revision: ${REVISION}"

grep -rl 'REPLACE_GIT_REPO\|REPLACE_GIT_REVISION' "${ROOT_DIR}/gitops" \
  | grep -v 'bootstrap/install-argocd.sh$' | while read -r file; do
  sed -i "s#REPLACE_GIT_REPO#${REPO_URL}#g; s#REPLACE_GIT_REVISION#${REVISION}#g" "${file}"
  echo "    updated: ${file#"${ROOT_DIR}"/}"
done

echo "==> Done. Review, commit and push:"
echo "    cd ${ROOT_DIR} && git add -A && git commit -m 'chore: set repository url' && git push"
