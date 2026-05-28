#!/usr/bin/env bash
set -euo pipefail

# Two-step deploy script (image bundle + GCP Secret Manager flow)
# 1) package: build Docker image and create one versioned tar.gz bundle (image only)
# 2) run: on VM, load image and read runtime secrets from GCP Secret Manager

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
IMAGE_NAME="${IMAGE_NAME:-pr-agent-github}"
IMAGE_TAG="${IMAGE_TAG:-${VERSION}}"
IMAGE_REF="${IMAGE_REF:-${IMAGE_NAME}:${IMAGE_TAG}}"
NGINX_IMAGE_NAME="${NGINX_IMAGE_NAME:-pr-agent-github-nginx}"
NGINX_IMAGE_REF="${NGINX_IMAGE_REF:-${NGINX_IMAGE_NAME}:${IMAGE_TAG}}"
BUNDLE_NAME="${BUNDLE_NAME:-${IMAGE_NAME}-${IMAGE_TAG}.tar.gz}"
BUNDLE_PATH="${PACKAGE_DIR}/${BUNDLE_NAME}"
CONTAINER_NAME="${CONTAINER_NAME:-pr-agent-github}"
NGINX_CONTAINER_NAME="${NGINX_CONTAINER_NAME:-pr-agent-github-nginx}"
DOCKER_NETWORK="${DOCKER_NETWORK:-pr-agent-net}"
HTTP_PORT="${HTTP_PORT:-80}"
GCP_PROJECT_ID="${GCP_PROJECT_ID:-${PROJECT_ID:-}}"
OPENAI_KEY_SECRET="${OPENAI_KEY_SECRET:-pr-agent-openai-key}"
GITHUB_APP_ID_SECRET="${GITHUB_APP_ID_SECRET:-pr-agent-github-app-id}"
GITHUB_PRIVATE_KEY_SECRET="${GITHUB_PRIVATE_KEY_SECRET:-pr-agent-github-private-key}"
GITHUB_WEBHOOK_SECRET_SECRET="${GITHUB_WEBHOOK_SECRET_SECRET:-pr-agent-github-webhook-secret}"

require_env() {
  local key="$1"
  if [[ -z "${!key:-}" ]]; then
    echo "Missing required env var: ${key}"
    exit 1
  fi
}

do_package() {
  command -v docker >/dev/null 2>&1 || { echo "Missing command: docker"; exit 1; }
  command -v tar >/dev/null 2>&1 || { echo "Missing command: tar"; exit 1; }
  command -v mktemp >/dev/null 2>&1 || { echo "Missing command: mktemp"; exit 1; }

  mkdir -p "${PACKAGE_DIR}"
  local tmp_dir app_image_tar nginx_image_tar metadata_env
  tmp_dir="$(mktemp -d)"
  app_image_tar="${tmp_dir}/app-image.tar"
  nginx_image_tar="${tmp_dir}/nginx-image.tar"
  metadata_env="${tmp_dir}/metadata.env"
  trap 'rm -rf "${tmp_dir}"' EXIT

  echo "[1/5] Building app image: ${IMAGE_REF}"
  docker build -f docker/github/Dockerfile.github -t "${IMAGE_REF}" .

  echo "[2/5] Building nginx image: ${NGINX_IMAGE_REF}"
  docker build -f docker/github/Dockerfile.nginx -t "${NGINX_IMAGE_REF}" .

  echo "[3/5] Exporting images"
  docker save -o "${app_image_tar}" "${IMAGE_REF}"
  docker save -o "${nginx_image_tar}" "${NGINX_IMAGE_REF}"

  echo "[4/5] Creating image metadata"
  cat > "${metadata_env}" <<METADATA_ENV
IMAGE_REF=${IMAGE_REF}
NGINX_IMAGE_REF=${NGINX_IMAGE_REF}
CONTAINER_NAME=${CONTAINER_NAME}
NGINX_CONTAINER_NAME=${NGINX_CONTAINER_NAME}
DOCKER_NETWORK=${DOCKER_NETWORK}
HTTP_PORT=${HTTP_PORT}
METADATA_ENV

  echo "[5/5] Writing bundle: ${BUNDLE_PATH}"
  tar -czf "${BUNDLE_PATH}" -C "${tmp_dir}" app-image.tar nginx-image.tar metadata.env

  echo "Done"
  echo "Bundle ready: ${BUNDLE_PATH}"
  echo "Copy this bundle + deploy_github.sh to VM, then run: bash deploy_github.sh run"
}

