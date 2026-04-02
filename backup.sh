#!/bin/bash
set -euo pipefail

# ============================================================
#  SmartHome Backup
#  Copies all config files to ~/SmartHome git repo and pushes
# ============================================================

SRC="/home/ek"
REPO="${SRC}/SmartHome"
BRANCH="main"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "FATAL: $*" >&2; exit 1; }

[ -d "${REPO}/.git" ] || die "Git repo not found at ${REPO}"

cd "$REPO"

# ---- Helpers ----
cpf() {
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    [ -e "$src" ] || return 0
    if [ -r "$src" ]; then
        cp -f "$src" "$dst"
    else
        sudo cp -f "$src" "$dst"
        sudo chown ek:ek "$dst"
    fi
}

syncdir() {
    local src="$1" dst="$2"
    shift 2
    mkdir -p "$dst"
    local args=(-a --delete)
    for exc in "$@"; do args+=(--exclude="$exc"); done
    if [ -r "$src" ]; then
        rsync "${args[@]}" "$src" "$dst"
    else
        sudo rsync "${args[@]}" "$src" "$dst"
        sudo chown -R ek:ek "$dst"
    fi
}

log "=== Starting backup ==="

# Clean out old backup folders to prevent dead files from accumulating
log "Cleaning old backup directories..."
rm -rf ha-stack dockge homeassistant homeassistant-config-old mosquitto nodered zigbee2mqtt cloudflared system scripts

# ==================== DOCKER COMPOSE ====================
log "Docker Compose..."
cpf "${SRC}/ha-stack/docker-compose.yaml"         "ha-stack/docker-compose.yaml"
cpf "${SRC}/ha-stack/dockge/docker-compose.yaml"  "ha-stack/dockge-docker-compose.yaml"

# ==================== DOCKGE ====================
log "Dockge..."
cpf "${SRC}/dockge/data/db-config.json"           "dockge/db-config.json"

# ==================== HOME ASSISTANT ====================
log "Home Assistant..."
for f in .HA_VERSION configuration.yaml automations.yaml scripts.yaml \
         scenes.yaml template.yaml HASC.sh secrets.yaml \
         google_service_account.json; do
    cpf "${SRC}/homeassistant/${f}" "homeassistant/${f}"
done

syncdir "${SRC}/homeassistant/blueprints/"        "homeassistant/blueprints/"
syncdir "${SRC}/homeassistant/themes/"            "homeassistant/themes/" "*.yamlx"
syncdir "${SRC}/homeassistant/custom_components/" "homeassistant/custom_components/" \
    "__pycache__" "hacs_frontend" "*.pyc"

# ==================== HA CONFIG (old backup) ====================
log "Home Assistant config subfolder..."
cpf "${SRC}/homeassistant/config/configuration.yaml"  "homeassistant-config-old/configuration.yaml"
cpf "${SRC}/homeassistant/config/secrets.yaml"        "homeassistant-config-old/secrets.yaml"
cpf "${SRC}/homeassistant/config/google-stt-key.json" "homeassistant-config-old/google-stt-key.json"
for f in "${SRC}/homeassistant/config/client_secret_"*.json; do
    [ -f "$f" ] && cpf "$f" "homeassistant-config-old/$(basename "$f")"
done

# ==================== MOSQUITTO ====================
log "Mosquitto..."
cpf "${SRC}/mosquitto/config/mosquitto.conf"      "mosquitto/config/mosquitto.conf"

# ==================== NODE-RED ====================
log "Node-RED..."
for f in flows.json flows_cred.json settings.js package.json \
         node-red-contrib-home-assistant-websocket.json; do
    cpf "${SRC}/nodered/data/${f}" "nodered/data/${f}"
done

# ==================== ZIGBEE2MQTT ====================
log "Zigbee2MQTT..."
cpf "${SRC}/zigbee2mqtt/data/configuration.yaml"       "zigbee2mqtt/data/configuration.yaml"
cpf "${SRC}/zigbee2mqtt/data/coordinator_backup.json"  "zigbee2mqtt/data/coordinator_backup.json"

# ==================== CLOUDFLARED ====================
log "Cloudflared..."
cpf "${SRC}/.cloudflared/config.yml"              "cloudflared/config.yml"

# ==================== SCRIPTS ====================
log "Scripts..."
cpf "${SRC}/update-ip.sh"                         "scripts/update-ip.sh"

# ==================== SYSTEM CONFIG ====================
log "System config..."
mkdir -p system

# Systemd services
sudo cp -f /etc/systemd/system/cloudflared.service          system/cloudflared.service 2>/dev/null || true
sudo cp -f /etc/systemd/system/glances.service              system/glances.service 2>/dev/null || true
sudo cp -f /etc/systemd/system/tailscale-funnels.service    system/tailscale-funnels.service 2>/dev/null || true
sudo chown ek:ek system/*.service 2>/dev/null || true

# Netplan (WiFi config)
sudo cp -f /etc/netplan/50-cloud-init.yaml  system/50-cloud-init.yaml 2>/dev/null || true
sudo chown ek:ek system/50-cloud-init.yaml 2>/dev/null || true

# Crontab
crontab -l > system/crontab.bak 2>/dev/null || echo "# empty" > system/crontab.bak

# SSH config (not keys — just the config file)
cpf "${SRC}/.ssh/config" "system/ssh-config"

# ==================== GIT COMMIT & PUSH ====================
log "Committing..."
git pull --rebase origin "$BRANCH" 2>/dev/null || log "WARNING: Pull failed. Continuing with local commit."
git add -A
if git diff --cached --quiet; then
    log "No changes — nothing to push."
else
    CHANGED="$(git diff --cached --stat | tail -1)"
    git commit -m "backup $(date '+%Y-%m-%d %H:%M') — ${CHANGED}"
    git push origin "$BRANCH" || log "WARNING: Push failed. Changes committed locally but not pushed."
fi

log "=== Backup complete ==="
