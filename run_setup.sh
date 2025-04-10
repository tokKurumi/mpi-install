#!/bin/bash

set -euo pipefail

# Load common functions
source ./lib/common.sh

require_sudo

if [[ $# -ne 1 ]]; then
    error "Usage: $0 <config_file>"
    exit 1
fi

config_file=$1

# Validate config first
info "Validating configuration..."
bash ./scripts/validate_config.sh "$config_file"

# Setup SSH
info "Setting up SSH keys..."
bash ./scripts/setup_ssh.sh "$config_file"

# Configure master
info "Configurring master node..."
bash ./scripts/configure_master.sh "$config_file"

# Configure slaves
info "Installing slave nodes..."
bash ./scripts/configure_slave.sh "$config_file"

# Running & verifying services
info "Running and verifying cluster services..."
bash ./scripts/run_services.sh "$config_file"

success "Cluster setup completed successfully!"
