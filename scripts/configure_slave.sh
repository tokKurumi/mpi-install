#!/bin/bash

# configure_slave.sh - Slave nodes configuration (called from master)

set -euo pipefail

# Load common functions
SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/../lib/common.sh"

# Verify slave environment
verify_slave_environment() {
    local slave_ip=$1
    local slave_user=$2

    ssh "${slave_user}@${slave_ip}" '
    if [ -f /etc/slurm/slurm.conf ]; then
        echo "ERROR: This host is already configured as master" >&2
        exit 1
    fi
    '
}

# Configure slave node
configure_slave_node() {
    local slave_ip=$1
    local slave_user=$2

    info "Configuring slave node ${slave_ip}"

    ssh "${slave_user}@${slave_ip}" '
    set -euo pipefail
    source /tmp/common.sh

    # 1. Install required packages
    install_package slurmd
    install_package munge
    install_package mpich
    install_package libmpich-dev

    # 2. Setup Munge environment
    sudo mkdir -p /etc/munge
    sudo chown munge:munge /etc/munge
    sudo chmod 711 /etc/munge

    # 3. Setup Slurm directories
    sudo mkdir -p /var/spool/slurmd
    sudo chown slurm:slurm /var/spool/slurmd
    sudo chmod 755 /var/spool/slurmd

    # 4. Validate user existence
    if ! id slurm &>/dev/null; then
        error "slurm user does not exist"
        exit 1
    fi

    if ! id munge &>/dev/null; then
        error "munge user does not exist"
        exit 1
    fi

    # 5. Enable services (without starting)
    sudo systemctl enable slurmd
    sudo systemctl enable munge

    success "Slave node configuration completed"
    '
}

# Process all slaves from config
process_slaves() {
    local config_file=$1

    info "Starting slave nodes configuration"

    local slave_count=$(jq '.slaves | length' "$config_file")
    if [ "$slave_count" -eq 0 ]; then
        warn "No slave nodes configured"
        return 0
    fi

    for ((i = 0; i < slave_count; i++)); do
        local slave_ip=$(jq -r ".slaves[$i].ip" "$config_file")
        local slave_user=$(jq -r ".slaves[$i].username" "$config_file")

        info "Configuring slave $((i + 1))/$slave_count: ${slave_user}@${slave_ip}"

        verify_slave_environment "$slave_ip" "$slave_user"
        configure_slave_node "$slave_ip" "$slave_user"

        success "Slave ${slave_ip} configured successfully"
    done
}

main() {
    if [[ $# -ne 1 ]]; then
        error "Usage: $0 <config_file>"
        exit 1
    fi

    local config_file=$1

    process_slaves "$config_file"

    success "All slave nodes configured"
    info "Note: Services will be started after running run_services.sh"
}

main "$@"
