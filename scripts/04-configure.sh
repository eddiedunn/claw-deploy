#!/usr/bin/env bash
set -euo pipefail

# Generate security-hardened configuration for the configured variant
# Run as root on the target host

# Source environment configuration
source "$(dirname "$0")/../.env" 2>/dev/null || true

# Source variant library
source "$(dirname "$0")/../lib/variant.sh"

CLAW_VARIANT="${CLAW_VARIANT:-openclaw}"
CLAW_USER="${CLAW_USER:-openclaw}"
CLAW_HOME="${CLAW_HOME:-/data/openclaw}"

CONFIG_DIR="$(variant_state_dir "$CLAW_VARIANT" "default" "$CLAW_HOME")"
CONFIG_FILENAME="$(variant_config_filename "$CLAW_VARIANT")"
TOKEN_VAR="$(variant_token_env_var "$CLAW_VARIANT")"
WORKSPACE_DIR="${CLAW_HOME}/workspace"

# Create directories
sudo -u "${CLAW_USER}" mkdir -p "${CONFIG_DIR}"
sudo -u "${CLAW_USER}" mkdir -p "${WORKSPACE_DIR}"

# Generate gateway token
GATEWAY_TOKEN=$(openssl rand -hex 32)

# Write config JSON (variant-specific format)
if [[ "${CLAW_VARIANT}" == "picoclaw" ]]; then
    cat > "${CONFIG_DIR}/${CONFIG_FILENAME}" << 'CONFIGEOF'
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "auth": {
      "mode": "token"
    },
    "controlUi": {
      "allowInsecureAuth": false,
      "dangerouslyDisableDeviceAuth": false
    }
  },
  "channels": {
    "telegram": {
      "dmPolicy": "pairing",
      "groups": {
        "*": {
          "requireMention": true
        }
      }
    }
  },
  "agents": {
    "defaults": {
      "model_name": "codex",
      "max_tokens": 32768,
      "sandbox": {
        "mode": "all",
        "scope": "agent",
        "workspaceAccess": "ro"
      }
    }
  },
  "model_list": [
    {
      "model_name": "codex",
      "model": "openai/gpt-5.2",
      "auth_method": "oauth"
    }
  ],
  "tools": {
    "deny": ["gateway", "cron", "sessions_spawn", "sessions_send"],
    "fs": {
      "workspaceOnly": true
    },
    "exec": {
      "security": "deny"
    },
    "elevated": {
      "enabled": false
    }
  },
  "session": {
    "dmScope": "per-channel-peer"
  },
  "discovery": {
    "mdns": {
      "mode": "off"
    }
  },
  "logging": {
    "redactSensitive": "tools"
  }
}
CONFIGEOF
elif [[ "${CLAW_VARIANT}" == "gclaw" ]]; then
    # GDEX credentials: read from .env if set, otherwise use placeholders
    _GDEX_API_KEY="${GDEX_API_KEY:-3f6c9e12-7b41-4c2a-9d5e-1a8f3b7e6c90,8d2a5f47-2e13-4b9c-a6f1-0c9e7d3a5b21}"
    _WALLET_ADDRESS="${WALLET_ADDRESS:-REPLACE_WITH_YOUR_EVM_WALLET_ADDRESS}"
    _PRIVATE_KEY="${PRIVATE_KEY:-REPLACE_WITH_YOUR_EVM_PRIVATE_KEY}"
    cat > "${CONFIG_DIR}/${CONFIG_FILENAME}" << CONFIGEOF
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "auth": {
      "mode": "token"
    },
    "controlUi": {
      "allowInsecureAuth": false,
      "dangerouslyDisableDeviceAuth": false
    }
  },
  "channels": {
    "telegram": {
      "dmPolicy": "pairing",
      "groups": {
        "*": {
          "requireMention": true
        }
      }
    }
  },
  "agents": {
    "defaults": {
      "model_name": "codex",
      "sandbox": {
        "mode": "all",
        "scope": "agent",
        "workspaceAccess": "ro"
      }
    }
  },
  "model_list": [
    {
      "model_name": "codex",
      "model": "openai/gpt-5.2",
      "auth_method": "oauth"
    },
    {
      "model_name": "claude",
      "model": "anthropic/claude-sonnet-4-6",
      "auth_method": "oauth"
    }
  ],
  "tools": {
    "deny": ["gateway", "cron", "sessions_spawn", "sessions_send"],
    "fs": {
      "workspaceOnly": true
    },
    "exec": {
      "security": "deny"
    },
    "elevated": {
      "enabled": false
    },
    "gdex": {
      "enabled": true,
      "api_key": "${_GDEX_API_KEY}",
      "wallet_address": "${_WALLET_ADDRESS}",
      "private_key": "${_PRIVATE_KEY}"
    }
  },
  "session": {
    "dmScope": "per-channel-peer"
  },
  "discovery": {
    "mdns": {
      "mode": "off"
    }
  },
  "logging": {
    "redactSensitive": "tools"
  }
}
CONFIGEOF
else
    cat > "${CONFIG_DIR}/${CONFIG_FILENAME}" << 'CONFIGEOF'
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "auth": {
      "mode": "token"
    },
    "controlUi": {
      "allowInsecureAuth": false,
      "dangerouslyDisableDeviceAuth": false
    }
  },
  "channels": {
    "telegram": {
      "dmPolicy": "pairing",
      "groups": {
        "*": {
          "requireMention": true
        }
      }
    }
  },
  "agents": {
    "defaults": {
      "sandbox": {
        "mode": "all",
        "scope": "agent",
        "workspaceAccess": "ro"
      }
    }
  },
  "tools": {
    "deny": ["gateway", "cron", "sessions_spawn", "sessions_send"],
    "fs": {
      "workspaceOnly": true
    },
    "exec": {
      "security": "deny"
    },
    "elevated": {
      "enabled": false
    }
  },
  "session": {
    "dmScope": "per-channel-peer"
  },
  "discovery": {
    "mdns": {
      "mode": "off"
    }
  },
  "logging": {
    "redactSensitive": "tools"
  }
}
CONFIGEOF
fi

