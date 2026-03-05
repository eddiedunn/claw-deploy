#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# claw-instance.sh — Multi-instance management for Claw Deploy
# ============================================================================
# Manages multiple claw variant instances running as rootless Podman containers
# under a dedicated service user.
#
# Usage: claw-instance.sh <command> [args...]
#
# Commands:
#   create  <name> [--variant V]  Create a new instance (default variant from env)
#   list                          List all instances with status, variant, and ports
#   start   <name>                Start an instance
#   stop    <name>                Stop an instance
#   restart <name>                Restart an instance
#   destroy <name>                Remove an instance (with confirmation)
#   config  <name>                Show or edit instance config
#   status  <name>                Detailed status of an instance
#   logs    <name> [N]            Show recent logs (default 50 lines)
# ============================================================================

# Source environment configuration
source "${CLAW_HOME:=/data/openclaw}/.env" 2>/dev/null || true

CLAW_HOME="${CLAW_HOME:-/data/openclaw}"

# Source variant library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/variant.sh
source "${SCRIPT_DIR}/../lib/variant.sh" 2>/dev/null \
    || source "${CLAW_HOME}/lib/variant.sh" 2>/dev/null \
    || { echo "ERROR: Cannot find lib/variant.sh" >&2; exit 1; }

CLAW_VARIANT="${CLAW_VARIANT:-openclaw}"
CLAW_USER="${CLAW_USER:-openclaw}"
CLAW_UID="${CLAW_UID:-$(id -u)}"
CLAW_GID="${CLAW_GID:-$(id -g)}"
CLAW_IMAGE="${CLAW_IMAGE:-}"
CLAW_DNS_PRIMARY="${CLAW_DNS_PRIMARY:-100.100.100.100}"
CLAW_DNS_FALLBACK="${CLAW_DNS_FALLBACK:-1.1.1.1}"
CLAW_GATEWAY_PORT="${CLAW_GATEWAY_PORT:-}"
CLAW_BRIDGE_PORT="${CLAW_BRIDGE_PORT:-}"
CLAW_MEMORY_DEFAULT="${CLAW_MEMORY_DEFAULT:-8g}"
CLAW_CPUS_DEFAULT="${CLAW_CPUS_DEFAULT:-4}"
CLAW_MEMORY_INSTANCE="${CLAW_MEMORY_INSTANCE:-4g}"
CLAW_CPUS_INSTANCE="${CLAW_CPUS_INSTANCE:-2}"

INSTANCE_REGISTRY="${CLAW_HOME}/.instance-registry"
TEMPLATE_DIR="${CLAW_HOME}/templates"
QUADLET_DIR="${CLAW_HOME}/.config/containers/systemd"
SHARED_SKILLS="${CLAW_HOME}/shared/skills"

# Ensure we're running as the service user
if [ "$(id -u)" -ne "${CLAW_UID}" ]; then
    echo "ERROR: This script must run as the ${CLAW_USER} user (uid ${CLAW_UID})." >&2
    echo "       Use: sudo -u ${CLAW_USER} bash -c '${0} ${*}'" >&2
    exit 1
fi

# Ensure XDG_RUNTIME_DIR is set for podman/systemctl
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${CLAW_UID}}"

# ============================================================================
# Migration: .port-registry -> .instance-registry
# ============================================================================

migrate_port_registry() {
    local old_registry="${CLAW_HOME}/.port-registry"
    if [ -f "$old_registry" ] && [ ! -f "$INSTANCE_REGISTRY" ]; then
        echo "Migrating .port-registry to .instance-registry..."
        while IFS=: read -r name gw_port br_port; do
            [ -z "${name}" ] && continue
            # Legacy entries are assumed to be openclaw variant
            echo "${name}:openclaw:${gw_port}:${br_port}" >> "$INSTANCE_REGISTRY"
        done < "$old_registry"
        echo "Migration complete. Old .port-registry preserved."
    fi
}

# ============================================================================
# Helper functions
# ============================================================================

