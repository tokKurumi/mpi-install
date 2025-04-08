#!/bin/bash

# install_slave.sh - Slave nodes installation script for Slurm+Munge cluster

set -euo pipefail

# Load common functions
SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/../lib/common.sh"

# Remote installation function
install_on_slave() {
    local slave_ip=$1
    local slave_user=$2

    info "Installing dependencies on ${slave_ip}"

    ssh "${slave_user}@${slave_ip}" '
    set -euo pipefail
    source /tmp/common.sh

    # Install packages
    install_package slurmd
    install_package munge
    install_package mpich
    install_package libmpich-dev

    # Setup Munge directory (if not exists)
    sudo mkdir -p /etc/munge
    sudo chown munge:munge /etc/munge
    sudo chmod 711 /etc/munge

    # Create Slurm spool directory
    sudo mkdir -p /var/spool/slurmd
    sudo chown slurm:slurm /var/spool/slurmd
    sudo chmod 755 /var/spool/slurmd

    # Enable services (but do not start yet)
    sudo systemctl enable slurmd
    sudo systemctl enable munge
    '
}

# Process each slave node
process_slaves() {
    local config_file=$1

    # Get all slaves from config
    local slave_count=$(jq '.slaves | length' "$config_file")

    for ((i = 0; i < slave_count; i++)); do
        local slave_ip=$(jq -r ".slaves[${i}].ip" "$config_file")
        local slave_user=$(jq -r ".slaves[${i}].username" "$config_file")

        info "Processing slave ${i+1}/${slave_count}: ${slave_user}@${slave_ip}"

        transfer_common "$slave_ip" "$slave_user"
        install_on_slave "$slave_ip" "$slave_user"

        success "Slave ${slave_ip} prepared successfully"
    done
}

main() {
    if [[ $# -ne 1 ]]; then
        error "Usage: $0 <config_file>"
        exit 1
    fi

    local config_file=$1
    process_slaves "$config_file"
}

main "$@"
