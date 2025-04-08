#!/bin/bash

# install_master.sh - Master node installation script for Slurm+Munge cluster

set -euo pipefail

# Load common functions
SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/../lib/common.sh"

# Validate and load configuration
load_config() {
    local config_file=$1

    if [[ ! -f "$config_file" ]]; then
        error "Configuration file not found: $config_file"
        exit 1
    fi

    # Export configuration variables
    export CLUSTER_NAME=$(jq -r '.master.cluster_name' "$config_file")
    export MASTER_IP=$(jq -r '.master.ip' "$config_file")
    export SLURMCTLD_PORT=$(jq -r '.master.slurmctld_port' "$config_file")
    export SLURMD_PORT=$(jq -r '.master.slurmd_port' "$config_file")

    # Get all slave IPs as array
    mapfile -t SLAVE_IPS < <(jq -r '.slaves[].ip' "$config_file")
    mapfile -t SLAVE_NAMES < <(jq -r '.slaves[].username' "$config_file")
}

# Install required packages
install_dependencies() {
    info "Installing required packages on master node..."

    install_package "slurm-wlm"
    install_package "slurmctld"
    install_package "slurmd"
    install_package "munge"
    install_package "jq"
    install_package "sshpass"
}

# Generate Munge key
setup_munge() {
    info "Configuring Munge authentication..."

    local munge_key="/etc/munge/munge.key"

    if [[ ! -f "$munge_key" ]]; then
        info "Generating new Munge key..."
        sudo dd if=/dev/urandom bs=1 count=1024 >"$munge_key" 2>/dev/null
        sudo chown munge:munge "$munge_key"
        sudo chmod 0400 "$munge_key"
        success "Munge key generated"
    else
        info "Using existing Munge key"
    fi
}

# Generate Slurm configuration
setup_slurm_config() {
    info "Generating Slurm configuration..."

    local config_file="/etc/slurm/slurm.conf"
    local backup_file="${config_file}.bak.$(date +%Y%m%d%H%M%S)"

    # Create backup if config exists
    if [[ -f "$config_file" ]]; then
        sudo cp "$config_file" "$backup_file"
        info "Existing slurm.conf backed up to $backup_file"
    fi

    # Generate node list
    local node_list=""
    for ((i = 0; i < ${#SLAVE_IPS[@]}; i++)); do
        node_list+="NodeName=slave$((i + 1)) NodeAddr=${SLAVE_IPS[i]} Port=${SLURMD_PORT} State=UNKNOWN\n"
    done

    # Generate slurm.conf
    cat <<EOF | sudo tee "$config_file" >/dev/null
# Slurm configuration generated automatically
ClusterName="$CLUSTER_NAME"
ControlMachine=$(hostname -s)
ControlAddr=$MASTER_IP
SlurmUser=slurm
SlurmctldPort=$SLURMCTLD_PORT
SlurmdPort=$SLURMD_PORT
AuthType=auth/munge
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd
SwitchType=switch/none
MpiDefault=none
SlurmctldPidFile=/var/run/slurmctld.pid
SlurmdPidFile=/var/run/slurmd.pid
ProctrackType=proctrack/cgroup
CacheGroups=0
ReturnToService=1
SlurmctldTimeout=300
SlurmdTimeout=300
InactiveLimit=0
MinJobAge=300
KillWait=30
Waittime=0

# Node configuration
$node_list
PartitionName=debug Nodes=ALL Default=YES MaxTime=INFINITE State=UP
EOF

    success "Slurm configuration generated at $config_file"
}

# Enable and start services
enable_services() {
    info "Enabling Slurm and Munge services..."

    sudo systemctl enable munge >/dev/null 2>&1
    sudo systemctl enable slurmctld >/dev/null 2>&1

    success "Services enabled (will start after slave configuration)"
}

main() {
    require_sudo

    if [[ $# -ne 1 ]]; then
        error "Usage: $0 <config_file>"
        exit 1
    fi

    local config_file=$1

    info "Starting master node installation"
    load_config "$config_file"
    install_dependencies
    setup_munge
    setup_slurm_config
    enable_services

    success "Master node installation completed successfully"
    info "Note: Services will be started after slave nodes configuration"
}

main "$@"
