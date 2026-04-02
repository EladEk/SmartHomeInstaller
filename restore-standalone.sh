#!/bin/bash
# ============================================================
#  SmartHome OS - Standalone Restore (v22.1)
#  Bare-metal fallback when Ansible is not available.
#  For day-to-day use, prefer: sudo ./oracle.sh
# ============================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="/home/ek"
TARGET_USER="ek"
LOG_FILE="/var/log/smarthome-os.log"
EVENT_LOG="/var/lib/smarthome_events.jsonl"
BREAKER_STATE="/var/lib/smarthome_breakers.json"
METRICS_FILE="/var/lib/smarthome_metrics.prom"
BACKUP_DIR="${HOME_DIR}/backups/atomic"
RESTORE_POINT_DIR="${HOME_DIR}/backups/safe_points"
LOCK_FILE="/run/lock/smarthome_os.lock"
COMPOSE_FILE="${HOME_DIR}/ha-stack/docker-compose.yaml"

# ---- Load secrets from .env ----
ENV_FILE="${REPO}/.env"
[ -f "$ENV_FILE" ] && set -a && . "$ENV_FILE" && set +a
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# ---- Global Dry-Run Flag ----
DRY_RUN=${DRY_RUN:-0}
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# ---- 1. Pre-Flight & Lock ----
if [ -f "$LOCK_FILE" ] && kill -0 "$(cat "$LOCK_FILE" 2>/dev/null)" 2>/dev/null; then
    echo "FATAL: Control Loop already active." >&2; exit 1
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"; exit' INT TERM EXIT

retry() {
    local max=$1; shift; local n=1
    while ! "$@"; do [ $n -ge $max ] && return 1; sleep $((n * 2)); ((n++)); done
    return 0
}

# ---- 2. Event Log & Housekeeping ----
[ -f "$EVENT_LOG" ] || touch "$EVENT_LOG"
[ -f "$BREAKER_STATE" ] || echo "{}" > "$BREAKER_STATE"