validate_name() {
    local name="$1"
    if [ -z "${name}" ]; then
        echo "ERROR: Instance name is required." >&2
        return 1
    fi
    if ! echo "${name}" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; then
        echo "ERROR: Invalid name '${name}'. Must be lowercase alphanumeric + hyphens," >&2
        echo "       no leading/trailing hyphens. Examples: dev, test-01, my-bot" >&2
        return 1
    fi
    if [ "${name}" = "default" ]; then
        echo "ERROR: 'default' is reserved for the existing instance." >&2
        return 1
    fi
}

ensure_instance_registry() {
    migrate_port_registry
    if [ ! -f "${INSTANCE_REGISTRY}" ]; then
        echo "Initializing instance registry with existing default instance..."
        local def_variant="${CLAW_VARIANT}"
        local def_gw_port="${CLAW_GATEWAY_PORT:-$(variant_default_gateway_port "$def_variant")}"
        local def_br_port="${CLAW_BRIDGE_PORT:-$(variant_default_bridge_port "$def_variant")}"
        echo "default:${def_variant}:${def_gw_port}:${def_br_port}" > "${INSTANCE_REGISTRY}"
    fi
    # Ensure default is registered (idempotent)
    if ! grep -q '^default:' "${INSTANCE_REGISTRY}"; then
        local def_variant="${CLAW_VARIANT}"
        local def_gw_port="${CLAW_GATEWAY_PORT:-$(variant_default_gateway_port "$def_variant")}"
        local def_br_port="${CLAW_BRIDGE_PORT:-$(variant_default_bridge_port "$def_variant")}"
        echo "default:${def_variant}:${def_gw_port}:${def_br_port}" >> "${INSTANCE_REGISTRY}"
    fi
}

get_instance_entry() {
    local name="$1"
    ensure_instance_registry
    grep "^${name}:" "${INSTANCE_REGISTRY}" | head -1
}

get_instance_variant() {
    local name="$1"
    local entry
    entry="$(get_instance_entry "$name")"
    echo "$entry" | cut -d: -f2
}

get_instance_ports() {
    local name="$1"
    local entry
    entry="$(get_instance_entry "$name")"
    local gw br
    gw="$(echo "$entry" | cut -d: -f3)"
    br="$(echo "$entry" | cut -d: -f4)"
    echo "${gw}:${br}"
}

allocate_ports() {
    local variant="$1"
    ensure_instance_registry
    # Find the highest gateway port in use across all variants
    local max_port
    max_port=$(awk -F: '{print $3}' "${INSTANCE_REGISTRY}" | sort -n | tail -1)
    if [ -z "${max_port}" ]; then
        max_port=$(variant_default_gateway_port "$variant")
    fi
    # Next available pair (gateway ports are odd-indexed: base, base+2, base+4...)
    local next_gateway=$((max_port + 2))
    local next_bridge=$((next_gateway + 1))
    echo "${next_gateway}:${next_bridge}"
}

instance_exists() {
    local name="$1"
    ensure_instance_registry
    grep -q "^${name}:" "${INSTANCE_REGISTRY}"
}

get_state_dir() {
    local name="$1"
    local variant
    variant="$(get_instance_variant "$name")"
    variant_state_dir "$variant" "$name" "$CLAW_HOME"
}

get_workspace_dir() {
    local name="$1"
    if [ "${name}" = "default" ]; then
        echo "${CLAW_HOME}/workspace"
    else
        echo "${CLAW_HOME}/workspace-${name}"
    fi
}

get_service_name() {
    local name="$1"
    local variant
    variant="$(get_instance_variant "$name")"
    variant_service_name "$variant" "$name"
}

get_quadlet_file() {
    local name="$1"
    echo "${QUADLET_DIR}/$(get_service_name "${name}").container"
}

get_service_status() {
    local service
    service="$(get_service_name "$1")"
    if systemctl --user is-active "${service}.service" &>/dev/null; then
        echo "running"
    elif systemctl --user is-failed "${service}.service" &>/dev/null; then
        echo "failed"
    else
        echo "stopped"
    fi
}

# ============================================================================
# Commands
# ============================================================================

