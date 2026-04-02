# SmartHome Genesis

A single-command installer that deploys a full smart-home stack on any Ubuntu server. An interactive setup wizard collects your preferences, then an Ansible playbook provisions Docker, networking, and every service — ready to use in minutes.

Post-install, the included `backup.sh` and `restore-standalone.sh` scripts handle day-to-day operations: automated backups to Git, config sync, DAG-ordered service boot, circuit-breaker watchdog, and emergency rollback.

## Stack

| Service | Port | Description |
|---|---|---|
| [Home Assistant](https://www.home-assistant.io/) | `8123` | Central automation hub |
| [Zigbee2MQTT](https://www.zigbee2mqtt.io/) | `8080` | Zigbee device gateway (token-protected) |
| [Node-RED](https://nodered.org/) | `1880` | Visual automation flows (password-protected) |
| [Eclipse Mosquitto](https://mosquitto.org/) | `1883` | MQTT message broker (password auth) |

### Optional Networking

| Service | Purpose |
|---|---|
| [Tailscale](https://tailscale.com/) | Zero-config VPN for remote access |
| [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) | Expose Home Assistant to the web without port-forwarding |

## Prerequisites

- **OS:** Ubuntu 20.04+ (amd64)
- **Access:** Root / sudo
- **Hardware:** Zigbee USB coordinator (e.g. Sonoff ZBDongle-P) — auto-detected at `/dev/ttyUSB*` or `/dev/ttyACM*`
- **Optional:** Tailscale auth key and/or Cloudflare Tunnel token

## Quick Start

```bash
git clone <repo-url> && cd SmartHomeInstaller
cp .env.example .env
nano .env              # fill in your secrets (or leave blank for interactive prompts)
sudo ./setup.sh
```

### Using `.env` (recommended)

Copy `.env.example` to `.env` and fill in your values. Any variable set in `.env` will skip the corresponding interactive prompt during setup:

| Variable | Required | Description |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | No | Telegram bot token for watchdog alerts |
| `TELEGRAM_CHAT_ID` | No | Telegram chat ID for notifications |
| `TAILSCALE_KEY` | No | Auth key for Tailscale VPN |
| `CF_TOKEN` | No | Cloudflare Tunnel install token |
| `HA_TIMEZONE` | Yes | e.g. `Asia/Jerusalem` |
| `HA_LATITUDE` | Yes | e.g. `31.2529` |
| `HA_LONGITUDE` | Yes | e.g. `34.7914` |
| `HA_ELEVATION` | Yes | e.g. `260` |
| `MQTT_PASSWORD` | No | Auto-generated (32-char hex) if left blank |

### Interactive mode

If `.env` doesn't exist or a value is blank, `setup.sh` will prompt for it interactively:

1. **Tailscale VPN** — paste an auth key or press Enter to skip
2. **Cloudflare Tunnel** — paste a tunnel token or press Enter to skip
3. **Location data** — timezone, latitude, longitude, and elevation for sun/weather automations

At the end, the installer prints all generated credentials — save them in a password manager.

## What the Installer Does

1. Installs system dependencies (including Ansible and OpenSSL)
2. Adds the Docker CE repository, installs Docker + Compose plugin, and enables the service
3. Installs and authenticates Tailscale (if a key was provided)
4. Installs and enables Cloudflare Tunnel (if a token was provided)
5. Auto-detects the Zigbee USB coordinator
6. Scaffolds the `~/SmartHome` directory tree
7. Generates all configuration files (Home Assistant, Mosquitto, Zigbee2MQTT, Node-RED)
8. Creates a strong random password and configures password-based auth for MQTT, Node-RED, and Zigbee2MQTT
9. Starts the full Docker Compose stack
10. Initialises a Git repository for config version tracking
11. Registers a nightly backup cron job (runs at 02:00)

## Default Credentials

All services share a single auto-generated 32-character password, displayed once at the end of setup:

| Service | Username | Password |
|---|---|---|
| MQTT (Mosquitto) | `smarthome` | *(auto-generated)* |
| Node-RED | `admin` | *(auto-generated)* |
| Zigbee2MQTT UI | *(token auth)* | *(auto-generated)* |

## Directory Layout

After installation, `~/SmartHome` will look like this:

```
~/SmartHome/
├── ha-stack/
│   └── docker-compose.yaml
├── homeassistant/
│   ├── configuration.yaml
│   ├── secrets.yaml
│   ├── automations.yaml
│   ├── scripts.yaml
│   ├── scenes.yaml
│   └── groups.yaml
├── mosquitto/
│   ├── config/
│   │   ├── mosquitto.conf
│   │   ├── passwd
│   │   └── mqtt_password
│   ├── data/
│   └── log/
├── zigbee2mqtt/
│   └── configuration.yaml
├── nodered/
│   └── settings.js
├── scripts/
├── system/
├── backup.sh
├── restore-standalone.sh
├── .env
├── backup.log
└── .gitignore
```

## Backups

A nightly cron job at **02:00** runs `backup.sh`, which:

- Pulls latest changes from remote (`git pull --rebase`) to prevent divergent branches
- Copies all config files (Home Assistant, Mosquitto, Zigbee2MQTT, Node-RED, system configs) into the Git repo
- Commits and pushes changes to the remote repository
- Handles push failures gracefully (commits locally, warns instead of crashing)

## Restore & Operations

`restore-standalone.sh` is a self-contained operations tool that works without Ansible. Run it with `sudo ./restore-standalone.sh` (or `--dry-run` to simulate).

| Feature | Description |
|---|---|
| **Safe Points** | Creates compressed snapshots of all configs before risky operations |
| **DAG Boot** | Starts services in dependency order: mosquitto → zigbee2mqtt + nodered → homeassistant |
| **Zigbee Network** | Automatically creates the Docker `zigbee` network if missing |
| **Atomic Sync** | Syncs individual app configs with pre-flight snapshots and automatic rollback on failure |
| **Git Pull** | Pulls latest repo with `--rebase`, auto-resets on failure |
| **Watchdog** | Circuit-breaker loop: monitors services, restarts on failure, trips after 3 consecutive failures |
| **Telegram Alerts** | Sends notifications on circuit trip, recovery, and sync failure (requires `.env`) |
| **Emergency Rollback** | Restores from the latest safe point and reboots the full stack |
| **Infrastructure** | Reconciles Docker and Tailscale installations |
| **Dry-Run Mode** | Simulates all operations without making changes |

## Security Notes

- All secrets (Telegram tokens, Tailscale keys, Cloudflare tokens) are loaded from `.env` — never hardcoded
- `.env` is excluded from Git via `.gitignore`
- **MQTT broker** uses password authentication — anonymous access is disabled
- **Node-RED** is protected with bcrypt-hashed admin credentials (`adminAuth`)
- **Zigbee2MQTT** frontend requires a token to access
- MQTT password is auto-generated (32-character hex) and the Ansible vars file is deleted on exit
- Tailscale and Cloudflare tokens are passed via environment variables, never visible in process listings
- Sensitive config files (`zigbee2mqtt/configuration.yaml`, `nodered/settings.js`, `mosquitto/config/passwd`, `mosquitto/config/mqtt_password`) are excluded from Git via `.gitignore`
- `secrets.yaml` is restricted to owner-only read (`0600`)

## Files

| File | Purpose |
|---|---|
| `setup.sh` | Interactive bootstrapper — installs Ansible, reads `.env`, interviews the user, launches the playbook |
| `deploy.yml` | Ansible playbook — provisions the entire stack end-to-end |
| `backup.sh` | Production backup script — syncs all configs to Git and pushes |
| `restore-standalone.sh` | Operations tool — safe points, DAG boot, watchdog, rollback, app sync, Telegram alerts |
| `.env.example` | Template for secrets and configuration — copy to `.env` and fill in |
| `.gitignore` | Prevents `.env` and other sensitive files from being committed |

## Troubleshooting

**Zigbee device not found:**
Make sure the USB coordinator is plugged in before running setup. Verify with `ls /dev/ttyUSB* /dev/ttyACM*`.

**Docker permission denied:**
Log out and back in after installation so the Docker group membership takes effect, or run `newgrp docker`.

**Services not starting:**
Check container logs with `docker compose -f ~/SmartHome/ha-stack/docker-compose.yaml logs`.

**Node-RED login not working:**
The password is bcrypt-hashed in `~/SmartHome/nodered/settings.js`. If you lost the password, re-run `setup.sh` to regenerate.

**Telegram alerts not working:**
Make sure `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are set in `~/SmartHome/.env`.

**Divergent branches on backup:**
`backup.sh` runs `git pull --rebase` before committing. If it still fails, manually resolve with `cd ~/SmartHome && git pull --rebase origin main`.

## License

This project is provided as-is for personal use.
