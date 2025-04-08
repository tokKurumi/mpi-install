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

    # Validate master node configuration
    for field in "${required_master_fields[@]}"; do
        if ! jq -e ".master.${field}" "$config_file" >/dev/null; then
            error "Master configuration is missing required field: $field"
            exit 1
        fi
    done

    # Validate slaves configuration
    local slave_count=$(jq '.slaves | length' "$config_file")
    if [[ "$slave_count" -eq 0 ]]; then
        error "At least one slave node must be configured"
        exit 1
    fi

    for ((i=0; i<slave_count; i++)); do
        for field in "${required_slave_fields[@]}"; do
            if ! jq -e ".slaves[${i}].${field}" "$config_file" >/dev/null; then
                error "Slave $i is missing required field: $field"
                exit 1
            fi
        done
    done

    # Validate IP addresses format
    local master_ip=$(jq -r '.master.ip' "$config_file")
    if ! [[ "$master_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "Master IP address $master_ip is invalid"
        exit 1
    fi

    for ((i=0; i<slave_count; i++)); do
        local slave_ip=$(jq -r ".slaves[${i}].ip" "$config_file")
        if ! [[ "$slave_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            error "Slave $i IP address $slave_ip is invalid"
            exit 1
        fi
    done
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