cmd_create() {
    local name=""
    local variant="${CLAW_VARIANT}"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --variant)
                variant="${2:-}"
                shift 2
                ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                    shift
                else
                    echo "ERROR: Unexpected argument '${1}'." >&2
                    exit 1
                fi
                ;;
        esac
    done

    validate_name "${name}"
    validate_variant "${variant}"

    if instance_exists "${name}"; then
        echo "ERROR: Instance '${name}' already exists." >&2
        exit 1
    fi

    # Check templates exist
    if [ ! -f "${TEMPLATE_DIR}/instance.container.tmpl" ]; then
        echo "ERROR: Quadlet template not found at ${TEMPLATE_DIR}/instance.container.tmpl" >&2
        exit 1
    fi
    # Select config template: prefer variant-specific, fall back to generic
    local config_tmpl="${TEMPLATE_DIR}/config.json.${variant}.tmpl"
    if [ ! -f "${config_tmpl}" ]; then
        config_tmpl="${TEMPLATE_DIR}/config.json.tmpl"
    fi
    if [ ! -f "${config_tmpl}" ]; then
        echo "ERROR: Config template not found at ${TEMPLATE_DIR}/config.json.tmpl" >&2
        exit 1
    fi

    # Allocate ports
    local ports
    ports=$(allocate_ports "$variant")
    local gateway_port="${ports%%:*}"
    local bridge_port="${ports##*:}"

    local state_dir
    state_dir="$(variant_state_dir "$variant" "$name" "$CLAW_HOME")"
    local workspace_dir
    workspace_dir=$(get_workspace_dir "${name}")
    local config_filename
    config_filename="$(variant_config_filename "$variant")"
    local token_var
    token_var="$(variant_token_env_var "$variant")"

    echo "Creating ${variant} instance '${name}'..."
    echo "  Variant:      ${variant}"
    echo "  Gateway port: ${gateway_port}"
    echo "  Bridge port:  ${bridge_port}"
    echo "  State dir:    ${state_dir}"
    echo "  Workspace:    ${workspace_dir}"
    echo ""

    # Create directories
    mkdir -p "${state_dir}"
    mkdir -p "${workspace_dir}"
    mkdir -p "${SHARED_SKILLS}"
    mkdir -p "${QUADLET_DIR}"

    # Generate config from template
    sed -e "s/{{GATEWAY_PORT}}/${gateway_port}/g" \
        -e "s/{{BRIDGE_PORT}}/${bridge_port}/g" \
        "${config_tmpl}" \
        > "${state_dir}/${config_filename}"
    chmod 600 "${state_dir}/${config_filename}"
    echo "  Created config: ${state_dir}/${config_filename}"

    # Generate .env with new gateway token (variant-specific token var name)
    local token
    token=$(openssl rand -hex 16)
    echo "${token_var}=${token}" > "${state_dir}/.env"
    chmod 600 "${state_dir}/.env"
    echo "  Created .env:   ${state_dir}/.env"

    # Determine image and service name for this variant
    local image="${CLAW_IMAGE:-$(variant_default_image "$variant")}"
    local service_name
    service_name="$(variant_service_name "$variant" "$name")"
    local quadlet_file="${QUADLET_DIR}/${service_name}.container"

    # Generate quadlet from template
    sed -e "s|{{NAME}}|${name}|g" \
        -e "s|{{VARIANT}}|${variant}|g" \
        -e "s|{{GATEWAY_PORT}}|${gateway_port}|g" \
        -e "s|{{BRIDGE_PORT}}|${bridge_port}|g" \
        -e "s|{{DNS_PRIMARY}}|${CLAW_DNS_PRIMARY}|g" \
        -e "s|{{DNS_FALLBACK}}|${CLAW_DNS_FALLBACK}|g" \
        -e "s|{{MEMORY}}|${CLAW_MEMORY_INSTANCE}|g" \
        -e "s|{{CPUS}}|${CLAW_CPUS_INSTANCE}|g" \
        -e "s|{{IMAGE}}|${image}|g" \
        -e "s|{{USER_MAPPING}}|${CLAW_UID}:${CLAW_GID}|g" \
        -e "s|{{CLAW_HOME}}|${CLAW_HOME}|g" \
        "${TEMPLATE_DIR}/instance.container.tmpl" \
        > "${quadlet_file}"
    chmod 644 "${quadlet_file}"
    echo "  Created quadlet: ${quadlet_file}"

    # Register in instance registry (format: name:variant:gateway:bridge)
    echo "${name}:${variant}:${gateway_port}:${bridge_port}" >> "${INSTANCE_REGISTRY}"
    echo "  Registered in instance registry"

    # Reload systemd
    systemctl --user daemon-reload
    echo "  Systemd daemon reloaded"

    echo ""
    echo "Instance '${name}' (${variant}) created successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Start the instance:"
    echo "     claw-instance.sh start ${name}"
    echo ""
    echo "  2. Configure Telegram bot (if needed):"
    echo "     claw-instance.sh config ${name}"
    echo "     Add channels.telegram section with your bot token"
    echo ""
    echo "  3. Configure auth provider:"
    echo "     claw-instance.sh config ${name}"
    echo "     Add auth.profiles section with your API key"
    echo ""
    echo "  4. Check status:"
    echo "     claw-instance.sh status ${name}"
}

