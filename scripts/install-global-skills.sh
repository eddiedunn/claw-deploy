#!/usr/bin/env bash
set -euo pipefail

# Install global skills to a claw host
# Usage: ./install-global-skills.sh [host]
#
# Rsyncs global-skills/ → <CLAW_HOME>/shared/skills/ on the target machine.
# Source .env for CLAW_HOST, CLAW_SSH_USER, CLAW_HOME before running.
#
# Run this explicitly after updating any global skill:
#   ./scripts/install-global-skills.sh
#   ./scripts/install-global-skills.sh trinity

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source environment configuration
source "${SCRIPT_DIR}/../.env" 2>/dev/null || source "${SCRIPT_DIR}/.env" 2>/dev/null || true

# Allow host override as argument
if [[ $# -ge 1 ]]; then
    CLAW_HOST="$1"
fi

CLAW_HOST="${CLAW_HOST:-trinity}"
CLAW_SSH_USER="${CLAW_SSH_USER:-root}"
CLAW_HOME="${CLAW_HOME:-/data/picoclaw}"

GLOBAL_SKILLS_SRC="${REPO_ROOT}/global-skills/"
GLOBAL_SKILLS_DEST="${CLAW_SSH_USER}@${CLAW_HOST}:${CLAW_HOME}/shared/skills/"

echo "Installing global skills to ${CLAW_HOST}..."
echo "  Source : ${GLOBAL_SKILLS_SRC}"
echo "  Dest   : ${GLOBAL_SKILLS_DEST}"
echo ""

# Ensure destination directory exists on remote
ssh "${CLAW_SSH_USER}@${CLAW_HOST}" "mkdir -p ${CLAW_HOME}/shared/skills"

# Rsync global-skills/ to remote shared/skills/
rsync -avz --delete \
    --exclude='*.swp' \
    --exclude='.DS_Store' \
    "${GLOBAL_SKILLS_SRC}" \
    "${GLOBAL_SKILLS_DEST}"

echo ""
echo "Global skills installed successfully."
echo ""
echo "Installed skills:"
ssh "${CLAW_SSH_USER}@${CLAW_HOST}" "ls -1 ${CLAW_HOME}/shared/skills/ 2>/dev/null || echo '  (none found)'"
