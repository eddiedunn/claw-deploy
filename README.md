# Claw Deploy

Rootless Podman deployment for claw-family AI agent platforms with Telegram integration. Supports four variants:

- **[OpenClaw](https://github.com/openclaw/openclaw)** — open-source AI agent platform
- **[PicoClaw](https://github.com/picoclaw/picoclaw)** — lightweight variant
- **[Gclaw](https://github.com/gclaw/gclaw)** — fork of PicoClaw
- **[Tradeclaw](https://github.com/eddiedunn/tradeclaw)** — fork of PicoClaw for direct Base chain trading (Go binary)

## Setup

**1. Configure your environment**

```bash
cp .env.example .env
vi .env   # Set your host, variant, IPs, ports, and resource limits
```

All scripts source `.env` automatically. See [.env.example](.env.example) for all available options.

Recommended env vars to set:

```
CLAW_VARIANT=openclaw
CLAW_HOST=your.host.or.ip
CLAW_SSH_USER=sshuser
CLAW_USER=openclaw
CLAW_HOME=/data/openclaw
```

**2. Run deployment scripts (as root on target host)**

```bash
bash scripts/01-create-user.sh     # Create dedicated nologin system user
bash scripts/02-setup-podman.sh    # Configure rootless Podman
bash scripts/03-clone-and-build.sh # Clone source and build container image
bash scripts/04-configure.sh       # Generate hardened config + gateway token
bash scripts/05-deploy-quadlet.sh  # Deploy systemd quadlet (auto-starts on boot)
```

Set `CLAW_VARIANT` in `.env` before running to deploy a different variant.

**3. Post-deploy (interactive)**

```bash
# Add Telegram bot — get token from @BotFather
podman exec -it openclaw openclaw channels add --channel telegram --token <TOKEN>

# Run configure wizard — set up Anthropic OAuth
podman exec -it openclaw openclaw configure

# Restart after config changes
systemctl --user restart openclaw.service

# Pair your Telegram account — send any message to bot, then approve
podman exec openclaw openclaw devices approve --latest
```

> All `podman` and `systemctl --user` commands run as the service user. See [Operations](#operations) for the full invocation pattern.

## Operations

Commands run as the service user (configured in `.env`):

```bash
# Service lifecycle (container name matches variant)
systemctl --user status openclaw.service
systemctl --user restart openclaw.service

# Container logs
podman logs --tail 50 openclaw

# Config changes
podman exec openclaw openclaw config set <key> <value>

# Manual backup
bash multi-instance/backup.sh
```

> **SSH access pattern**: `ssh <host> 'sudo -u <user> XDG_RUNTIME_DIR=/run/user/$(id -u <user>) <command>'`

## Codex OAuth (OpenAI)

Codex OAuth requires a recent build that includes the OpenAI/Codex auth flow.
If you see "No provider plugins found" in the container, rebuild the image from the
upstream repo and restart the service.

Rebuild (on host, as the service user):

```bash
cd /data/openclaw/openclaw-src
git pull --ff-only
podman build -t openclaw:local -f Dockerfile .
```

Restart:

```bash
sudo -u openclaw XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) systemctl --user restart openclaw.service
```

Run Codex OAuth (interactive TTY required):

```bash
ssh -tt "${CLAW_SSH_USER:-user}@${CLAW_HOST:-host}" \
  "SVC_USER='${CLAW_USER:-openclaw}' && SVC_UID=\$(id -u \"\$SVC_USER\") && \
  cd /tmp && sudo -u \"\$SVC_USER\" XDG_RUNTIME_DIR=\"/run/user/\$SVC_UID\" \
  podman exec -it openclaw node dist/index.js onboard --auth-choice openai-codex"
```

Then set the default model and restart the gateway:

```bash
claw default config set agents.defaults.model.primary openai-codex/gpt-5.3-codex
claw default gateway restart
```

## Troubleshooting

### Gateway token mismatch (unauthorized)

Symptom:
- `gateway token mismatch` when running CLI commands.

Fix (on host):

```bash
SVC_USER="${CLAW_USER:-openclaw}"
SVC_UID="$(id -u "$SVC_USER")"
CLAW_HOME="${CLAW_HOME:-/data/openclaw}"
VARIANT="${CLAW_VARIANT:-openclaw}"
TOKEN="$(sudo -u "$SVC_USER" sed -n "s/^${VARIANT^^}_GATEWAY_TOKEN=//p" "$CLAW_HOME/.${VARIANT}/.env")"
sudo -u "$SVC_USER" XDG_RUNTIME_DIR="/run/user/$SVC_UID" podman exec -i "$VARIANT" node dist/index.js config set gateway.auth.token "$TOKEN"
sudo -u "$SVC_USER" XDG_RUNTIME_DIR="/run/user/$SVC_UID" podman exec -i "$VARIANT" node dist/index.js config set gateway.remote.token "$TOKEN"
sudo -u "$SVC_USER" XDG_RUNTIME_DIR="/run/user/$SVC_UID" systemctl --user restart "${VARIANT}.service"
```

### `claw default gateway restart` fails locally

Symptom:
- `systemctl --user unavailable` on your local machine.

Fix:

```bash
ssh "${CLAW_SSH_USER:-user}@${CLAW_HOST:-host}" \
  "cd /tmp && SVC_USER='${CLAW_USER:-openclaw}' && SVC_UID=\$(id -u \"\$SVC_USER\") && \
  sudo -u \"\$SVC_USER\" XDG_RUNTIME_DIR=\"/run/user/\$SVC_UID\" systemctl --user restart ${CLAW_VARIANT:-openclaw}.service"
```

### Dashboard

The gateway UI is loopback-only. Access via SSH tunnel:

```bash
ssh -L 18789:127.0.0.1:18789 your-server
# Open http://localhost:18789
```

Gateway token is in `<CLAW_HOME>/.<variant>/.env`.

### Backups

Automated daily at 3am via systemd timer. 14-day retention, gzip compressed.

```bash
# Check timer
systemctl --user list-timers

# List backups
ls -lh backups/
```

## Multi-Instance

Run multiple isolated instances (of any variant) sharing a common skills library. See [multi-instance/README.md](multi-instance/README.md) for full documentation.

```bash
# Quick start
bash claw-instance.sh create research                    # New openclaw instance
bash claw-instance.sh create pico-dev --variant picoclaw # New picoclaw instance
bash claw-instance.sh list                               # Show all instances
bash claw-instance.sh start research                     # Start it
bash claw-instance.sh destroy research                   # Remove it
```

## CLI Wrapper (`claw`)

`claw` is a shell wrapper that provides a unified interface for managing instances — both locally on the host and remotely via SSH. It auto-detects whether you are on the server or a remote machine and routes commands accordingly.

### Install

From the repo directory (works on any POSIX system):

```bash
ln -sf $(pwd)/claw ~/.local/bin/claw
```

Ensure `~/.local/bin` is in your `PATH`. The script resolves symlinks to find its `.env`, so the `.env` file must be alongside the real script.

### Usage

```
claw <instance> <command...>        Run a command on an instance
claw <instance> --shell             Drop into a shell inside the container
claw <instance> --logs [N]          Tail container logs (default 50)
claw list                           List all instances
claw help                           Show this help
```

### Examples

```bash
claw default devices list
claw default devices approve --latest
claw default config set gateway.bind loopback
claw research configure
claw default --shell
claw default --logs 100
```

### How it works

- **Remote**: wraps commands in `ssh -t <host> 'sudo -u <user> ...'` using values from `.env`
- **Local**: wraps commands in `sudo -u <user> ...` directly (detected via hostname match)
- Interactive commands (`configure`, `--shell`, etc.) automatically allocate a TTY
- Instance names are globally unique across variants — no need to specify which variant

## Architecture

```
<host>
├── Service user (nologin, rootless Podman with subuid/subgid)
├── Container (quadlet-managed, auto-restart)
│   ├── Gateway:  127.0.0.1:<port>  (loopback only)
│   ├── Bridge:   127.0.0.1:<port>  (loopback only)
│   └── Resources: configurable RAM + CPU limits
├── State: .<variant>/                  # e.g. .openclaw/, .picoclaw/
│   ├── <variant>.json          # Config
│   ├── .env                    # Gateway token
│   ├── agents/                 # Auth profiles, sessions
│   ├── credentials/            # Telegram pairing
│   └── sandboxes/              # Agent skills + identity
├── Workspace: workspace/
└── Backups: backups/           # Daily, 14-day retention
```

Default ports per variant:

| Variant   | Gateway | Bridge | Runtime |
|-----------|---------|--------|---------|
| openclaw  | 18789   | 18790  | Node.js |
| picoclaw  | 28789   | 28790  | Node.js |
| gclaw     | 38789   | 38790  | Node.js |
| tradeclaw | 48789   | 48790  | Go      |

## Variant Notes

### Tradeclaw (Go binary)

Tradeclaw is a Go binary, not a Node.js app. Key differences from Node.js variants:

- **Quadlet Exec line**: Use `Exec=gateway` (not `Exec=node dist/index.js gateway --bind lan --port <port>`). The ENTRYPOINT is `tradeclaw`, so this runs `tradeclaw gateway`.
- **Gateway port**: Set in config JSON (`gateway.port`) or via `TRADECLAW_GATEWAY_PORT` env var — no `--port` CLI flag.
- **OAuth login**: Requires `--userns=keep-id` so the container can write auth tokens to the mounted volume:

```bash
sudo -u tradeclaw -H bash -c "cd /data/tradeclaw && XDG_RUNTIME_DIR=/run/user/\$(id -u tradeclaw) \
  podman run --rm -it --userns=keep-id \
  -v /data/tradeclaw/.tradeclaw:/home/node/.tradeclaw \
  -e HOME=/home/node --user \$(id -u tradeclaw):\$(id -g tradeclaw) \
  localhost/tradeclaw:local auth login --provider openai"
```

Auth tokens are saved to the mounted volume (`/data/tradeclaw/.tradeclaw/`) and survive image rebuilds and container restarts.

### Podman < 4.4 (no Quadlet support)

Podman Quadlet requires version 4.4+. On older versions (e.g. Debian bookworm ships 4.3.1), create a systemd user service manually instead of running `05-deploy-quadlet.sh`:

```bash
# Create service directory
sudo -u <user> mkdir -p <home>/.config/systemd/user

# Write service file (example for tradeclaw)
cat > <home>/.config/systemd/user/<variant>.service << 'EOF'
[Unit]
Description=<variant> gateway (rootless Podman)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=/run/user/<uid>
EnvironmentFile=<home>/.<variant>/.env
ExecStartPre=-/usr/bin/podman rm -f <variant>
ExecStart=/usr/bin/podman run --rm --name <variant> \
  --userns=keep-id \
  -p 127.0.0.1:<gateway_port>:<gateway_port> \
  -p 127.0.0.1:<bridge_port>:<bridge_port> \
  -v <home>/.<variant>:/home/node/.<variant> \
  -v <home>/workspace:/home/node/.<variant>/workspace \
  --env-file <home>/.<variant>/.env \
  -e HOME=/home/node \
  -e TERM=xterm-256color \
  --dns 100.100.100.100 \
  --dns 1.1.1.1 \
  --memory=8g --cpus=4 \
  --user <uid>:<gid> \
  localhost/<variant>:local gateway
ExecStop=/usr/bin/podman stop -t 30 <variant>
Restart=on-failure
TimeoutStartSec=300

[Install]
WantedBy=default.target
EOF

# Enable and start
systemctl --machine <user>@ --user daemon-reload
systemctl --machine <user>@ --user enable --now <variant>.service
```

### Private repo access (deploy keys)

For private repos (e.g. tradeclaw), `03-clone-and-build.sh` needs git access. Set up an SSH deploy key:

```bash
# Generate key for the service user
sudo -u <user> -H ssh-keygen -t ed25519 -f <home>/.ssh/id_ed25519 -N "" -C "<user>@<host>"

# Add to GitHub as a deploy key
gh repo deploy-key add <home>/.ssh/id_ed25519.pub --repo <owner>/<repo> --title "<user>@<host>"

# Add GitHub to known_hosts
sudo -u <user> -H bash -c "ssh-keyscan github.com >> <home>/.ssh/known_hosts"

# Rewrite HTTPS to SSH for the service user
sudo -u <user> -H git config --global url."git@github.com:".insteadOf "https://github.com/"
```

### Container registry (unqualified image names)

If `podman build` fails with `short-name did not resolve to an alias`, add Docker Hub as a search registry:

```bash
cat >> /etc/containers/registries.conf << EOF
unqualified-search-registries = ["docker.io"]
EOF
```

## Security

| Control | Detail |
|---------|--------|
| Dedicated nologin user | No shell access, isolated home directory |
| Rootless Podman | User namespace isolation via subuid/subgid |
| Loopback-only ports | Host binds to 127.0.0.1, access via SSH tunnel only |
| Token auth | Gateway requires token for all connections |
| Exec denied | `tools.exec.security: "deny"` |
| Dangerous tools denied | `gateway`, `sessions_spawn`, `sessions_send` blocked |
| Sandbox off | Container itself is the isolation boundary |
| Filesystem restricted | `tools.fs.workspaceOnly: true` |
| mDNS off | `discovery.mdns.mode: "off"` |
| Log redaction | `logging.redactSensitive: "tools"` |

## Troubleshooting

<details>
<summary><b>subuid/subgid not configured</b></summary>

**Symptom**: `podman build` fails with `potentially insufficient UIDs or GIDs available in user namespace`.

**Fix**: Add non-overlapping range to `/etc/subuid` and `/etc/subgid`, then:
```bash
podman system reset --force
podman system migrate
```
The reset is critical — without it the UID mapping won't update.
</details>

<details>
<summary><b>Container can't read mounted config (permission denied)</b></summary>

**Symptom**: `Permission denied` on `/home/node/.<variant>/` inside container.

**Cause**: `--userns keep-id` with Dockerfile's `USER node` (UID 1000) doesn't match file ownership.

**Fix**: Add `--user <uid>:<gid>` to quadlet PodmanArgs to match the service user's UID/GID.
</details>

<details>
<summary><b>Gateway unreachable (connection reset)</b></summary>

**Symptom**: `curl http://127.0.0.1:<port>/` returns connection reset.

**Cause**: Podman pasta networking forwards via non-loopback `169.254.1.2`. Gateway bound to loopback rejects it.

**Fix**: Use `--bind lan` in the Exec command (container listens on all interfaces). Enforce loopback at the host level with `PublishPort=127.0.0.1:<port>:<port>`.
</details>

<details>
<summary><b>CLI error: "plaintext ws:// to non-loopback"</b></summary>

**Cause**: `gateway.bind` in config controls both the listener AND the CLI connection URL. With `"lan"`, CLI resolves the LAN IP which fails the security check.

**Fix**: Set `gateway.bind: "loopback"` in config. The quadlet Exec flag (`--bind lan`) independently controls the actual listener.
</details>

<details>
<summary><b>Cron/device pairing errors</b></summary>

Internal tools (cron, etc.) are treated as separate "devices" needing one-time pairing:
```bash
podman exec <container> <variant-cli> devices approve --latest
```

Also ensure `cron` is not in the `tools.deny` array in config.
</details>

<details>
<summary><b>Docker EACCES in agent sandbox</b></summary>

**Cause**: `sandbox.mode: "all"` tries to spawn Docker containers inside Podman. Docker isn't available.

**Fix**: `<variant-cli> config set agents.defaults.sandbox.mode off` — the Podman container is the sandbox.
</details>
