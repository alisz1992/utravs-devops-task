#!/usr/bin/env bash
set -euo pipefail

OWNER="${GITHUB_OWNER:?set GITHUB_OWNER=<github-user-or-org>}"
TAG="${1:-1.0.0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for app in producer consumer; do
  IMAGE="ghcr.io/${OWNER}/${app}:${TAG}"
  echo "==> Building ${IMAGE}"
  docker build -t "${IMAGE}" "${ROOT_DIR}/apps/${app}"
  echo "==> Pushing ${IMAGE}"
  docker push "${IMAGE}"
done

echo "==> Done. Update image.repository in charts/*/values.yaml and"
echo "    gitops/environments/<env>/*-values.yaml with: ghcr.io/${OWNER}"
