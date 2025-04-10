#!/bin/bash

# setup_ssh.sh - Configure SSH access from master to slaves

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

    if ! sudo systemctl is-active --quiet ssh; then
        sudo systemctl enable --now ssh || {
            error "Failed to start SSH service"
            exit 1
        }
    fi
}

# Generate master key if not exists
generate_master_key() {
    local key_path="$HOME/.ssh/id_rsa"

    if [[ ! -f "$key_path" ]]; then
        info "Generating SSH key pair on master..."
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        ssh-keygen -t rsa -b 4096 -N "" -f "$key_path" >/dev/null || {
            error "Failed to generate SSH key"
            exit 1
        }
        success "Master SSH key generated at $key_path"
    else
        info "Using existing master SSH key at $key_path"
    fi
}

# Transfer common.sh to slave node
transfer_common() {
    local slave_ip=$1
    local slave_user=$2
    local slave_pass=$3

    info "Transferring common.sh to ${slave_user}@${slave_ip}"

    if ! sshpass -p "$slave_pass" scp -o StrictHostKeyChecking=no \
        "${SCRIPT_DIR}/../lib/common.sh" \
        "${slave_user}@${slave_ip}:/tmp/common.sh"; then
        error "Failed to transfer common.sh to ${slave_ip}"
        return 1
    fi

    # Set proper permissions on slave node
    sshpass -p "$slave_pass" ssh -o StrictHostKeyChecking=no "$slave_user@$slave_ip" \
        "chmod +x /tmp/common.sh"
}

# Install packages on slave node
install_slave_packages() {
    local slave_ip=$1
    local slave_user=$2
    local slave_pass=$3

    info "Installing packages on ${slave_ip}"

    sshpass -p "$slave_pass" ssh -o StrictHostKeyChecking=no "$slave_user@$slave_ip" \
        "source /tmp/common.sh && \
        install_package openssh-server && \
        install_package openssh-client && \
        sudo systemctl enable --now ssh" || {
        error "Failed to install packages on ${slave_ip}"
        return 1
    }
}

# Configure slave SSH access
configure_slave_ssh() {
    local slave_ip=$1
    local slave_user=$2
    local slave_pass=$3

    info "Configuring SSH on ${slave_ip}"

    # Create SSH directory and keys
    sshpass -p "$slave_pass" ssh -o StrictHostKeyChecking=no "$slave_user@$slave_ip" \
        "mkdir -p ~/.ssh && \
        chmod 700 ~/.ssh && \
        [ -f ~/.ssh/id_rsa ] || ssh-keygen -t rsa -b 4096 -N '' -f ~/.ssh/id_rsa >/dev/null && \
        grep -qF '$(cat ~/.ssh/id_rsa.pub)' ~/.ssh/authorized_keys 2>/dev/null || \
        cat >> ~/.ssh/authorized_keys && \
        chmod 600 ~/.ssh/authorized_keys" <~/.ssh/id_rsa.pub || {
        error "Failed to configure SSH keys on ${slave_ip}"
        return 1
    }

    # Configure passwordless sudo
    sshpass -p "$slave_pass" ssh -o StrictHostKeyChecking=no "$slave_user@$slave_ip" \
        "echo '$slave_user ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/${slave_user}-nopasswd >/dev/null && \
        sudo chmod 440 /etc/sudoers.d/${slave_user}-nopasswd" || {
        error "Failed to configure sudo on ${slave_ip}"
        return 1
    }
}

# Setup individual slave node
setup_slave_node() {
    local slave_ip=$1
    local slave_user=$2
    local slave_pass=$3

    info "Processing slave node ${slave_user}@${slave_ip}"

    transfer_common "$slave_ip" "$slave_user" "$slave_pass"
    install_slave_packages "$slave_ip" "$slave_user" "$slave_pass"
    configure_slave_ssh "$slave_ip" "$slave_user" "$slave_pass"

    # Verify SSH access
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$slave_user@$slave_ip" exit; then
        error "SSH verification failed for ${slave_ip}"
        return 1
    fi

    success "Slave node ${slave_ip} configured successfully"
}

# Setup all slave nodes from configuration file
setup_all_slaves() {
    local config_file="$1"

    local slave_count=$(jq '.slaves | length' "$config_file")
    for ((i = 0; i < slave_count; i++)); do
        local slave_user=$(jq -r ".slaves[$i].username" "$config_file")
        local slave_host=$(jq -r ".slaves[$i].ip" "$config_file")
        local slave_pass=$(jq -r ".slaves[$i].password" "$config_file")

        setup_slave_node "$slave_host" "$slave_user" "$slave_pass"
    done
}

main() {
    require_sudo

    if [[ $# -ne 1 ]]; then
        error "Usage: $0 <config_file>"
        exit 1
    fi

    local config_file="$1"

    info "Starting SSH configuration from master node"

    setup_master_ssh
    generate_master_key

    setup_all_slaves "$config_file"

    success "SSH configuration completed successfully"
    info "Master can now access all slaves without password"
}

main "$@"
