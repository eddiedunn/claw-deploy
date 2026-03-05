# Claw Deploy Runbook

Operational runbook for claw-family deployments. Covers day-2 operations, troubleshooting, and known gotchas learned from production deploys.

## Quick Reference

All commands assume SSH to the target host. Replace `$USER` and `$VARIANT` with the service user and claw variant.

| Task | Command |
|------|---------|
| Service status | `ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) systemctl --user status $VARIANT.service'"` |
| Restart | `ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) systemctl --user restart $VARIANT.service'"` |
| Logs (systemd) | `ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) journalctl --user -u $VARIANT.service -n 100 --no-pager'"` |
| Logs (podman) | `ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman logs --tail 100 $VARIANT'"` |
| Re-auth OpenAI | `ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman exec $VARIANT $VARIANT auth login --device-code'"` |
| Container shell | `ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman exec -it $VARIANT sh'"` |

## Initial Deploy

Follow the [README](README.md) deployment steps (01 through 05 scripts).

### Post-Deploy Checklist

1. **Config file name**: Verify the config file is named `config.json` (NOT `<variant>.json`). The binary always reads `config.json`.
2. **Auth**: Run `auth login --device-code` inside the container (see Re-Auth section below).
3. **Telegram**: Add bot token, send a message, approve the device.
4. **Service running**: Check `systemctl --user status` shows active.
5. **Logs clean**: Check logs for startup errors.

## Day-2 Operations

### Restart Service

```bash
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) systemctl --user restart $VARIANT.service'"
```

### View Logs

**Systemd journal** (includes start/stop events):
```bash
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) journalctl --user -u $VARIANT.service -n 200 --no-pager'"
```

**Podman container logs** (stdout/stderr from the process):
```bash
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman logs --tail 200 $VARIANT'"
```

**Follow logs live**:
```bash
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman logs -f $VARIANT'"
```

### Re-Auth OpenAI (Device Code Flow)

The `auth login` command uses OAuth. On headless servers, use `--device-code` to avoid TTY issues.

> **WARNING**: `auth login` rewrites the entire config file with defaults. Back up first!

**Step-by-step:**

1. Back up config:
   ```bash
   ssh $HOST "sudo -u $USER -H sh -c 'cd /data/$USER && cp .${VARIANT}/config.json .${VARIANT}/config.json.bak'"
   ```

2. Run device-code auth:
   ```bash
   ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman exec $VARIANT $VARIANT auth login --device-code'"
   ```

3. Follow the URL printed, enter the code in your browser, authorize.

4. Restore gateway/channel settings that `auth login` overwrote:
   ```bash
   # Compare and restore settings auth login clobbered
   ssh $HOST "sudo -u $USER -H sh -c 'cd /data/$USER && diff .${VARIANT}/config.json.bak .${VARIANT}/config.json'"
   # If gateway_url, channels, etc. were overwritten, restore from backup:
   # Edit config.json to merge the auth token from new config with settings from backup
   ```

5. Restart the service:
   ```bash
   ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) systemctl --user restart $VARIANT.service'"
   ```

### Rebuild After Code Changes

```bash
# On the target host, as the service user
ssh $HOST "sudo -u $USER -H sh -c 'cd /data/$USER/$VARIANT && git pull'"
ssh $HOST "sudo -u $USER -H sh -c 'cd /data/$USER/$VARIANT && XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman build -t $VARIANT .'"
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) systemctl --user restart $VARIANT.service'"
```

### Config Changes

Config lives at `/data/$USER/.$VARIANT/config.json`.

```bash
# Edit config (use podman exec for in-container edits, or edit the mounted volume)
ssh $HOST "sudo -u $USER -H sh -c 'vi /data/$USER/.$VARIANT/config.json'"

# Restart to pick up changes
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) systemctl --user restart $VARIANT.service'"
```

### Check Auth Token Expiry

```bash
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman exec $VARIANT $VARIANT auth status'"
```

If expired, follow the Re-Auth steps above.

## Secrets Management

### Architecture

Secrets are managed via **podman secrets** (not `.env` files). This keeps credentials out of the filesystem and git history.

