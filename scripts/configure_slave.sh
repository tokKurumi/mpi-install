#!/bin/bash

# configure_slave.sh - Slave nodes configuration

set -euo pipefail

# Load common functions
SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/../lib/common.sh"

# Transfer munge.key to slave node
transfer_munge_key() {
    local slave_ip=$1
    local slave_user=$2
    local slave_pass=$3

    info "Transferring munge.key to ${slave_user}@${slave_ip}"

    local munge_dir="/etc/munge"
    local munge_key="${munge_dir}/munge.key"

    if ! sshpass -p "$slave_pass" scp -o StrictHostKeyChecking=no \
        "$munge_key" \
        "${slave_user}@${slave_ip}:/tmp/munge.key"; then
        error "Failed to transfer munge.key to ${slave_ip}"
        return 1
    fi

    sshpass -p "$slave_pass" ssh -o StrictHostKeyChecking=no "$slave_user@$slave_ip" "
        sudo mkdir -p /etc/munge && \
        sudo mv /tmp/munge.key /etc/munge/munge.key && \
        sudo chown munge:munge /etc/munge/munge.key && \
        sudo chmod 0400 /etc/munge/munge.key
    " || {
        error "Failed to set munge.key permissions on ${slave_ip}"
        return 1
    }
}

# Verify slave environment
verify_slave_environment() {
    local slave_ip=$1
    local slave_user=$2
    local slave_pass=$3

    sshpass -p "$slave_pass" ssh -o StrictHostKeyChecking=no "$slave_user@$slave_ip" '
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
    local slave_pass=$3

    info "Configuring slave node ${slave_ip}"

    sshpass -p "$slave_pass" ssh -o StrictHostKeyChecking=no "$slave_user@$slave_ip" '
    set -euo pipefail
    source /tmp/common.sh

    # 1. Install required packages
    install_package slurmd
    install_package munge
    install_package mpich
    install_package libmpich-dev

    # 2. Setup Slurm directories
    sudo mkdir -p /var/spool/slurmd
    sudo chown slurm:slurm /var/spool/slurmd
    sudo chmod 755 /var/spool/slurmd

    # 3. Validate user existence
    if ! id slurm &>/dev/null; then
        error "slurm user does not exist"
        exit 1
    fi

    if ! id munge &>/dev/null; then
        error "munge user does not exist"
        exit 1
    fi

    # 4. Enable services (without starting)
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
        local slave_pass=$(jq -r ".slaves[$i].password" "$config_file")

        info "Configuring slave $((i + 1))/$slave_count: ${slave_user}@${slave_ip}"

        verify_slave_environment "$slave_ip" "$slave_user" "$slave_pass"
        transfer_munge_key "$slave_ip" "$slave_user" "$slave_pass"
        configure_slave_node "$slave_ip" "$slave_user" "$slave_pass"

        success "Slave ${slave_ip} configured successfully"
    done
}

# Verify master has munge.key
verify_munge_key() {
    local munge_key="/etc/munge/munge.key"
    if [ ! -f "$munge_key" ]; then
        error "Munge key not found on master at $munge_key"
        exit 1
    fi
    
    info "Munge key found at $munge_key"
}

main() {
    if [[ $# -ne 1 ]]; then
        error "Usage: $0 <config_file>"
        exit 1
    fi

    local config_file=$1

    verify_munge_key
    process_slaves "$config_file"

    success "All slave nodes configured"
    info "Note: Services will be started after running run_services.sh"
}

main "$@"
