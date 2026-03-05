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
CLAW_UID="$(id -u "${CLAW_USER}")"
PODMAN_ENV="XDG_RUNTIME_DIR=/run/user/${CLAW_UID}"

# Create directories
sudo -u "${CLAW_USER}" mkdir -p "${CONFIG_DIR}"
sudo -u "${CLAW_USER}" mkdir -p "${WORKSPACE_DIR}"

# Generate gateway token and store as podman secret (never written to disk)
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
elif [[ "${CLAW_VARIANT}" == "tradeclaw" ]]; then
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
        "mode": "off"
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
    "deny": ["gateway", "sessions_spawn", "sessions_send"],
    "fs": {
      "workspaceOnly": true
    },
    "exec": {
      "security": "deny"
    },
    "elevated": {
      "enabled": false
    },
    "trading": {
      "enabled": true,
      "fork_mode": false
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

# Store gateway token as a podman secret (never written to disk)
printf "%s" "${GATEWAY_TOKEN}" | \
    sudo -u "${CLAW_USER}" env "${PODMAN_ENV}" podman secret create --replace "${TOKEN_VAR}" -

# Write .env for non-secret runtime config (token is injected via podman secret at runtime)
sudo -u "${CLAW_USER}" tee "${CONFIG_DIR}/.env" > /dev/null << 'ENVEOF'
# Non-secret runtime environment variables for this variant.
# Secrets (gateway token, Telegram bot token, private keys) are managed via
# podman secret create — do NOT add secret values here.
ENVEOF

# Set ownership
chown -R "${CLAW_USER}:${CLAW_USER}" "${CONFIG_DIR}"
chown -R "${CLAW_USER}:${CLAW_USER}" "${WORKSPACE_DIR}"

echo "Configuration written to ${CONFIG_DIR}/${CONFIG_FILENAME}"
echo "Environment file written to ${CONFIG_DIR}/.env"
echo "Gateway token stored as podman secret: ${TOKEN_VAR}"
echo ""
echo "NEXT: Store Telegram bot token as podman secret (as service user):"
echo "      printf '%s' '<token>' | sudo -u ${CLAW_USER} env ${PODMAN_ENV} podman secret create --replace TELEGRAM_BOT_TOKEN -"
if [[ "${CLAW_VARIANT}" == "picoclaw" ]]; then
    echo "NEXT: After container starts, run OpenAI OAuth login:"
    echo "      ${CLAW_VARIANT} auth login --provider openai"
    echo "      (Device code flow — works headlessly)"
else
    echo "NEXT: Add ANTHROPIC_API_KEY to ${CONFIG_DIR}/.env"
    echo "NEXT: Run OAuth login after container starts"
fi
