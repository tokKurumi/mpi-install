#!/bin/bash

# configure_master.sh - Master node installation script for Slurm+Munge cluster

set -euo pipefail

# Load common functions
SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/../lib/common.sh"

# Install required packages
install_dependencies() {
    info "Installing required packages on master node..."

    install_package "slurm-wlm"
    install_package "slurmctld"
    install_package "slurmd"
    install_package "munge"
    install_package "jq"
}

# Generate Munge key
setup_munge() {
    info "Configuring Munge authentication..."

    local munge_dir="/etc/munge"
    local munge_key="${munge_dir}/munge.key"

    sudo mkdir -p "$munge_dir"
    sudo chown munge:munge "$munge_dir"
    sudo chmod 711 "$munge_dir"

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
    local config_file=$1

    info "Generating Slurm configuration..."

    # Read configuration values
    local cluster_name=$(jq -r '.master.cluster_name' "$config_file")
    local master_ip=$(jq -r '.master.ip' "$config_file")
    local slurmctld_port=$(jq -r '.master.slurmctld_port' "$config_file")
    local slurmd_port=$(jq -r '.master.slurmd_port' "$config_file")
    local slave_ips=($(jq -r '.slaves[].ip' "$config_file"))

    local slurm_conf="/etc/slurm/slurm.conf"
    local backup_file="${slurm_conf}.bak.$(date +%Y%m%d%H%M%S)"

    # Create backup if config exists
    if [[ -f "$slurm_conf" ]]; then
        sudo cp "$slurm_conf" "$backup_file"
        info "Existing slurm.conf backed up to $backup_file"
    fi

    # Generate node list
    local node_list=""
    for ((i = 0; i < ${#slave_ips[@]}; i++)); do
        node_list+="NodeName=slave$((i + 1)) NodeAddr=${slave_ips[i]} Port=${slurmd_port} State=UNKNOWN\n"
    done

    # Generate slurm.conf
    cat <<EOF | sudo tee "$slurm_conf" >/dev/null
# Slurm configuration generated automatically
ClusterName="${cluster_name}"
ControlMachine=$(hostname -s)
ControlAddr=${master_ip}
SlurmUser=slurm
SlurmctldPort=${slurmctld_port}
SlurmdPort=${slurmd_port}
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
${node_list}
PartitionName=debug Nodes=ALL Default=YES MaxTime=INFINITE State=UP
EOF

    success "Slurm configuration generated at $slurm_conf"
}

# Enable and start services
enable_services() {
    local config_file=$1

    info "Enabling Slurm and Munge services..."

    sudo systemctl enable munge >/dev/null 2>&1 || {
        error "Failed to enable munge service"
        return 1
    }

    sudo systemctl enable slurmctld >/dev/null 2>&1 || {
        error "Failed to enable slurmctld service"
        return 1
    }

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

    install_dependencies
    setup_munge
    setup_slurm_config "$config_file"
    enable_services "$config_file"

    success "Master node installation completed successfully"
    info "Note: Services will be started after slave nodes configuration"
}

main "$@"