do_run() {
  command -v sudo >/dev/null 2>&1 || { echo "Missing command: sudo"; exit 1; }
  command -v tar >/dev/null 2>&1 || { echo "Missing command: tar"; exit 1; }
  command -v gcloud >/dev/null 2>&1 || { echo "Missing command: gcloud"; exit 1; }

  require_env GCP_PROJECT_ID

  local bundle_path tmp_dir app_image_tar nginx_image_tar metadata_env
  bundle_path="${BUNDLE_PATH}"
  if [[ ! -f "${bundle_path}" ]] && [[ -f "${BUNDLE_NAME}" ]]; then
    bundle_path="${BUNDLE_NAME}"
  fi
  if [[ ! -f "${bundle_path}" ]]; then
    echo "Bundle not found: ${BUNDLE_PATH} (or ${BUNDLE_NAME})"
    exit 1
  fi

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT
  tar -xzf "${bundle_path}" -C "${tmp_dir}"

  app_image_tar="${tmp_dir}/app-image.tar"
  nginx_image_tar="${tmp_dir}/nginx-image.tar"
  metadata_env="${tmp_dir}/metadata.env"
  [[ -f "${app_image_tar}" ]] || { echo "Invalid bundle: missing app-image.tar"; exit 1; }
  [[ -f "${nginx_image_tar}" ]] || { echo "Invalid bundle: missing nginx-image.tar"; exit 1; }
  [[ -f "${metadata_env}" ]] || { echo "Invalid bundle: missing metadata.env"; exit 1; }

  set -a
  # shellcheck disable=SC1090
  source "${metadata_env}"
  set +a

  require_env IMAGE_REF
  require_env NGINX_IMAGE_REF

  echo "[1/6] Reading secrets from GCP Secret Manager"
  local openai_key github_app_id github_private_key github_webhook_secret
  openai_key="$(gcloud secrets versions access latest --project "${GCP_PROJECT_ID}" --secret "${OPENAI_KEY_SECRET}")"
  github_app_id="$(gcloud secrets versions access latest --project "${GCP_PROJECT_ID}" --secret "${GITHUB_APP_ID_SECRET}")"
  github_private_key="$(gcloud secrets versions access latest --project "${GCP_PROJECT_ID}" --secret "${GITHUB_PRIVATE_KEY_SECRET}")"
  github_webhook_secret="$(gcloud secrets versions access latest --project "${GCP_PROJECT_ID}" --secret "${GITHUB_WEBHOOK_SECRET_SECRET}")"

  echo "[2/6] Ensuring Docker exists"
  if ! command -v docker >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y docker.io
    sudo systemctl enable docker
    sudo systemctl start docker
  fi

  echo "[3/7] Loading Docker images"
  sudo docker load -i "${app_image_tar}"
  sudo docker load -i "${nginx_image_tar}"

  echo "[4/7] Ensuring Docker network"
  if ! sudo docker network ls --format '{{.Name}}' | grep -Fxq "${DOCKER_NETWORK}"; then
    sudo docker network create "${DOCKER_NETWORK}"
  fi

  echo "[5/7] Recreating containers"
  if sudo docker ps -a --format '{{.Names}}' | grep -Fxq "${NGINX_CONTAINER_NAME}"; then
    sudo docker rm -f "${NGINX_CONTAINER_NAME}"
  fi
  if sudo docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
    sudo docker rm -f "${CONTAINER_NAME}"
  fi

  sudo docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    --network "${DOCKER_NETWORK}" \
    -e CONFIG__GIT_PROVIDER=github \
    -e GITHUB__DEPLOYMENT_TYPE=app \
    -e GITHUB__APP_ID="${github_app_id}" \
    -e GITHUB__PRIVATE_KEY="${github_private_key}" \
    -e GITHUB__WEBHOOK_SECRET="${github_webhook_secret}" \
    -e OPENAI__KEY="${openai_key}" \
    -e CONFIG__MODEL="gpt-5.3-codex" \
    -e CONFIG__FALLBACK_MODELS='["gpt-5.2-codex"]' \
    "${IMAGE_REF}"

  sudo docker run -d \
    --name "${NGINX_CONTAINER_NAME}" \
    --restart unless-stopped \
    --network "${DOCKER_NETWORK}" \
    -p "${HTTP_PORT}:80" \
    "${NGINX_IMAGE_REF}"

  echo "[6/7] Container status"
  sudo docker ps --filter "name=pr-agent-github"

  echo "[7/7] Done"
  echo "Webhook endpoint: https://<YOUR_DOMAIN_OR_VM_IP>/api/v1/github_webhooks"
  echo "HTTP test endpoint: http://<YOUR_DOMAIN_OR_VM_IP>/api/v1/github_webhooks"
}

case "${MODE}" in
  package) do_package ;;
  run) do_run ;;
  *)
    echo "Unknown mode: ${MODE}"
    echo "Usage: $0 <package|run>"
    exit 1
    ;;
esac
