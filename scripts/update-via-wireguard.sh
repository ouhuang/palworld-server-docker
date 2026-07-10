#!/usr/bin/env bash
# Restart Palworld once with its Docker subnet routed through a WireGuard peer.
#
# Prerequisites on this host:
#   - /etc/wireguard/wg-palupdate.conf exists and uses "Table = off".
#   - The German VPS is configured to NAT the WireGuard subnet to the Internet.
#   - UPDATE_ON_BOOT=true is set in .env.
#
# Run:
#   sudo ./scripts/update-via-wireguard.sh
#
# Environment overrides:
#   WG_INTERFACE=wg-palupdate DOCKER_NETWORK=palworld-server-docker_default \
#     sudo ./scripts/update-via-wireguard.sh
#
# If a host shutdown interrupted a previous run, remove its dedicated rules with:
#   sudo ./scripts/update-via-wireguard.sh --cleanup

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="${PROJECT_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
readonly WG_INTERFACE="${WG_INTERFACE:-wg-palupdate}"
readonly DOCKER_NETWORK="${DOCKER_NETWORK:-palworld-server-docker_default}"
readonly DOCKER_SUBNET="${DOCKER_SUBNET:-}"
readonly SERVICE="${PALWORLD_SERVICE:-palworld}"
readonly ROUTE_TABLE="${ROUTE_TABLE:-51820}"
readonly RULE_PRIORITY="${RULE_PRIORITY:-51820}"
readonly UPDATE_TIMEOUT_SECONDS="${UPDATE_TIMEOUT_SECONDS:-3600}"

WG_UP=false
ROUTE_ADDED=false
RULE_ADDED=false
NAT_ADDED=false
FORWARD_OUT_ADDED=false
FORWARD_RETURN_ADDED=false
SUBNET=""

log() {
    printf '[palworld-update] %s\n' "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

require_root() {
    [ "${EUID}" -eq 0 ] || die "Run this script with sudo."
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

resolve_subnet() {
    if [ -n "$DOCKER_SUBNET" ]; then
        SUBNET="$DOCKER_SUBNET"
        return
    fi

    SUBNET="$(docker network inspect "$DOCKER_NETWORK" \
        --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null)" || true
    [ -n "$SUBNET" ] || die "Cannot find Docker network '$DOCKER_NETWORK'. Set DOCKER_NETWORK or DOCKER_SUBNET."
}

has_iptables_rule() {
    local table="$1"
    shift
    iptables -t "$table" -C "$@" >/dev/null 2>&1
}

remove_iptables_rule() {
    local table="$1"
    shift
    while has_iptables_rule "$table" "$@"; do
        iptables -t "$table" -D "$@" || true
    done
}

cleanup_current_run() {
    local exit_code=$?
    trap - EXIT INT TERM

    if [ "$FORWARD_RETURN_ADDED" = true ]; then
        iptables -D FORWARD -d "$SUBNET" -i "$WG_INTERFACE" \
            -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || true
    fi
    if [ "$FORWARD_OUT_ADDED" = true ]; then
        iptables -D FORWARD -s "$SUBNET" -o "$WG_INTERFACE" -j ACCEPT || true
    fi
    if [ "$NAT_ADDED" = true ]; then
        iptables -t nat -D POSTROUTING -s "$SUBNET" -o "$WG_INTERFACE" -j MASQUERADE || true
    fi
    if [ "$RULE_ADDED" = true ]; then
        ip rule del priority "$RULE_PRIORITY" || true
    fi
    if [ "$ROUTE_ADDED" = true ]; then
        ip route flush table "$ROUTE_TABLE" || true
    fi
    if [ "$WG_UP" = true ]; then
        wg-quick down "$WG_INTERFACE" || true
    fi

    exit "$exit_code"
}

cleanup_stale_state() {
    resolve_subnet
    log "Removing dedicated update routing for $SUBNET."

    remove_iptables_rule filter FORWARD -d "$SUBNET" -i "$WG_INTERFACE" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    remove_iptables_rule filter FORWARD -s "$SUBNET" -o "$WG_INTERFACE" -j ACCEPT
    remove_iptables_rule nat POSTROUTING -s "$SUBNET" -o "$WG_INTERFACE" -j MASQUERADE

    while ip rule del priority "$RULE_PRIORITY" >/dev/null 2>&1; do
        :
    done
    ip route flush table "$ROUTE_TABLE" || true

    if ip link show dev "$WG_INTERFACE" >/dev/null 2>&1; then
        wg-quick down "$WG_INTERFACE" || true
    fi
}

validate_environment() {
    require_command docker
    require_command ip
    require_command iptables
    require_command wg-quick
    docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
    [ -f "/etc/wireguard/${WG_INTERFACE}.conf" ] || die "Missing /etc/wireguard/${WG_INTERFACE}.conf"
    [ "$(sysctl -n net.ipv4.ip_forward)" = "1" ] || die "IPv4 forwarding is disabled. Start Docker or enable net.ipv4.ip_forward."

    cd "$PROJECT_DIR"
    [ -f .env ] || die "Missing $PROJECT_DIR/.env"
    grep -Eiq '^[[:space:]]*UPDATE_ON_BOOT[[:space:]]*=[[:space:]]*true[[:space:]]*(#.*)?$' .env || \
        die "UPDATE_ON_BOOT=true is required in $PROJECT_DIR/.env"
}

wait_for_server_start() {
    local started_at="$1"
    local container_id deadline next_notice now state

    container_id="$(docker compose ps -q "$SERVICE")"
    [ -n "$container_id" ] || die "Cannot find the '$SERVICE' container after restart."

    deadline=$(( $(date +%s) + UPDATE_TIMEOUT_SECONDS ))
    next_notice=$(( $(date +%s) + 30 ))

    while true; do
        state="$(docker inspect --format '{{.State.Status}}' "$container_id" 2>/dev/null || true)"
        case "$state" in
            running|restarting)
                ;;
            *)
                docker compose logs --since "$started_at" "$SERVICE" || true
                die "Container stopped while updating (state: ${state:-unknown})."
                ;;
        esac

        if docker logs --since "$started_at" "$container_id" 2>&1 | grep -Fq 'Starting Server'; then
            log "Steam update finished; Palworld is starting."
            docker compose logs --since "$started_at" "$SERVICE" || true
            return
        fi

        now=$(date +%s)
        if [ "$now" -ge "$deadline" ]; then
            docker compose logs --since "$started_at" "$SERVICE" || true
            die "Timed out after ${UPDATE_TIMEOUT_SECONDS}s waiting for Palworld to start."
        fi
        if [ "$now" -ge "$next_notice" ]; then
            log "Waiting for SteamCMD update to finish..."
            next_notice=$(( now + 30 ))
        fi
        sleep 5
    done
}

