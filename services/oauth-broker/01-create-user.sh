#!/usr/bin/env bash
set -euo pipefail

# Create system user for the OAuth Broker service
# Run as root on the target host

source "$(dirname "$0")/.env" 2>/dev/null || true

CLAW_USER="${CLAW_USER:-oauthbroker}"
CLAW_HOME="${CLAW_HOME:-/data/oauth-broker}"
CLAW_SUBUID_START="${CLAW_SUBUID_START:-362144}"
CLAW_SUBUID_COUNT="${CLAW_SUBUID_COUNT:-65536}"

if id "${CLAW_USER}" &>/dev/null; then
    echo "User '${CLAW_USER}' already exists, skipping creation"
else
    useradd --system --create-home --home-dir "${CLAW_HOME}" --shell /usr/sbin/nologin "${CLAW_USER}"
    echo "Created user '${CLAW_USER}' with home ${CLAW_HOME}"
fi

if ! grep -q "^${CLAW_USER}:" /etc/subuid 2>/dev/null; then
    echo "${CLAW_USER}:${CLAW_SUBUID_START}:${CLAW_SUBUID_COUNT}" >> /etc/subuid
    echo "${CLAW_USER}:${CLAW_SUBUID_START}:${CLAW_SUBUID_COUNT}" >> /etc/subgid
    echo "Added subuid/subgid mappings (${CLAW_SUBUID_START}:${CLAW_SUBUID_COUNT})"
else
    echo "subuid/subgid already configured"
fi

loginctl enable-linger "${CLAW_USER}"
echo "Enabled lingering for ${CLAW_USER}"

_UID=$(id -u "${CLAW_USER}")
mkdir -p "/run/user/${_UID}"
chown "${CLAW_USER}:${CLAW_USER}" "/run/user/${_UID}"
echo "XDG_RUNTIME_DIR set up at /run/user/${_UID}"

echo "Done — ${CLAW_USER} user ready"
