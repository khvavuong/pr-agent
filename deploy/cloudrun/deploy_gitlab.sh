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
IMAGE_NAME="${IMAGE_NAME:-pr-agent-gitlab}"
IMAGE_TAG="${IMAGE_TAG:-${VERSION}}"
IMAGE_REF="${IMAGE_REF:-${IMAGE_NAME}:${IMAGE_TAG}}"
BUNDLE_NAME="${BUNDLE_NAME:-${IMAGE_NAME}-${IMAGE_TAG}.tar.gz}"
BUNDLE_PATH="${PACKAGE_DIR}/${BUNDLE_NAME}"
CONTAINER_NAME="${CONTAINER_NAME:-pr-agent-gitlab}"
HOST_PORT="${HOST_PORT:-3000}"
GCP_PROJECT_ID="${GCP_PROJECT_ID:-${PROJECT_ID:-}}"
OPENAI_KEY_SECRET="${OPENAI_KEY_SECRET:-pr-agent-openai-key}"
GITLAB_URL_SECRET="${GITLAB_URL_SECRET:-pr-agent-gitlab-url}"
GITLAB_PAT_SECRET="${GITLAB_PAT_SECRET:-pr-agent-gitlab-pat}"
GITLAB_SHARED_SECRET_SECRET="${GITLAB_SHARED_SECRET_SECRET:-pr-agent-gitlab-shared-secret}"

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
  local tmp_dir image_tar metadata_env
  tmp_dir="$(mktemp -d)"
  image_tar="${tmp_dir}/image.tar"
  metadata_env="${tmp_dir}/metadata.env"
  trap 'rm -rf "${tmp_dir}"' EXIT

  echo "[1/4] Building Docker image: ${IMAGE_REF}"
  docker build -f docker/Dockerfile.gitlab -t "${IMAGE_REF}" .

  echo "[2/4] Exporting image"
  docker save -o "${image_tar}" "${IMAGE_REF}"

  echo "[3/4] Creating image metadata"
  cat > "${metadata_env}" <<METADATA_ENV
IMAGE_REF=${IMAGE_REF}
CONTAINER_NAME=${CONTAINER_NAME}
HOST_PORT=${HOST_PORT}
METADATA_ENV

  echo "[4/4] Writing bundle: ${BUNDLE_PATH}"
  tar -czf "${BUNDLE_PATH}" -C "${tmp_dir}" image.tar metadata.env

  echo "Done"
  echo "Bundle ready: ${BUNDLE_PATH}"
  echo "Copy this bundle + deploy_gitlab.sh to VM, then run: bash deploy_gitlab.sh run"
}

do_run() {
  command -v sudo >/dev/null 2>&1 || { echo "Missing command: sudo"; exit 1; }
  command -v tar >/dev/null 2>&1 || { echo "Missing command: tar"; exit 1; }
  command -v gcloud >/dev/null 2>&1 || { echo "Missing command: gcloud"; exit 1; }

  require_env GCP_PROJECT_ID

  local bundle_path tmp_dir image_tar metadata_env
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

  image_tar="${tmp_dir}/image.tar"
  metadata_env="${tmp_dir}/metadata.env"
  [[ -f "${image_tar}" ]] || { echo "Invalid bundle: missing image.tar"; exit 1; }
  [[ -f "${metadata_env}" ]] || { echo "Invalid bundle: missing metadata.env"; exit 1; }

  set -a
  # shellcheck disable=SC1090
  source "${metadata_env}"
  set +a

  require_env IMAGE_REF

  echo "[1/6] Reading secrets from GCP Secret Manager"
  local openai_key gitlab_url gitlab_pat gitlab_shared_secret
  openai_key="$(gcloud secrets versions access latest --project "${GCP_PROJECT_ID}" --secret "${OPENAI_KEY_SECRET}")"
  gitlab_url="$(gcloud secrets versions access latest --project "${GCP_PROJECT_ID}" --secret "${GITLAB_URL_SECRET}")"
  gitlab_pat="$(gcloud secrets versions access latest --project "${GCP_PROJECT_ID}" --secret "${GITLAB_PAT_SECRET}")"
  gitlab_shared_secret="$(gcloud secrets versions access latest --project "${GCP_PROJECT_ID}" --secret "${GITLAB_SHARED_SECRET_SECRET}")"

  echo "[2/6] Ensuring Docker exists"
  if ! command -v docker >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y docker.io
    sudo systemctl enable docker
    sudo systemctl start docker
  fi

  echo "[3/6] Loading Docker image"
  sudo docker load -i "${image_tar}"

  echo "[4/6] Recreating container"
  if sudo docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
    sudo docker rm -f "${CONTAINER_NAME}"
  fi

  sudo docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    -p "${HOST_PORT}:3000" \
    -e CONFIG__GIT_PROVIDER=gitlab \
    -e GITLAB__URL="${gitlab_url}" \
    -e GITLAB__PERSONAL_ACCESS_TOKEN="${gitlab_pat}" \
    -e GITLAB__SHARED_SECRET="${gitlab_shared_secret}" \
    -e OPENAI__KEY="${openai_key}" \
    -e CONFIG__MODEL="gpt-5.3-codex" \
    -e CONFIG__FALLBACK_MODELS='["gpt-5.2-codex"]' \
    "${IMAGE_REF}"

  echo "[5/6] Container status"
  sudo docker ps --filter "name=${CONTAINER_NAME}"

  echo "[6/6] Done"
  echo "Webhook endpoint: https://<YOUR_DOMAIN_OR_VM_IP>/webhook"
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
