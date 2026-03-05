#!/usr/bin/env bash
set -euo pipefail

# Deploy OAuth Broker as a rootless systemd pod quadlet
# Run as root on the target host
#
# Creates three quadlet files:
#   oauth-broker.pod              — pod (owns the port binding)
#   oauth-broker-redis.container  — Redis sidecar (pod-internal, not host-exposed)
#   oauth-broker.container        — FastAPI token broker
#
# Both containers share the pod's network namespace, so the broker reaches
# Redis at localhost:6379 with no host port exposure for Redis.

source "$(dirname "$0")/.env" 2>/dev/null || true

CLAW_USER="${CLAW_USER:-oauthbroker}"
CLAW_HOME="${CLAW_HOME:-/data/oauth-broker}"
CLAW_IMAGE="${CLAW_IMAGE:-oauth-broker:local}"
CLAW_PORT="${CLAW_PORT:-8420}"
CLAW_MEMORY="${CLAW_MEMORY:-2g}"
CLAW_CPUS="${CLAW_CPUS:-2}"
CLAW_DNS_PRIMARY="${CLAW_DNS_PRIMARY:-100.100.100.100}"
CLAW_DNS_FALLBACK="${CLAW_DNS_FALLBACK:-1.1.1.1}"

QUADLET_DIR="${CLAW_HOME}/.config/containers/systemd"
_UID=$(id -u "${CLAW_USER}")
_GID=$(id -g "${CLAW_USER}")

sudo -u "${CLAW_USER}" mkdir -p "${QUADLET_DIR}"
chmod 700 "${CLAW_HOME}/.config" "${CLAW_HOME}/.config/containers" "${QUADLET_DIR}"

# --- Pod definition ---------------------------------------------------------
# The pod owns the port binding (127.0.0.1 only — SSH tunnel for external access).
# Both containers join this pod and share its network namespace.
cat > "${QUADLET_DIR}/oauth-broker.pod" << PODEOF
# OAuth Broker pod — shared network namespace for broker + Redis sidecar
# Security: port published to loopback only; access via SSH tunnel

[Unit]
Description=OAuth Broker pod

[Pod]
PublishPort=127.0.0.1:${CLAW_PORT}:${CLAW_PORT}

[Install]
WantedBy=default.target
PODEOF

# --- Redis sidecar ----------------------------------------------------------
# Runs inside the pod; not exposed to the host. Broker connects via localhost.
cat > "${QUADLET_DIR}/oauth-broker-redis.container" << REDISEOF
# OAuth Broker — Redis sidecar (pod-internal only)

[Unit]
Description=OAuth Broker — Redis
After=oauth-broker-pod.service
Requires=oauth-broker-pod.service

[Container]
Image=docker.io/library/redis:7-alpine
ContainerName=oauth-broker-redis
Pod=oauth-broker.pod

Volume=${CLAW_HOME}/redis-data:/data

HealthCmd=redis-cli ping
HealthInterval=5s
HealthTimeout=3s
HealthRetries=5

Pull=missing

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
REDISEOF

# --- OAuth Broker container -------------------------------------------------
cat > "${QUADLET_DIR}/oauth-broker.container" << BROKEREOF
# OAuth Broker — FastAPI token broker (rootless Podman)

[Unit]
Description=OAuth Broker
After=oauth-broker-redis.service
Requires=oauth-broker-redis.service

[Container]
Image=${CLAW_IMAGE}
ContainerName=oauth-broker
Pod=oauth-broker.pod

# Non-secret runtime config (OB_ENCRYPTION_KEY is injected via Secret= below)
EnvironmentFile=${CLAW_HOME}/.env
Environment=OB_HOST=0.0.0.0
Environment=OB_PORT=${CLAW_PORT}
Environment=OB_REDIS_URL=redis://localhost:6379/0
Environment=OB_SQLITE_PATH=/data/oauth_broker.db

# Encryption key for refresh tokens at rest — never in .env or environment
Secret=OB_ENCRYPTION_KEY,type=env

# Persistent data (SQLite DB)
Volume=${CLAW_HOME}/data:/data

# DNS (Tailscale MagicDNS + fallback)
DNS=${CLAW_DNS_PRIMARY}
DNS=${CLAW_DNS_FALLBACK}

# Resource limits
PodmanArgs=--memory=${CLAW_MEMORY} --cpus=${CLAW_CPUS}

Pull=never

[Service]
Restart=on-failure
TimeoutStartSec=60

[Install]
WantedBy=default.target
BROKEREOF

chown -R "${CLAW_USER}:${CLAW_USER}" "${QUADLET_DIR}"
chmod 600 \
    "${QUADLET_DIR}/oauth-broker.pod" \
    "${QUADLET_DIR}/oauth-broker-redis.container" \
    "${QUADLET_DIR}/oauth-broker.container"

echo "Quadlets written to ${QUADLET_DIR}/"
echo ""
echo "To start the service:"
echo "  systemctl --machine ${CLAW_USER}@ --user daemon-reload"
echo "  systemctl --machine ${CLAW_USER}@ --user start oauth-broker.service"
echo "  systemctl --machine ${CLAW_USER}@ --user enable oauth-broker.service"
echo ""
echo "To verify:"
echo "  systemctl --machine ${CLAW_USER}@ --user status oauth-broker.service"
echo "  journalctl --machine ${CLAW_USER}@ --user -u oauth-broker.service -f"
echo ""
echo "To access (SSH tunnel from local machine):"
echo "  ssh -L ${CLAW_PORT}:127.0.0.1:${CLAW_PORT} \${CLAW_HOST}"
echo "  curl http://localhost:${CLAW_PORT}/health"
