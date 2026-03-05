# Config

`claw-defaults.json` is a **reference config** showing the security-hardened defaults
used across all claw variants (openclaw, picoclaw, tradeclaw).

This file is not used at runtime. The deployment script `scripts/04-configure.sh`
generates the actual runtime config in the instance's state directory
(e.g., `<CLAW_HOME>/.<variant>/<variant>.json`).
