#!/bin/bash
# ============================================================
#  SmartHome OS - HYBRID BOOTSTRAPPER
#  Purpose: Interview User -> Install Ansible -> Execute Playbook
# ============================================================
set -euo pipefail

# Must run as root
[ "$(id -u)" -eq 0 ] || { echo "❌ Please run as sudo: sudo ./setup.sh"; exit 1; }

TARGET_USER="${SUDO_USER:-$USER}"
VARS_FILE="/tmp/smarthome_vars.yml"

# Resolve the script's own directory so ansible-playbook works regardless
# of where the user cd'd before running sudo ./setup.sh
SCRIPT_DIR=$(dirname "$(realpath "$0")")

# ✅ FIX #1: Always clean up secrets file on exit, even if script fails
trap 'rm -f "$VARS_FILE"' EXIT

echo "==========================================================="
echo "   Initiating SmartHome Genesis Sequence"
echo "==========================================================="
echo "Target User: $TARGET_USER"

# --- 1. Install Ansible (Prerequisite) ---
echo -e "\n>>> Installing Ansible Engine..."
apt-get update -yqq
apt-get install -yqq software-properties-common ansible curl git openssl

# --- Validation Helpers ---
# ✅ FIX #2: Validate numeric inputs before proceeding
validate_float() {
  local value="$1"
  local label="$2"
  if [[ ! "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    echo "❌ Invalid value for $label: '$value'. Must be a number (e.g. 31.25)"
    exit 1
  fi
}

validate_int() {
  local value="$1"
  local label="$2"
  if [[ ! "$value" =~ ^-?[0-9]+$ ]]; then
    echo "❌ Invalid value for $label: '$value'. Must be an integer (e.g. 260)"
    exit 1
  fi
}

# --- 2. The Interview ---
echo ""
echo "==========================================================="
echo "   STEP 1: TAILSCALE VPN AUTHENTICATION"
echo "==========================================================="
echo "Tailscale securely connects your phone to the server."
echo "1. Go to: https://login.tailscale.com/admin/settings/keys"
echo "2. Click 'Generate auth key' (Reusable, Ephemeral = OFF)"
read -rp "Paste Auth Key (or press enter to skip): " TS_KEY

echo -e "\n==========================================================="
echo "   STEP 2: CLOUDFLARE TUNNEL"
echo "==========================================================="
echo "Cloudflare exposes Home Assistant securely to the web."
echo "1. Go to Zero Trust Dashboard -> Networks -> Tunnels"
echo "2. Create a tunnel, copy the token from the install command."
read -rp "Paste Tunnel Token (or press enter to skip): " CF_TOKEN

echo -e "\n==========================================================="
echo "   STEP 3: HOME ASSISTANT LOCATION DATA"
echo "==========================================================="
echo "Home Assistant needs your exact coordinates for sun/weather automations."
echo "You can find these at https://www.latlong.net/"

read -rp "Enter Timezone (e.g., Asia/Jerusalem): " HA_TZ
if [[ -z "$HA_TZ" ]]; then
  echo "❌ Timezone cannot be empty."
  exit 1
fi

read -rp "Enter Latitude (e.g., 31.2529): " HA_LAT
validate_float "$HA_LAT" "Latitude"

read -rp "Enter Longitude (e.g., 34.7914): " HA_LON
validate_float "$HA_LON" "Longitude"

read -rp "Enter Elevation in meters (e.g., 260): " HA_ELEV
validate_int "$HA_ELEV" "Elevation"

# --- 3. Auto-Generate MQTT Password ---
# Never trust the user to change a default — generate a strong password automatically.
# hex output is purely alphanumeric with no +/= symbols, so no stripping needed.
# 'openssl rand -hex 16' always produces exactly 32 characters.
MQTT_PASSWORD="$(openssl rand -hex 16)"

# --- 4. Generate Ansible Variables File ---
echo ">>> Securing variables..."
cat <<'HEREDOC_END' > "$VARS_FILE"
target_user: "PLACEHOLDER_USER"
tailscale_key: 'PLACEHOLDER_TS'
cf_token: 'PLACEHOLDER_CF'
ha_tz: 'PLACEHOLDER_TZ'
ha_lat: "PLACEHOLDER_LAT"
ha_lon: "PLACEHOLDER_LON"
ha_elev: "PLACEHOLDER_ELEV"
mqtt_password: "PLACEHOLDER_MQTT"
HEREDOC_END
sed -i \
  -e "s|PLACEHOLDER_USER|$TARGET_USER|" \
  -e "s|PLACEHOLDER_TS|$TS_KEY|" \
  -e "s|PLACEHOLDER_CF|$CF_TOKEN|" \
  -e "s|PLACEHOLDER_TZ|$HA_TZ|" \
  -e "s|PLACEHOLDER_LAT|$HA_LAT|" \
  -e "s|PLACEHOLDER_LON|$HA_LON|" \
  -e "s|PLACEHOLDER_ELEV|$HA_ELEV|" \
  -e "s|PLACEHOLDER_MQTT|$MQTT_PASSWORD|" \
  "$VARS_FILE"
chmod 600 "$VARS_FILE"

# --- 5. Hand off to Ansible ---
echo -e "\n>>> Interview Complete. Handing control to Ansible...\n"

# ✅ FIX #3: Fixed broken line continuation (-c loca\nl -> -c local)
ansible-playbook "$SCRIPT_DIR/deploy.yml" -e @"$VARS_FILE" -i "localhost," -c local

echo -e "\n✅ SmartHome Genesis Complete!"
echo "   - Home Assistant : http://localhost:8123"
echo "   - Zigbee2MQTT UI : http://localhost:8080"
echo "   - Node-RED       : http://localhost:1880"
echo ""
echo "==========================================================="
echo "   🔐 SAVE THESE CREDENTIALS"
echo "==========================================================="
echo "   MQTT Username   : smarthome"
echo "   MQTT Password   : $MQTT_PASSWORD"
echo ""
echo "   Node-RED Login  : admin / $MQTT_PASSWORD"
echo "   Zigbee2MQTT UI  : token = $MQTT_PASSWORD"
echo ""
echo "   These are already configured in your stack."
echo "   Store them in a password manager — they will not be shown again."
echo "==========================================================="
