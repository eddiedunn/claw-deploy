#!/usr/bin/env bash
set -euo pipefail

# Configure rootless podman for the OAuth Broker service user
# Run as root on the target host

source "$(dirname "$0")/.env" 2>/dev/null || true

CLAW_USER="${CLAW_USER:-oauthbroker}"
CLAW_HOME="${CLAW_HOME:-/data/oauth-broker}"

sudo -u "${CLAW_USER}" mkdir -p "${CLAW_HOME}/.config/containers"
sudo -u "${CLAW_USER}" mkdir -p "${CLAW_HOME}/.local/share/containers"

echo "Testing rootless podman..."
sudo -u "${CLAW_USER}" bash -c "XDG_RUNTIME_DIR=/run/user/\$(id -u) podman info --format '{{.Host.Security.Rootless}}'" | grep -q true
echo "Rootless podman verified"

echo "Done — podman configured for ${CLAW_USER}"
