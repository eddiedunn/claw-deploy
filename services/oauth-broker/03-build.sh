#!/usr/bin/env bash
set -euo pipefail

# Clone the oauth-service repo and build the container image
# Run as root on the target host

source "$(dirname "$0")/.env" 2>/dev/null || true

CLAW_USER="${CLAW_USER:-oauthbroker}"
CLAW_HOME="${CLAW_HOME:-/data/oauth-broker}"
CLAW_REPO_URL="${CLAW_REPO_URL:-https://github.com/eddiedunn/oauth-broker.git}"
CLAW_REPO_BRANCH="${CLAW_REPO_BRANCH:-main}"
CLAW_IMAGE="${CLAW_IMAGE:-oauth-broker:local}"

SRC_DIR="${CLAW_HOME}/oauth-service-src"
_UID=$(id -u "${CLAW_USER}")
PODMAN_ENV="XDG_RUNTIME_DIR=/run/user/${_UID}"

if [ -d "${SRC_DIR}/.git" ]; then
    echo "Repo already cloned, pulling latest..."
    sudo -u "${CLAW_USER}" git -C "${SRC_DIR}" checkout "${CLAW_REPO_BRANCH}"
    sudo -u "${CLAW_USER}" git -C "${SRC_DIR}" pull origin "${CLAW_REPO_BRANCH}"
else
    echo "Cloning oauth-service from ${CLAW_REPO_URL}..."
    sudo -u "${CLAW_USER}" git clone -b "${CLAW_REPO_BRANCH}" "${CLAW_REPO_URL}" "${SRC_DIR}"
fi

echo "Building container image ${CLAW_IMAGE} (this may take a while)..."
sudo -u "${CLAW_USER}" bash -c \
    "cd ${SRC_DIR} && ${PODMAN_ENV} podman build -f podman/Containerfile.broker -t ${CLAW_IMAGE} ."

echo "Verifying image..."
sudo -u "${CLAW_USER}" bash -c "${PODMAN_ENV} podman images ${CLAW_IMAGE}"

echo "Done — ${CLAW_IMAGE} built successfully"