rotate_logs() {
    if [ "$(wc -l < "$EVENT_LOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
        tail -n 1000 "$EVENT_LOG" > "$EVENT_LOG.tmp" && mv "$EVENT_LOG.tmp" "$EVENT_LOG"
    fi
    find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +14 -delete 2>/dev/null || true
}

emit_event() {
    local comp=$1 state=$2 msg=${3:-""} ts=$(date +%s)
    jq -n -c --arg c "$comp" --arg s "$state" --arg m "$msg" --arg t "$ts" \
       '{component: $c, state: $s, msg: $m, timestamp: $t}' >> "$EVENT_LOG"
    echo -e "[$(date '+%H:%M:%S')] [$comp] -> $state ${msg:+( $msg )}" | tee -a "$LOG_FILE"
}

notify_telegram() {
    local msg="$1"
    [ -z "${TELEGRAM_BOT_TOKEN:-}" ] && return 0
    curl -sf -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${msg}" \
        >/dev/null 2>&1 || true
}

export_metrics() {
    local tmp_metrics="/tmp/smarthome.prom"
    echo "# HELP smarthome_os_uptime OS Control Loop Uptime" > "$tmp_metrics"
    echo "smarthome_os_uptime $(date +%s)" >> "$tmp_metrics"
    for c in "mosquitto" "zigbee2mqtt" "nodered" "homeassistant"; do
        local is_up=0
        docker ps --format '{{.Names}}' | grep -q "^${c}$" && is_up=1
        echo "smarthome_service_status{service=\"$c\"} $is_up" >> "$tmp_metrics"
    done
    mv "$tmp_metrics" "$METRICS_FILE" 2>/dev/null || true
}

# ==================== THE PROTECTION LAYER ====================

create_safe_point() {
    if [ "$DRY_RUN" -eq 1 ]; then
        emit_event "PROTECTION" "DRY_RUN" "Would create a global tar.gz snapshot of all configs."
        return 0
    fi

    emit_event "PROTECTION" "BACKUP_START" "Creating global restore point..."
    mkdir -p "$RESTORE_POINT_DIR"
    local snap_name="safe_point_$(date +%Y%m%d_%H%M%S).tar.gz"
    local snap_path="${RESTORE_POINT_DIR}/${snap_name}"

    docker compose -f "$COMPOSE_FILE" stop 2>/dev/null || true
    tar -czf "$snap_path" -C "$HOME_DIR" homeassistant mosquitto zigbee2mqtt nodered 2>/dev/null || true
    ls -tp "$RESTORE_POINT_DIR"/*.tar.gz 2>/dev/null | grep -v '/$' | tail -n +6 | xargs -I {} rm -- {} 2>/dev/null || true
    emit_event "PROTECTION" "BACKUP_DONE" "Safe point secured: $snap_name"
}

emergency_rollback() {
    echo -e "\n=== EMERGENCY ROLLBACK PROCEDURE ==="
    local latest_snap=$(ls -tp "$RESTORE_POINT_DIR"/*.tar.gz 2>/dev/null | grep -v '/$' | head -n 1)
    
    if [ -z "$latest_snap" ]; then echo "❌ FATAL: No restore points found."; return 1; fi
    echo "Found Safe Point: $(basename "$latest_snap")"
    
    if [ "$DRY_RUN" -eq 1 ]; then
        emit_event "PROTECTION" "DRY_RUN" "Would extract $(basename "$latest_snap") and reboot DAG."
        return 0
    fi

    read -rp "⚠️ WARNING: This will REWIND time. Proceed? (y/N): " c
    if [[ "$c" =~ ^[Yy]$ ]]; then
        emit_event "PROTECTION" "ROLLBACK_EXEC" "Overwriting current system state"
        docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
        tar -xzf "$latest_snap" -C "$HOME_DIR"
        emit_event "PROTECTION" "ROLLBACK_DONE" "System successfully rewound"
        boot_dag
    else
        echo "Aborted."
    fi
}

probe_health() {
    local s=$1
    local state=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$s" 2>/dev/null || echo "missing")
    case "$state" in "healthy"|"running") return 0 ;; *) return 1 ;; esac
}

# ==================== CORE TRANSACTIONS ====================

atomic_sync() {
    local app=$1 src=$2 dst=$3 container=${4:-""}
    
    if [ -n "$container" ] && probe_health "$container"; then
        echo -e "\n🟢 $app is currently HEALTHY and RUNNING."
        read -rp "⚠️ Overwrite config and restart container? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            emit_event "SYNC_$app" "SKIPPED" "User skipped healthy app"
            return 0
        fi
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "\n  🛠️  [DRY-RUN] Would take a .tar.gz snapshot of $dst"
        echo -e "  🛠️  [DRY-RUN] Would rsync $src -> $dst"
        [ -n "$container" ] && echo -e "  🛠️  [DRY-RUN] Would restart Docker container: $container"
        return 0
    fi

    local snap="${BACKUP_DIR}/${app}_$(date +%s).tar.gz"
    mkdir -p "$BACKUP_DIR" "$dst"
    emit_event "SYNC_$app" "SNAPSHOT" "Pre-flight snapshot"
    tar -czf "$snap" -C "$dst" . 2>/dev/null || true

    if retry 3 rsync -av --delete "$src" "$dst" >/dev/null 2>&1; then
        chown -R "$TARGET_USER:$TARGET_USER" "$dst"
        emit_event "SYNC_$app" "COMMITTED"
        if [ -n "$container" ]; then
            docker compose -f "$COMPOSE_FILE" restart "$container" 2>/dev/null || true
        fi
    else
        emit_event "SYNC_$app" "FAILED" "Rolling back"
        notify_telegram "SYNC FAILED: $app - rolling back to snapshot"
        tar -xzf "$snap" -C "$dst"
        return 1
    fi
}

atomic_file_sync() {
    local comp=$1 src=$2 dst=$3
    
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then 
        echo -e "\n🟢 $comp config is already IDENTICAL."
        read -rp "⚠️ Force overwrite anyway? (y/N): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && { emit_event "SYNC_$comp" "SKIPPED" "Files identical"; return 0; }
    fi
    
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "\n  🛠️  [DRY-RUN] Would backup $dst to ${dst}.bak"
        echo -e "  🛠️  [DRY-RUN] Would copy $src -> $dst"
        return 0
    fi

    mkdir -p "$(dirname "$dst")"
    cp -p "$dst" "${dst}.bak" 2>/dev/null || true
    if cp -p "$src" "$dst"; then
        emit_event "SYNC_$comp" "COMMITTED" "File updated"
    else
        mv "${dst}.bak" "$dst" 2>/dev/null || true
        emit_event "SYNC_$comp" "FAILED" "File rollback"
    fi
}

safe_git_pull() {
    emit_event "GIT" "PULLING" "Syncing from remote"
    
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "\n  🛠️  [DRY-RUN] Would execute: git fetch origin main && git diff HEAD origin/main"
        git -C "$REPO" fetch origin main 2>/dev/null || true
        git -C "$REPO" --no-pager diff --stat HEAD origin/main || echo "No changes or offline."
        return 0
    fi

    local current_hash=$(git -C "$REPO" rev-parse HEAD)
    if ! retry 3 git -C "$REPO" pull --rebase origin main; then
        emit_event "GIT" "FAILED" "Reverting to $current_hash"
        git -C "$REPO" reset --hard "$current_hash"
        return 1
    fi
    emit_event "GIT" "SYNCED" "Repo updated"
}

# ==================== DAG ENGINE ====================

declare -A DAG_DEPS=( ["mosquitto"]="" ["zigbee2mqtt"]="mosquitto" ["nodered"]="mosquitto" ["homeassistant"]="mosquitto zigbee2mqtt" )
declare -A DAG_PORTS=( ["mosquitto"]="1883" ["zigbee2mqtt"]="8080" ["nodered"]="1880" ["homeassistant"]="8123" )

check_deps() {
    local svc=$1
    for dep in ${DAG_DEPS[$svc]}; do nc -z localhost "${DAG_PORTS[$dep]}" >/dev/null 2>&1 || return 1; done
    return 0
}

boot_dag() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "\n  🛠️  [DRY-RUN] Would boot DAG: mosquitto -> zigbee2mqtt -> nodered -> homeassistant"
        return 0
    fi

    docker network inspect zigbee >/dev/null 2>&1 || docker network create zigbee
    emit_event "DAG" "BOOT_START" "Resolving dependency graph"
    local PENDING=("mosquitto" "zigbee2mqtt" "nodered" "homeassistant")
    local max_loops=10; local loop=0

    while [ ${#PENDING[@]} -gt 0 ] && [ $loop -lt $max_loops ]; do
        local NEXT_PENDING=()
        for svc in "${PENDING[@]}"; do
            if check_deps "$svc"; then
                emit_event "DAG" "STARTING" "Dependencies met for $svc"
                docker compose -f "$COMPOSE_FILE" up -d "$svc"
                retry 10 nc -z localhost "${DAG_PORTS[$svc]}" >/dev/null 2>&1 || emit_event "DAG" "WARN" "$svc slow to bind port"
            else
                NEXT_PENDING+=("$svc")
            fi
        done
        PENDING=("${NEXT_PENDING[@]+"${NEXT_PENDING[@]}"}")
        [ ${#PENDING[@]} -eq 0 ] && break
        ((loop++)); sleep 2
    done
    [ ${#PENDING[@]} -eq 0 ] && emit_event "DAG" "BOOT_COMPLETE" "Graph resolved" || emit_event "DAG" "STALLED" "Unresolved deps"
}

# ==================== WATCHDOG ====================

run_watchdog() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "\n  🛠️  [DRY-RUN] Would start infinite circuit-breaker watchdog loop in background."
        return 0
    fi

    emit_event "WATCHDOG" "STARTED" "Persistent loop engaged"
    local COOLDOWN=300

    while true; do
        rotate_logs; export_metrics; local now=$(date +%s)
        
        for c in "mosquitto" "zigbee2mqtt" "nodered" "homeassistant"; do
            local state=$(jq -r ".\"$c\".state // \"OK\"" "$BREAKER_STATE")
            local last_trip=$(jq -r ".\"$c\".last_trip // 0" "$BREAKER_STATE")
            local fail_count=$(jq -r ".\"$c\".fails // 0" "$BREAKER_STATE")

            if probe_health "$c"; then
                [ "$state" != "OK" ] && emit_event "SVC_$c" "RECOVERED" && jq ".\"$c\" = {\"state\":\"OK\", \"fails\":0, \"last_trip\":0}" "$BREAKER_STATE" > "$BREAKER_STATE.tmp" && mv "$BREAKER_STATE.tmp" "$BREAKER_STATE"
                continue
            fi

            if [ "$state" == "TRIPPED" ]; then
                if [ $((now - last_trip)) -ge $COOLDOWN ]; then
                    emit_event "SVC_$c" "HALF_OPEN" "Auto-probing..."
                    jq ".\"$c\".state = \"HALF_OPEN\"" "$BREAKER_STATE" > "$BREAKER_STATE.tmp" && mv "$BREAKER_STATE.tmp" "$BREAKER_STATE"
                    docker compose -f "$COMPOSE_FILE" up -d "$c"
                fi
            elif [ "$state" == "HALF_OPEN" ]; then
                emit_event "SVC_$c" "TRIPPED" "Probe failed."
                jq ".\"$c\" = {\"state\":\"TRIPPED\", \"fails\":3, \"last_trip\":$now}" "$BREAKER_STATE" > "$BREAKER_STATE.tmp" && mv "$BREAKER_STATE.tmp" "$BREAKER_STATE"
            else
                fail_count=$((fail_count + 1))
                if [ $fail_count -ge 3 ]; then
                    emit_event "SVC_$c" "TRIPPED" "Circuit broken."
                    notify_telegram "CIRCUIT TRIPPED: $c - 3 consecutive failures, manual intervention needed"
                    jq ".\"$c\" = {\"state\":\"TRIPPED\", \"fails\":$fail_count, \"last_trip\":$now}" "$BREAKER_STATE" > "$BREAKER_STATE.tmp" && mv "$BREAKER_STATE.tmp" "$BREAKER_STATE"
                else
                    emit_event "SVC_$c" "DEGRADED" "Restart $fail_count/3"
                    jq ".\"$c\".fails = $fail_count" "$BREAKER_STATE" > "$BREAKER_STATE.tmp" && mv "$BREAKER_STATE.tmp" "$BREAKER_STATE"
                    docker compose -f "$COMPOSE_FILE" restart "$c"
                fi
            fi
        done
        sleep 60
    done
}

# ==================== SURGICAL MENUS ====================

reconcile_docker() {
    if command -v docker &>/dev/null && systemctl is-active --quiet docker; then
        echo -e "\n🟢 Docker is already INSTALLED and ACTIVE."
        read -rp "⚠️ Force ecosystem reinstall? (y/N): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
    fi
    
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "\n  🛠️  [DRY-RUN] Would apt-get install docker-ce docker-compose-plugin"
        return 0
    fi

    emit_event "INFRA_DOCKER" "STARTING"
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    fi
    [ -f /etc/apt/sources.list.d/docker.list ] || echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    retry 3 apt-get update
    retry 3 apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    usermod -aG docker "$TARGET_USER" && systemctl enable --now docker
    emit_event "INFRA_DOCKER" "READY"
}

reconcile_tailscale() {
    if command -v tailscale &>/dev/null && systemctl is-active --quiet tailscaled; then
        echo -e "\n🟢 Tailscale is already INSTALLED and ACTIVE."
        read -rp "⚠️ Force reinstall? (y/N): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
    fi
    
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "\n  🛠️  [DRY-RUN] Would curl Tailscale install script and enable systemd service."
        return 0
    fi

    emit_event "INFRA_TS" "STARTING"
    retry 3 bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
    systemctl enable --now tailscaled
    emit_event "INFRA_TS" "READY"
}

reconcile_netplan() {
    emit_event "SYS_NETPLAN" "STARTING"
    [ -f "${REPO}/system/50-cloud-init.yaml" ] && atomic_file_sync NETPLAN "${REPO}/system/50-cloud-init.yaml" "/etc/netplan/50-cloud-init.yaml"
    if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
    chmod 600 /etc/netplan/*.yaml 2>/dev/null || true
    emit_event "SYS_NETPLAN" "READY" "Run netplan apply manually"
}

reconcile_ssh_cron() {
    emit_event "SYS_SSH" "STARTING"
    [ -f "${REPO}/system/ssh-config" ] && atomic_file_sync SSH "${REPO}/system/ssh-config" "${HOME_DIR}/.ssh/config"
    if [ "$DRY_RUN" -eq 1 ]; then echo -e "  🛠️  [DRY-RUN] Would apply crontab rules."; return 0; fi
    [ -f "${REPO}/system/crontab.bak" ] && su - "$TARGET_USER" -c "crontab ${REPO}/system/crontab.bak"
    emit_event "SYS_SSH" "READY"
}

menu_infra() {
    while true; do
        echo -e "\n--- [ Infrastructure Surgery ] ---"
        echo "1) Sync All Infra"; echo "2) Sync Docker"; echo "3) Sync Tailscale"; echo "b) Back"
        read -rp ">> " c
        case "$c" in
            1) reconcile_docker; reconcile_tailscale ;; 2) reconcile_docker ;; 3) reconcile_tailscale ;; b) break ;;
        esac
    done
}

menu_apps() {
    while true; do
        echo -e "\n--- [ Application Surgery ] ---"
        echo "1) Sync Home Assistant"; echo "2) Sync MQTT"; echo "3) Sync Z2M"; echo "4) Sync Node-RED"; echo "b) Back"
        read -rp ">> " c
        case "$c" in
            1) atomic_sync HA "${REPO}/homeassistant/" "${HOME_DIR}/homeassistant/" "homeassistant" ;;
            2) atomic_sync MQTT "${REPO}/mosquitto/config/" "${HOME_DIR}/mosquitto/config/" "mosquitto" ;;
            3) atomic_sync Z2M "${REPO}/zigbee2mqtt/data/" "${HOME_DIR}/zigbee2mqtt/data/" "zigbee2mqtt" ;;
            4) atomic_sync NODERED "${REPO}/nodered/data/" "${HOME_DIR}/nodered/data/" "nodered" ;;
            b) break ;;
        esac
    done
}

menu_system() {
    while true; do
        echo -e "\n--- [ System Surgery ] ---"
        echo "1) Sync Netplan (WiFi)"; echo "2) Sync SSH & Cron"; echo "b) Back"
        read -rp ">> " c
        case "$c" in
            1) reconcile_netplan ;; 2) reconcile_ssh_cron ;; b) break ;;
        esac
    done
}

show_main_menu() {
    while true; do
        local mode_color="\e[32mLIVE (Destructive)\e[0m"
        [ "$DRY_RUN" -eq 1 ] && mode_color="\e[33mDRY-RUN (Simulation Only)\e[0m"

        echo -e "\n=== SmartHome OS v22.1 (The Oracle) ==="
        echo -e "Execution Mode: $mode_color"
        echo "0) AUTONOMOUS DAG BOOT (Create Safe Point -> Pull -> Build)"
        echo "1) Infrastructure Surgery -->"
        echo "2) Application Surgery    -->"
        echo "3) System Surgery         -->"
        echo "4) Engage Watchdog Daemon"
        echo "5) Read Audit Log"
        echo "6) 🆘 EMERGENCY: Rollback to Last Safe Point"
        echo "D) 🔄 Toggle Dry-Run Mode"
        echo "q) Quit"
        read -rp "Action: " c
        case "$c" in
            0) create_safe_point && safe_git_pull && boot_dag ;;
            1) menu_infra ;;
            2) menu_apps ;;
            3) menu_system ;;
            4) run_watchdog ;;
            5) tail -n 15 "$EVENT_LOG" 2>/dev/null | jq -C . || echo "No events logged yet." ;;
            6) emergency_rollback ;;
            D|d) if [ "$DRY_RUN" -eq 1 ]; then DRY_RUN=0; else DRY_RUN=1; fi ;;
            q) exit 0 ;;
        esac
    done
}

[ "$(id -u)" -eq 0 ] || { echo "Sudo required."; exit 1; }
show_main_menu