main() {
    require_root
    validate_environment

    if [ "${1:-}" = "--cleanup" ]; then
        cleanup_stale_state
        log "Cleanup complete."
        return
    fi
    [ "$#" -eq 0 ] || die "Usage: $0 [--cleanup]"

    resolve_subnet
    ip link show dev "$WG_INTERFACE" >/dev/null 2>&1 && \
        die "$WG_INTERFACE already exists. Run '$0 --cleanup' first if it is stale."
    ip rule show | grep -q "^${RULE_PRIORITY}:" && \
        die "IP rule priority $RULE_PRIORITY is already in use. Set RULE_PRIORITY or clean up the previous run."

    trap cleanup_current_run EXIT INT TERM

    log "Starting WireGuard interface $WG_INTERFACE."
    wg-quick up "$WG_INTERFACE"
    WG_UP=true

    log "Routing Docker subnet $SUBNET through the German WireGuard peer."
    ip route replace default dev "$WG_INTERFACE" table "$ROUTE_TABLE"
    ROUTE_ADDED=true
    ip rule add priority "$RULE_PRIORITY" from "$SUBNET" table "$ROUTE_TABLE"
    RULE_ADDED=true

    if ! has_iptables_rule nat POSTROUTING -s "$SUBNET" -o "$WG_INTERFACE" -j MASQUERADE; then
        iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$WG_INTERFACE" -j MASQUERADE
        NAT_ADDED=true
    fi
    if ! has_iptables_rule filter FORWARD -s "$SUBNET" -o "$WG_INTERFACE" -j ACCEPT; then
        iptables -A FORWARD -s "$SUBNET" -o "$WG_INTERFACE" -j ACCEPT
        FORWARD_OUT_ADDED=true
    fi
    if ! has_iptables_rule filter FORWARD -d "$SUBNET" -i "$WG_INTERFACE" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; then
        iptables -A FORWARD -d "$SUBNET" -i "$WG_INTERFACE" \
            -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        FORWARD_RETURN_ADDED=true
    fi

    local started_at
    started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    log "Restarting $SERVICE; UPDATE_ON_BOOT will invoke SteamCMD."
    docker compose restart "$SERVICE"
    wait_for_server_start "$started_at"
}

main "$@"
