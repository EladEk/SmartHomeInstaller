# SmartHome Genesis

A single-command installer that deploys a full smart-home stack on any Ubuntu server. An interactive setup wizard collects your preferences, then an Ansible playbook provisions Docker, networking, and every service — ready to use in minutes.

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
sudo ./setup.sh
```

The setup wizard will walk you through:

1. **Tailscale VPN** — paste an auth key or press Enter to skip
2. **Cloudflare Tunnel** — paste a tunnel token or press Enter to skip
3. **Location data** — timezone, latitude, longitude, and elevation for sun/weather automations

Once the interview is complete, Ansible takes over and handles everything else automatically.

At the end, the installer prints all generated credentials — save them in a password manager.

## What the Installer Does

1. Installs system dependencies (including Ansible and OpenSSL)
2. Adds the Docker CE repository, installs Docker + Compose plugin, and enables the service
3. Installs and authenticates Tailscale (if a key was provided)
4. Installs and enables Cloudflare Tunnel (if a token was provided)
5. Auto-detects the Zigbee USB coordinator
6. Scaffolds the `~/SmartHome` directory tree
7. Generates all configuration files (Home Assistant, Mosquitto, Zigbee2MQTT)
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
├── backup.log
└── .gitignore
```

## Backups

A nightly cron job at **02:00** runs `backup.sh`, which:

- Copies Home Assistant config (excluding database files) to `~/smarthome-backups/<date>/`
- Copies Zigbee2MQTT config (excluding logs)
- Commits all changes to the local Git repository
- Prunes backups older than 30 days

## Security Notes

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
| `setup.sh` | Interactive bootstrapper — installs Ansible, interviews the user, launches the playbook |
| `deploy.yml` | Ansible playbook — provisions the entire stack end-to-end |

## Troubleshooting

**Zigbee device not found:**
Make sure the USB coordinator is plugged in before running setup. Verify with `ls /dev/ttyUSB* /dev/ttyACM*`.

**Docker permission denied:**
Log out and back in after installation so the Docker group membership takes effect, or run `newgrp docker`.

**Services not starting:**
Check container logs with `docker compose -f ~/SmartHome/ha-stack/docker-compose.yaml logs`.

**Node-RED login not working:**
The password is bcrypt-hashed in `~/SmartHome/nodered/settings.js`. If you lost the password, re-run `setup.sh` to regenerate.

## License

This project is provided as-is for personal use.
