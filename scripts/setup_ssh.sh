#!/bin/bash

# 1_setup_ssh.sh - Configure SSH access from master to slaves
# MUST be executed ONLY on master node

set -euo pipefail

# Load common functions
SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/../lib/common.sh"

# Install SSH packages on master
setup_master_ssh() {
    info "Installing SSH dependencies on master..."
    install_package "openssh-server"
    install_package "sshpass"
    install_package "openssh-client"
    sudo systemctl enable --now ssh
}

# Generate master key if not exists
generate_master_key() {
    local key_path="$HOME/.ssh/id_rsa"

    if [[ ! -f "$key_path" ]]; then
        info "Generating SSH key pair on master..."
        ssh-keygen -t rsa -b 4096 -N "" -f "$key_path" >/dev/null
        success "Master SSH key generated at $key_path"
    else
        info "Using existing master SSH key at $key_path"
    fi
}

# Distribute master key to slaves
setup_slaves_ssh() {
    local config_file="$1"
    local slave_count=$(jq '.slaves | length' "$config_file")

    for ((i = 0; i < slave_count; i++)); do
        local slave_user=$(jq -r ".slaves[$i].username" "$config_file")
        local slave_host=$(jq -r ".slaves[$i].ip" "$config_file")
        local slave_pass=$(jq -r ".slaves[$i].password" "$config_file")

        info "Configuring slave $slave_host..."

        # Install SSH packages on slave
        echo "$slave_pass" | sshpass -p "$slave_pass" ssh -o StrictHostKeyChecking=no "$slave_user@$slave_host" \
            "sudo -S apt-get update && sudo -S apt-get install -y openssh-server openssh-client"

        # Generate slave key and add master's pubkey
        sshpass -p "$slave_pass" ssh "$slave_user@$slave_host" \
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
            ssh-keygen -t rsa -b 4096 -N '' -f ~/.ssh/id_rsa >/dev/null && \
            echo '$(cat ~/.ssh/id_rsa.pub)' >> ~/.ssh/authorized_keys && \
            chmod 600 ~/.ssh/authorized_keys"

        # Enable passwordless sudo for ssh commands
        echo "$slave_pass" | sshpass -p "$slave_pass" ssh -o StrictHostKeyChecking=no "$slave_user@$slave_host" \
            "echo '$slave_user ALL=(ALL) NOPASSWD:ALL' | sudo -S tee /etc/sudoers.d/$slave_user-nopasswd && \
            sudo -S chmod 440 /etc/sudoers.d/$slave_user-nopasswd"

        # Copy master's key to slave
        sshpass -p "$slave_pass" ssh-copy-id -f -i ~/.ssh/id_rsa.pub "$slave_user@$slave_host"

        success "Slave $slave_host configured"
    done
}

verify_ssh_access() {
    local config_file="$1"
    local slave_count=$(jq '.slaves | length' "$config_file")

    for ((i = 0; i < slave_count; i++)); do
        local slave_user=$(jq -r ".slaves[$i].username" "$config_file")
        local slave_host=$(jq -r ".slaves[$i].ip" "$config_file")

        info "Verifying SSH access to $slave_host..."
        if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$slave_user@$slave_host" exit; then
            error "Failed to connect to slave $slave_host"
            exit 1
        fi
        success "SSH access to $slave_host verified"
    done
}

main() {
    if [[ $# -ne 1 ]]; then
        error "Usage: $0 <config_file>"
        exit 1
    fi

    local config_file="$1"

    info "Starting SSH configuration from master node"
    setup_master_ssh
    generate_master_key
    setup_slaves_ssh "$config_file"
    verify_ssh_access "$config_file"

    success "SSH configuration completed. Master can now access all slaves without password"
}

main "$@"