cmd_list() {
    ensure_instance_registry

    printf "%-15s %-10s %-10s %-8s %-8s %-18s %s\n" \
        "INSTANCE" "VARIANT" "STATUS" "GATEWAY" "BRIDGE" "CONTAINER" "STATE DIR"
    printf "%-15s %-10s %-10s %-8s %-8s %-18s %s\n" \
        "--------" "-------" "------" "-------" "------" "---------" "---------"

    while IFS=: read -r name variant gw_port br_port; do
        [ -z "${name}" ] && continue
        local status
        status=$(get_service_status "${name}")
        local container_name
        container_name=$(variant_container_name "${variant}" "${name}")
        local state_dir
        state_dir=$(variant_state_dir "${variant}" "${name}" "${CLAW_HOME}")

        # Color status
        local status_display
        case "${status}" in
            running) status_display="\033[32m${status}\033[0m" ;;
            failed)  status_display="\033[31m${status}\033[0m" ;;
            *)       status_display="\033[33m${status}\033[0m" ;;
        esac

        printf "%-15s %-10s %-10b %-8s %-8s %-18s %s\n" \
            "${name}" "${variant}" "${status_display}" "${gw_port}" "${br_port}" \
            "${container_name}" "${state_dir}"
    done < "${INSTANCE_REGISTRY}"
}

cmd_start() {
    local name="${1:-}"
    if [ -z "${name}" ]; then
        echo "ERROR: Instance name is required." >&2
        echo "Usage: claw-instance.sh start <name>" >&2
        exit 1
    fi

    if ! instance_exists "${name}"; then
        echo "ERROR: Instance '${name}' not found. Use 'list' to see available instances." >&2
        exit 1
    fi

    local service
    service="$(get_service_name "${name}")"
    echo "Starting ${service}.service..."
    systemctl --user start "${service}.service"
    echo "Started. Check with: claw-instance.sh status ${name}"
}

cmd_stop() {
    local name="${1:-}"
    if [ -z "${name}" ]; then
        echo "ERROR: Instance name is required." >&2
        echo "Usage: claw-instance.sh stop <name>" >&2
        exit 1
    fi

    if ! instance_exists "${name}"; then
        echo "ERROR: Instance '${name}' not found. Use 'list' to see available instances." >&2
        exit 1
    fi

    local service
    service="$(get_service_name "${name}")"
    echo "Stopping ${service}.service..."
    systemctl --user stop "${service}.service"
    echo "Stopped."
}

cmd_restart() {
    local name="${1:-}"
    if [ -z "${name}" ]; then
        echo "ERROR: Instance name is required." >&2
        echo "Usage: claw-instance.sh restart <name>" >&2
        exit 1
    fi

    if ! instance_exists "${name}"; then
        echo "ERROR: Instance '${name}' not found. Use 'list' to see available instances." >&2
        exit 1
    fi

    local service
    service="$(get_service_name "${name}")"
    echo "Restarting ${service}.service..."
    systemctl --user restart "${service}.service"
    echo "Restarted. Check with: claw-instance.sh status ${name}"
}

