#!/usr/bin/env bash
set -euo pipefail

# Two-step deploy script (Docker image artifact flow)
#
# Step 1 (local): build image + export image artifact (.tar.gz)
#   ./deploy/cloudrun/deploy_gitlab.sh package
#
# Step 2 (on VM): load image from artifact + run service
#   OPENAI_KEY=... GITLAB_URL=... GITLAB_PAT=... GITLAB_SHARED_SECRET=... ./deploy_gitlab.sh run

MODE="${1:-}"
if [[ -z "${MODE}" ]]; then
  echo "Usage: $0 <package|run>"
  exit 1
fi

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

PACKAGE_DIR="${PACKAGE_DIR:-deploy/packages}"
VERSION="${VERSION:-$(date +%Y%m%d-%H%M%S)}"
IMAGE_NAME="${IMAGE_NAME:-pr-agent-gitlab}"
IMAGE_TAG="${IMAGE_TAG:-${VERSION}}"
IMAGE_REF="${IMAGE_REF:-${IMAGE_NAME}:${IMAGE_TAG}}"
IMAGE_ARTIFACT_NAME="${IMAGE_ARTIFACT_NAME:-${IMAGE_NAME}-${IMAGE_TAG}.tar.gz}"
IMAGE_ARTIFACT_PATH="${PACKAGE_DIR}/${IMAGE_ARTIFACT_NAME}"
CONTAINER_NAME="${CONTAINER_NAME:-pr-agent-gitlab}"
HOST_PORT="${HOST_PORT:-3000}"

require_env() {
  local key="$1"
  if [[ -z "${!key:-}" ]]; then
    echo "Missing required env var: ${key}"
    exit 1
  fi
}

do_package() {
  command -v docker >/dev/null 2>&1 || { echo "Missing command: docker"; exit 1; }
  mkdir -p "${PACKAGE_DIR}"

  echo "[1/3] Building Docker image: ${IMAGE_REF}"
  docker build -f docker/Dockerfile.gitlab -t "${IMAGE_REF}" .

  echo "[2/3] Saving image artifact: ${IMAGE_ARTIFACT_PATH}"
  docker save "${IMAGE_REF}" | gzip > "${IMAGE_ARTIFACT_PATH}"

  echo "[3/3] Done"
  echo "Artifact ready: ${IMAGE_ARTIFACT_PATH}"
  echo "Copy this file + deploy_gitlab.sh to VM, then run deploy_gitlab.sh run with env vars."
}

do_run() {
  command -v sudo >/dev/null 2>&1 || { echo "Missing command: sudo"; exit 1; }

  require_env OPENAI_KEY
  require_env GITLAB_URL
  require_env GITLAB_PAT
  require_env GITLAB_SHARED_SECRET

  local artifact_path
  artifact_path="${IMAGE_ARTIFACT_PATH}"
  if [[ ! -f "${artifact_path}" ]] && [[ -f "${IMAGE_ARTIFACT_NAME}" ]]; then
    artifact_path="${IMAGE_ARTIFACT_NAME}"
  fi
  if [[ ! -f "${artifact_path}" ]]; then
    echo "Image artifact not found: ${IMAGE_ARTIFACT_PATH} (or ${IMAGE_ARTIFACT_NAME})"
    exit 1
  fi

  echo "[1/5] Ensuring Docker exists"
  if ! command -v docker >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y docker.io
    sudo systemctl enable docker
    sudo systemctl start docker
  fi

  echo "[2/5] Loading Docker image from artifact"
  sudo docker load -i "${artifact_path}"

  echo "[3/5] Recreating container"
  if sudo docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
    sudo docker rm -f "${CONTAINER_NAME}"
  fi

  sudo docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    -p "${HOST_PORT}:3000" \
    -e CONFIG__GIT_PROVIDER=gitlab \
    -e GITLAB__URL="${GITLAB_URL}" \
    -e GITLAB__PERSONAL_ACCESS_TOKEN="${GITLAB_PAT}" \
    -e GITLAB__SHARED_SECRET="${GITLAB_SHARED_SECRET}" \
    -e OPENAI__KEY="${OPENAI_KEY}" \
    -e CONFIG__MODEL="gpt-5.3-codex" \
    -e CONFIG__FALLBACK_MODELS='["gpt-5.2-codex"]' \
    "${IMAGE_REF}"

  echo "[4/5] Container status"
  sudo docker ps --filter "name=${CONTAINER_NAME}"

  echo "[5/5] Done"
  echo "Webhook endpoint: https://<YOUR_DOMAIN_OR_VM_IP>/webhook"
}

case "${MODE}" in
  package)
    do_package
    ;;
  run)
    do_run
    ;;
  *)
    echo "Unknown mode: ${MODE}"
    echo "Usage: $0 <package|run>"
    exit 1
    ;;
esac
