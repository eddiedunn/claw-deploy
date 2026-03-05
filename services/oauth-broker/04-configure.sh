#!/usr/bin/env bash
set -euo pipefail

# Provision OAuth Broker secrets and runtime config
# Run as root on the target host
#
# Creates:
#   - OB_ENCRYPTION_KEY podman secret (Fernet key for refresh tokens at rest)
#   - ${CLAW_HOME}/.env  (non-secret runtime vars, loaded by the quadlet)
#   - ${CLAW_HOME}/data/ and ${CLAW_HOME}/redis-data/ (persistent volumes)

source "$(dirname "$0")/.env" 2>/dev/null || true

CLAW_USER="${CLAW_USER:-oauthbroker}"
CLAW_HOME="${CLAW_HOME:-/data/oauth-broker}"
OB_LOG_LEVEL="${OB_LOG_LEVEL:-info}"
OB_CALLBACK_BASE_URL="${OB_CALLBACK_BASE_URL:-http://localhost:8420}"
OB_REFRESH_MARGIN_SECONDS="${OB_REFRESH_MARGIN_SECONDS:-300}"
OB_SCHEDULER_INTERVAL_SECONDS="${OB_SCHEDULER_INTERVAL_SECONDS:-60}"

_UID=$(id -u "${CLAW_USER}")
PODMAN_ENV="XDG_RUNTIME_DIR=/run/user/${_UID}"

# Create persistent data directories
sudo -u "${CLAW_USER}" mkdir -p "${CLAW_HOME}/data"       # SQLite DB
sudo -u "${CLAW_USER}" mkdir -p "${CLAW_HOME}/redis-data" # Redis persistence
echo "Data directories created"

# Provision OB_ENCRYPTION_KEY as a podman secret (never written to disk)
# Requires python3 with the cryptography package available on the host,
# or generate on another machine and pass via: printf '%s' '<key>' | ...
if sudo -u "${CLAW_USER}" env "${PODMAN_ENV}" podman secret inspect OB_ENCRYPTION_KEY &>/dev/null; then
    echo "OB_ENCRYPTION_KEY secret already exists — skipping"
    echo "  To rotate: printf '%s' \"\$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')\" \\"
    echo "    | sudo -u ${CLAW_USER} env ${PODMAN_ENV} podman secret create --replace OB_ENCRYPTION_KEY -"
else
    FERNET_KEY="$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')"
    printf "%s" "${FERNET_KEY}" \
        | sudo -u "${CLAW_USER}" env "${PODMAN_ENV}" podman secret create OB_ENCRYPTION_KEY -
    echo "OB_ENCRYPTION_KEY secret created"
fi

# Write non-secret runtime config
# OB_ENCRYPTION_KEY is injected via Secret= in the quadlet — never add it here
sudo -u "${CLAW_USER}" tee "${CLAW_HOME}/.env" > /dev/null << ENVEOF
# OAuth Broker — non-secret runtime configuration
# Secrets (OB_ENCRYPTION_KEY) are injected via podman secret — do not add them here
OB_LOG_LEVEL=${OB_LOG_LEVEL}
OB_CALLBACK_BASE_URL=${OB_CALLBACK_BASE_URL}
OB_REFRESH_MARGIN_SECONDS=${OB_REFRESH_MARGIN_SECONDS}
OB_SCHEDULER_INTERVAL_SECONDS=${OB_SCHEDULER_INTERVAL_SECONDS}
ENVEOF

echo "Runtime config written to ${CLAW_HOME}/.env"
echo ""
echo "NEXT: Run 05-deploy-quadlet.sh to install the systemd service"