cmd_destroy() {
    local name="${1:-}"
    if [ -z "${name}" ]; then
        echo "ERROR: Instance name is required." >&2
        echo "Usage: claw-instance.sh destroy <name>" >&2
        exit 1
    fi

    if [ "${name}" = "default" ]; then
        echo "ERROR: Cannot destroy the default instance." >&2
        exit 1
    fi

    if ! instance_exists "${name}"; then
        echo "ERROR: Instance '${name}' not found. Use 'list' to see available instances." >&2
        exit 1
    fi

    local variant
    variant="$(get_instance_variant "$name")"
    local state_dir
    state_dir=$(get_state_dir "${name}")
    local workspace_dir
    workspace_dir=$(get_workspace_dir "${name}")
    local quadlet_file
    quadlet_file=$(get_quadlet_file "${name}")

    echo "WARNING: This will destroy ${variant} instance '${name}'."
    echo "  Quadlet:   ${quadlet_file}"
    echo "  State dir: ${state_dir}"
    echo "  Workspace: ${workspace_dir}"
    echo ""
    read -rp "Are you sure? [y/N] " confirm
    if [ "${confirm}" != "y" ] && [ "${confirm}" != "Y" ]; then
        echo "Aborted."
        exit 0
    fi

    # Stop the service if running
    local service
    service="$(get_service_name "${name}")"
    if systemctl --user is-active "${service}.service" &>/dev/null; then
        echo "Stopping ${service}.service..."
        systemctl --user stop "${service}.service"
    fi

    # Remove quadlet file
    if [ -f "${quadlet_file}" ]; then
        rm -f "${quadlet_file}"
        echo "Removed quadlet: ${quadlet_file}"
    fi

    # Reload systemd
    systemctl --user daemon-reload

    # Ask about data removal
    echo ""
    read -rp "Also remove state dir (${state_dir})? [y/N] " rm_state
    if [ "${rm_state}" = "y" ] || [ "${rm_state}" = "Y" ]; then
        rm -rf "${state_dir}"
        echo "Removed state dir."
    fi

    read -rp "Also remove workspace (${workspace_dir})? [y/N] " rm_workspace
    if [ "${rm_workspace}" = "y" ] || [ "${rm_workspace}" = "Y" ]; then
        rm -rf "${workspace_dir}"
        echo "Removed workspace dir."
    fi

    # Remove from instance registry
    local tmp_registry="${INSTANCE_REGISTRY}.tmp"
    grep -v "^${name}:" "${INSTANCE_REGISTRY}" > "${tmp_registry}" || true
    mv "${tmp_registry}" "${INSTANCE_REGISTRY}"
    echo "Removed from instance registry."

    echo ""
    echo "Instance '${name}' destroyed."
}

cmd_config() {
    local name="${1:-}"
    if [ -z "${name}" ]; then
        echo "ERROR: Instance name is required." >&2
        echo "Usage: claw-instance.sh config <name>" >&2
        exit 1
    fi

    if ! instance_exists "${name}"; then
        echo "ERROR: Instance '${name}' not found. Use 'list' to see available instances." >&2
        exit 1
    fi

    local variant
    variant="$(get_instance_variant "$name")"
    local state_dir
    state_dir=$(get_state_dir "${name}")
    local config_filename
    config_filename="$(variant_config_filename "$variant")"
    local config_file="${state_dir}/${config_filename}"

    if [ ! -f "${config_file}" ]; then
        echo "ERROR: Config file not found at ${config_file}" >&2
        exit 1
    fi

    echo "Config file: ${config_file}"
    echo ""

    if [ -n "${EDITOR:-}" ] && [ -t 0 ] && [ -t 1 ]; then
        read -rp "Open in ${EDITOR}? [y/N] " open_editor
        if [ "${open_editor}" = "y" ] || [ "${open_editor}" = "Y" ]; then
            "${EDITOR}" "${config_file}"
            exit 0
        fi
    fi

    cat "${config_file}"
}

