#!/bin/bash

set -euo pipefail

# Load configuration and common functions
CONFIG_FILE="config.json"
source ./lib/common.sh

# Validate config first
log "Validating configuration..."
./scripts/0_validate_config.sh "$CONFIG_FILE"

# Setup SSH
log "Setting up SSH keys..."
./scripts/1_setup_ssh.sh "$CONFIG_FILE"

# Install master
log "Installing master node..."
./scripts/2_install_master.sh "$CONFIG_FILE"

# Install slaves
log "Installing slave nodes..."
./scripts/3_install_slave.sh "$CONFIG_FILE"

# Configure services
log "Configuring cluster services..."
./scripts/4_configure_services.sh "$CONFIG_FILE"

# Verify
log "Verifying cluster..."
./scripts/5_verify_cluster.sh "$CONFIG_FILE"

log "Cluster setup completed successfully!"