| Layer | What goes here | Example |
|-------|---------------|---------|
| Podman secrets | Credentials, private keys, tokens | `PRIVATE_KEY`, `TELEGRAM_BOT_TOKEN`, `TRADECLAW_GATEWAY_TOKEN`, `OB_ENCRYPTION_KEY` |
| `.env` file | Non-sensitive config | `BASE_RPC_URL`, `ZEROX_API_KEY`, `OB_LOG_LEVEL` |
| `config.json` | App configuration | Gateway port, agent settings, tool config |

Podman secrets are injected as environment variables via `--secret NAME,type=env` in the systemd service file.

### Helper: Running podman commands as the service user

All podman secret commands must run as the service user with `XDG_RUNTIME_DIR` set:

```bash
# Pattern (replace $HOST, $USER, and COMMAND)
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) COMMAND'"
```

### List current secrets

```bash
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman secret ls'"
```

### Verify secrets are available inside the container

```bash
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman exec $VARIANT printenv | grep -E \"PRIVATE_KEY|TELEGRAM|GATEWAY_TOKEN\"'"
```

> **Note**: This prints the actual values. Only use for verification, not in logs.

---

## Rotation Runbooks

### Rotate EVM Wallet Key (PRIVATE_KEY)

Use this when the wallet key is compromised, or when generating a fresh wallet.

**Pre-rotation (if compromised):**
1. Transfer any remaining funds out of the old wallet immediately using another wallet tool (e.g., MetaMask)
2. The old key is burned — never reuse it

**Generate a new wallet:**

```bash
# Option 1: Use cast (from foundry toolkit)
cast wallet new

# Option 2: Use Node.js with viem
node -e "const { generatePrivateKey, privateKeyToAccount } = require('viem/accounts'); const key = generatePrivateKey(); const acct = privateKeyToAccount(key); console.log('Address:', acct.address); console.log('Private key:', key);"

# Option 3: Use openssl (raw — you'll need to derive the address separately)
echo "0x$(openssl rand -hex 32)"
```

Save the new private key securely (password manager, not a file in a repo).

**Rotate the podman secret:**

```bash
# Remove old secret
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman secret rm PRIVATE_KEY'"

# Create new secret (replace 0xNEW_KEY with the actual key)
ssh $HOST "sudo -u $USER -H sh -c 'printf \"%s\" \"0xNEW_KEY\" | XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman secret create PRIVATE_KEY -'"

# Restart service to pick up the new key
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) systemctl --user restart $VARIANT.service'"
```

**Post-rotation:**
1. Verify the container has the new key: `podman exec $VARIANT printenv PRIVATE_KEY` (first 6 chars should match)
2. Fund the new wallet with ETH on Base for gas
3. Test with a small trade: `trade_quote` then `trade_swap` with a minimal amount
4. Update any monitoring or address book entries with the new wallet address

**Example:**

```bash
# Remove + create (replace $HOST, $USER, $VARIANT with your values)
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman secret rm PRIVATE_KEY && printf \"%s\" \"0xYOUR_NEW_KEY\" | XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman secret create PRIVATE_KEY -'"

# Restart
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) systemctl --user restart $VARIANT.service'"
```

---

### Rotate Telegram Bot Token

Use this when the bot token is compromised, or if you want to create a fresh bot.

**Step 1: Revoke the old token via @BotFather**