cmd_status() {
    local name="${1:-}"
    if [ -z "${name}" ]; then
        echo "ERROR: Instance name is required." >&2
        echo "Usage: claw-instance.sh status <name>" >&2
        exit 1
    fi

    if ! instance_exists "${name}"; then
        echo "ERROR: Instance '${name}' not found. Use 'list' to see available instances." >&2
        exit 1
    fi

    local variant
    variant="$(get_instance_variant "$name")"
    local service
    service="$(get_service_name "${name}")"
    local container_name
    container_name="$(variant_container_name "$variant" "$name")"
    local state_dir
    state_dir=$(get_state_dir "${name}")
    local ports
    ports=$(get_instance_ports "${name}")
    local gateway_port="${ports%%:*}"
    local bridge_port="${ports##*:}"

    echo "=== ${variant} Instance: ${name} ==="
    echo ""
    echo "Variant:   ${variant}"
    echo "Ports:     gateway=${gateway_port}, bridge=${bridge_port}"
    echo "State:     ${state_dir}"
    echo "Workspace: $(get_workspace_dir "${name}")"
    echo "Quadlet:   $(get_quadlet_file "${name}")"
    echo ""
    echo "--- systemctl status ---"
    systemctl --user status "${service}.service" --no-pager 2>&1 || true
    echo ""

    # Container inspect (if running)
    if podman container exists "${container_name}" 2>/dev/null; then
        echo "--- container inspect (summary) ---"
        podman inspect "${container_name}" --format '{{.State.Status}} since {{.State.StartedAt}}' 2>/dev/null || true
        podman inspect "${container_name}" --format 'PID={{.State.Pid}} Memory={{.HostConfig.Memory}} CPUs={{.HostConfig.NanoCpus}}' 2>/dev/null || true
    fi
}

cmd_logs() {
    local name="${1:-}"
    if [ -z "${name}" ]; then
        echo "ERROR: Instance name is required." >&2
        echo "Usage: claw-instance.sh logs <name> [lines]" >&2
        exit 1
    fi

    local lines="${2:-50}"

    if ! instance_exists "${name}"; then
        echo "ERROR: Instance '${name}' not found. Use 'list' to see available instances." >&2
        exit 1
    fi

    local service
    service="$(get_service_name "${name}")"
    journalctl --user -u "${service}.service" --no-pager -n "${lines}"
}

cmd_help() {
    echo "Usage: claw-instance.sh <command> [args...]"
    echo ""
    echo "Commands:"
    echo "  create  <name> [--variant V]  Create a new instance (variants: openclaw, picoclaw, tradeclaw)"
    echo "  list                          List all instances with status, variant, and ports"
    echo "  start   <name>                Start an instance"
    echo "  stop    <name>                Stop an instance"
    echo "  restart <name>                Restart an instance"
    echo "  destroy <name>                Remove an instance (with confirmation)"
    echo "  config  <name>                Show or edit instance config"
    echo "  status  <name>                Detailed status of an instance"
    echo "  logs    <name> [N]            Show recent logs (default 50 lines)"
    echo ""
    echo "Instance names are globally unique across all variants."
    echo "Names must be lowercase alphanumeric with optional hyphens."
    echo ""
    echo "Examples:"
    echo "  claw-instance.sh create dev"
    echo "  claw-instance.sh create research --variant picoclaw"
    echo "  claw-instance.sh start dev"
    echo "  claw-instance.sh logs dev 100"
    echo "  claw-instance.sh destroy dev"
}

# ============================================================================
# Main dispatch
# ============================================================================

command="${1:-help}"
shift || true

case "${command}" in
    create)  cmd_create "$@" ;;
    list)    cmd_list "$@" ;;
    start)   cmd_start "$@" ;;
    stop)    cmd_stop "$@" ;;
    restart) cmd_restart "$@" ;;
    destroy) cmd_destroy "$@" ;;
    config)  cmd_config "$@" ;;
    status)  cmd_status "$@" ;;
    logs)    cmd_logs "$@" ;;
    help|-h|--help) cmd_help ;;
    *)
        echo "ERROR: Unknown command '${command}'" >&2
        echo "" >&2
        cmd_help >&2
        exit 1
        ;;
esac
