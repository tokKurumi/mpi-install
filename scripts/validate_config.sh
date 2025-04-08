#!/bin/bash

# validate_config.sh - Validate cluster configuration file

set -euo pipefail

# Load common functions
SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/../lib/common.sh"

# Validate that config file exists and is valid JSON
validate_config_file() {
    local config_file=$1

    if [[ ! -f "$config_file" ]]; then
        error "Configuration file $config_file does not exist"
        exit 1
    fi

    if ! validate_config "$config_file"; then
        error "Invalid configuration file"
        exit 1
    fi
}

# Validate configuration content
validate_config_content() {
    local config_file=$1
    local required_master_fields=("username" "ip" "password" "cluster_name" "slurmctld_port" "slurmd_port")
    local required_slave_fields=("id" "username" "ip" "password")
    local errors=()

    # Validate master node configuration
    for field in "${required_master_fields[@]}"; do
        if ! jq -e ".master.${field}" "$config_file" >/dev/null 2>&1; then
            errors+=("Master configuration is missing required field: $field")
        fi
    done

    # Validate slaves configuration
    local slave_count=$(jq '.slaves | length' "$config_file")
    if [[ "$slave_count" -eq 0 ]]; then
        errors+=("At least one slave node must be configured")
    else
        for ((i = 0; i < slave_count; i++)); do
            for field in "${required_slave_fields[@]}"; do
                if ! jq -e ".slaves[${i}].${field}" "$config_file" >/dev/null 2>&1; then
                    errors+=("Slave $i is missing required field: $field")
                fi
            done
        done
    fi

    # Validate IP addresses format
    local master_ip=$(jq -r '.master.ip' "$config_file" 2>/dev/null)
    if ! [[ "$master_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        errors+=("Master IP address $master_ip is invalid")
    fi

    for ((i = 0; i < slave_count; i++)); do
        local slave_ip=$(jq -r ".slaves[${i}].ip" "$config_file" 2>/dev/null)
        if ! [[ "$slave_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            errors+=("Slave $i IP address $slave_ip is invalid")
        fi
    done

    # Report all errors if any
    if [[ ${#errors[@]} -gt 0 ]]; then
        error "Found ${#errors[@]} configuration issues:"
        for err in "${errors[@]}"; do
            error "  - $err"
        done
        exit 1
    fi

    return 0
}

main() {
    if [[ $# -ne 1 ]]; then
        error "Usage: $0 <config_file>"
        exit 1
    fi

    local config_file=$1

    info "Validating configuration file: $config_file"

    validate_config_file "$config_file"
    validate_config_content "$config_file"

    success "Configuration file is valid"
}

main "$@"