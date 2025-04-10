#!/bin/bash

set -euo pipefail

# Load common functions
source ./lib/common.sh

if [[ $# -ne 1 ]]; then
    error "Usage: $0 <config_file>"
    exit 1
fi

local config_file=$1

# Validate config first
log "Validating configuration..."
./scripts/0_validate_config.sh "$config_file"

# Setup SSH
log "Setting up SSH keys..."
./scripts/1_setup_ssh.sh "$config_file"

# Install master
log "Installing master node..."
./scripts/2_install_master.sh "$config_file"

# Install slaves
log "Installing slave nodes..."
./scripts/3_install_slave.sh "$config_file"

# Configure services
log "Configuring cluster services..."
./scripts/4_configure_services.sh "$config_file"

# Verify
log "Verifying cluster..."
./scripts/5_verify_cluster.sh "$config_file"

log "Cluster setup completed successfully!"