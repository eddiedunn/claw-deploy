#!/usr/bin/env bash
set -euo pipefail

# Clone repo and build container image for the configured variant
# Run as root on the target host

# Source environment configuration
source "$(dirname "$0")/../.env" 2>/dev/null || true

# Source variant library
source "$(dirname "$0")/../lib/variant.sh"

CLAW_VARIANT="${CLAW_VARIANT:-openclaw}"
CLAW_USER="${CLAW_USER:-openclaw}"
CLAW_HOME="${CLAW_HOME:-/data/openclaw}"

REPO_URL="$(variant_repo_url "$CLAW_VARIANT")"
IMAGE_NAME="$(variant_default_image "$CLAW_VARIANT")"
SRC_DIR="$(variant_src_dir "$CLAW_VARIANT" "$CLAW_HOME")"

REPO_BRANCH="${CLAW_REPO_BRANCH:-}"

_UID=$(id -u "${CLAW_USER}")
export XDG_RUNTIME_DIR="/run/user/${_UID}"

if [ -d "${SRC_DIR}/.git" ]; then
    echo "Repo already cloned, pulling latest..."
    sudo -u "${CLAW_USER}" git -C "${SRC_DIR}" pull
    if [[ -n "${REPO_BRANCH}" ]]; then
        sudo -u "${CLAW_USER}" git -C "${SRC_DIR}" checkout "${REPO_BRANCH}"
        sudo -u "${CLAW_USER}" git -C "${SRC_DIR}" pull origin "${REPO_BRANCH}"
    fi
else
    echo "Cloning ${CLAW_VARIANT}..."
    if [[ -n "${REPO_BRANCH}" ]]; then
        sudo -u "${CLAW_USER}" git clone -b "${REPO_BRANCH}" "${REPO_URL}" "${SRC_DIR}"
    else
        sudo -u "${CLAW_USER}" git clone "${REPO_URL}" "${SRC_DIR}"
    fi
fi

echo "Building container image (this may take a while)..."
sudo -u "${CLAW_USER}" bash -c "cd ${SRC_DIR} && XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} podman build -t ${IMAGE_NAME} ."

echo "Verifying image..."
sudo -u "${CLAW_USER}" bash -c "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} podman images ${IMAGE_NAME}"

echo "Done - ${CLAW_VARIANT} image built"