# Write .env with variant-specific token var name
if [[ "${CLAW_VARIANT}" == "picoclaw" ]]; then
    cat > "${CONFIG_DIR}/.env" << ENVEOF
${TOKEN_VAR}=${GATEWAY_TOKEN}
ENVEOF
elif [[ "${CLAW_VARIANT}" == "gclaw" ]]; then
    cat > "${CONFIG_DIR}/.env" << ENVEOF
${TOKEN_VAR}=${GATEWAY_TOKEN}
ENVEOF
else
    cat > "${CONFIG_DIR}/.env" << ENVEOF
${TOKEN_VAR}=${GATEWAY_TOKEN}
ENVEOF
fi

# Set ownership
chown -R "${CLAW_USER}:${CLAW_USER}" "${CONFIG_DIR}"
chown -R "${CLAW_USER}:${CLAW_USER}" "${WORKSPACE_DIR}"

echo "Configuration written to ${CONFIG_DIR}/${CONFIG_FILENAME}"
echo "Environment file written to ${CONFIG_DIR}/.env"
echo "Gateway token generated (saved in .env)"
echo ""
echo "NEXT: Add Telegram bot token to ${CONFIG_DIR}/.env"
if [[ "${CLAW_VARIANT}" == "picoclaw" ]]; then
    echo "NEXT: After container starts, run OpenAI OAuth login:"
    echo "      ${CLAW_VARIANT} auth login --provider openai"
    echo "      (Device code flow — works headlessly)"
elif [[ "${CLAW_VARIANT}" == "gclaw" ]]; then
    echo "NEXT: After container starts, run Codex OAuth login (PKCE flow):"
    echo "      gclaw auth login --provider openai"
    echo "      (Prints auth URL — paste redirect URL back when prompted)"
else
    echo "NEXT: Add ANTHROPIC_API_KEY to ${CONFIG_DIR}/.env"
    echo "NEXT: Run OAuth login after container starts"
fi