1. Open Telegram, message [@BotFather](https://t.me/BotFather)
2. Send `/revoke`
3. Select the bot whose token you want to revoke
4. BotFather confirms the token is revoked — **the old token stops working immediately**

**Step 2: Get the new token**

- If revoking and keeping the same bot: BotFather gives you a new token after `/revoke`
- If creating a new bot: `/newbot` → follow prompts → get the new token

**Step 3: Rotate the podman secret**

```bash
# Remove old secret
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman secret rm TELEGRAM_BOT_TOKEN'"

# Create new secret (replace NEW_TOKEN with the actual token, format: 123456:ABCdef...)
ssh $HOST "sudo -u $USER -H sh -c 'printf \"%s\" \"NEW_TOKEN\" | XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman secret create TELEGRAM_BOT_TOKEN -'"

# Restart service
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) systemctl --user restart $VARIANT.service'"
```

**Step 4: Re-pair Telegram**

After rotating the bot token, existing device pairings are invalidated. Re-pair:

1. Send a message to the bot in Telegram
2. Approve the device pairing:
   ```bash
   ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman exec $VARIANT $VARIANT devices approve --latest'"
   ```

**Step 5: Verify**

```bash
# Check logs for successful Telegram connection
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman logs --tail 50 $VARIANT'" | grep -i telegram
```

**Example:**

```bash
# Rotate secret (replace $HOST, $USER, $VARIANT with your values)
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman secret rm TELEGRAM_BOT_TOKEN && printf \"%s\" \"123456:ABCnewtoken\" | XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman secret create TELEGRAM_BOT_TOKEN -'"

# Restart
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) systemctl --user restart $VARIANT.service'"

# Re-pair (after sending a message to the bot)
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman exec $VARIANT $VARIANT devices approve --latest'"
```

---

### Rotate Gateway Token (${VARIANT^^}_GATEWAY_TOKEN)

Use this if the gateway token is exposed or as a periodic rotation.

The token is stored exclusively as a podman secret — it is never written to `.env` or any file on disk.

```bash
# Generate a new token
NEW_TOKEN=$(openssl rand -hex 32)

# Replace podman secret
ssh $HOST "sudo -u $USER -H sh -c 'printf \"%s\" \"$NEW_TOKEN\" | XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman secret create --replace ${VARIANT^^}_GATEWAY_TOKEN -'"

# Update config.json to match (gateway.auth.token and gateway.remote.token)
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman exec $VARIANT $VARIANT config set gateway.auth.token $NEW_TOKEN'"
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) podman exec $VARIANT $VARIANT config set gateway.remote.token $NEW_TOKEN'"

# Restart so the container picks up the new secret
ssh $HOST "sudo -u $USER -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) systemctl --user restart $VARIANT.service'"
```

> **Important**: The gateway token must match in both the podman secret (env var) and `config.json`. If they diverge, you'll get "gateway token mismatch" errors.

---

### Rotate OAuth Broker Encryption Key (OB_ENCRYPTION_KEY)

Use this if the Fernet encryption key for stored refresh tokens is compromised.

> **Warning**: Rotating this key invalidates all encrypted refresh tokens. After rotation, users must re-authenticate via `GET /auth/{provider}/login` for each provider.

```bash
# Generate a new Fernet key (requires python3 + cryptography on the host, or generate elsewhere)
NEW_KEY=$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')

# Replace podman secret (as oauthbroker user)
ssh $HOST "sudo -u oauthbroker -H sh -c 'printf \"%s\" \"$NEW_KEY\" | XDG_RUNTIME_DIR=/run/user/\$(id -u oauthbroker) podman secret create --replace OB_ENCRYPTION_KEY -'"

# Restart the service to pick up the new key
ssh $HOST "sudo -u oauthbroker -H sh -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u oauthbroker) systemctl --user restart oauth-broker.service'"
```

After restarting, re-authenticate each provider via the login URL (requires SSH tunnel to port 8420):

```bash
ssh -L 8420:127.0.0.1:8420 $HOST
curl http://localhost:8420/auth/anthropic/login   # follow printed URL
curl http://localhost:8420/auth/openai/login      # follow printed URL
```

---

### Emergency Rotation Checklist

If you suspect a full compromise (private key + tokens leaked):

1. **Wallet first**: Transfer funds out, then rotate `PRIVATE_KEY` (see above)
2. **Telegram**: Revoke via @BotFather `/revoke`, rotate `TELEGRAM_BOT_TOKEN`
3. **Gateway**: Rotate `TRADECLAW_GATEWAY_TOKEN`
4. **OpenAI auth**: Re-authenticate with `auth login --device-code` (see Re-Auth section)
5. **Git history**: If secrets were committed, purge with `git filter-repo` and force-push
6. **GitHub**: Check for exposed secrets at GitHub repo Settings → Security → Secret scanning
7. **Audit**: Review recent transactions on the wallet address via [BaseScan](https://basescan.org)

---

## Fork Mode Testing

Fork mode lets you test tradeclaw's trading tools against a local Anvil fork of Base mainnet. No real funds are used — all transactions hit the fork.

### Prerequisites

Install Foundry (provides `anvil` and `cast`):

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup
```

### Start the Anvil fork

```bash
# In the tradeclaw repo:
make fork

# Or manually:
anvil --fork-url ${BASE_RPC_URL:-https://mainnet.base.org} --chain-id 8453
```

Anvil listens on `http://127.0.0.1:8545` by default.

### Run tradeclaw in fork mode

```bash
# In another terminal:
TRADECLAW_FORK_MODE=true make run
```

Or set `TRADECLAW_FORK_MODE=true` in your `.env` file.

### Fund the test wallet

From the tradeclaw agent, use the `trade_fund_fork` tool, or manually:

```bash
# Fund with 100 ETH (replace ADDRESS with your wallet address)
cast rpc anvil_setBalance ADDRESS $(cast to-wei 100 ether | cast to-hex --base-in 10)
```

### Container fork mode

To test fork mode inside the container, pass the env var:

```bash
# Add to .env on the host
TRADECLAW_FORK_MODE=true
TRADECLAW_FORK_RPC_URL=http://host.containers.internal:8545
```

Anvil must be running on the host, and the container must be able to reach it (e.g., via `host.containers.internal` or the host's IP).

> **WARNING**: NEVER enable fork mode in production. Fork mode bypasses 0x routing and uses a local fork with no real on-chain state. All trades are simulated only.

---

## Known Gotchas

### Config file must be `config.json`

The binary always reads `config.json` from its config directory. If you name it `tradeclaw.json` or `openclaw.json`, it will be ignored and the binary will use defaults. Always use `config.json`.

### `auth login` rewrites full config

Running `auth login` replaces the entire config file with defaults plus the new auth token. This **destroys** your gateway URL, channel settings, and any custom configuration.

**Always back up `config.json` before running `auth login`**, then restore your custom settings after.

### `sudo -u <user>` needs `sh -c 'cd <home> && ...'` pattern

Plain `sudo -u tradeclaw <command>` fails because the calling user's cwd may not be accessible to the target user. Always wrap in:

```bash
sudo -u $USER -H sh -c 'cd /data/$USER && COMMAND'
```

The `-H` flag sets `$HOME` to the target user's home directory.

### Podman < 4.4: no Quadlet support

Quadlet (systemd generator for Podman containers) requires Podman 4.4+. On Debian Bookworm (ships Podman 4.3.1), you must create a manual systemd user service file instead of using `.container` Quadlet files.

Manual service file location: `~/.config/systemd/user/$VARIANT.service`

Example service file:
```ini
[Unit]
Description=%i claw agent
After=network-online.target

[Service]
Restart=on-failure
RestartSec=10
ExecStartPre=-/usr/bin/podman rm -f %i
ExecStart=/usr/bin/podman run --name %i \
  --userns=keep-id \
  -v /data/%i/.%i:/home/appuser/.%i:Z \
  %i:latest
ExecStop=/usr/bin/podman stop %i

[Install]
WantedBy=default.target
```

### `docker.io` in registries.conf

Podman on Debian may not have `docker.io` configured as an unqualified search registry. If `podman pull` fails to find images, add:

```
# /etc/containers/registries.conf (or registries.conf.d/)
unqualified-search-registries = ["docker.io"]
```

### Deploy keys for private repos

Private GitHub repos need a deploy key on the target host. Generate one on the host and add it to the repo's deploy keys in GitHub Settings.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/deploy_key -N ""
# Add the public key to GitHub repo → Settings → Deploy keys
```

### `--userns=keep-id` for volume permissions

Without `--userns=keep-id`, files written to mounted volumes inside the container will have root ownership on the host. Always include this flag in `podman run`.

## Server Inventory

Maintain a local inventory file (gitignored) at `.server-inventory.md` alongside your `.env` files. The table below is a template — replace with your actual host details.

| Host | Tailscale Name | OS | SSH User | Service User | UID | Home | Podman Version | Quadlet Support |
|------|---------------|-----|----------|-------------|-----|------|----------------|-----------------|
| your-server | `your-host` | Debian Bookworm | your-user | tradeclaw | — | /data/tradeclaw | — | Yes |

> Use Tailscale magic DNS hostnames for SSH where available, not IP addresses.
