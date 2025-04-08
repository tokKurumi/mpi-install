#!/bin/bash

# configure_services.sh - Final cluster configuration and services startup

set -euo pipefail

# Load common functions
SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/../lib/common.sh"

# Distribute Munge key to slaves
distribute_munge_key() {
    local config_file=$1

    info "Distributing Munge key to slave nodes..."

    local slave_ips=($(jq -r '.slaves[].ip' "$config_file"))
    local slave_users=($(jq -r '.slaves[].username' "$config_file"))

    for ((i = 0; i < ${#slave_ips[@]}; i++)); do
        local slave_ip="${slave_ips[i]}"
        local slave_user="${slave_users[i]}"

        info "Copying Munge key to ${slave_user}@${slave_ip}"
        if ! scp "/etc/munge/munge.key" "${slave_user}@${slave_ip}:/tmp/munge.key"; then
            error "Failed to copy Munge key to ${slave_ip}"
            return 1
        fi

        ssh "${slave_user}@${slave_ip}" "
            sudo mv /tmp/munge.key /etc/munge/munge.key && \
            sudo chown munge:munge /etc/munge/munge.key && \
            sudo chmod 400 /etc/munge/munge.key
        " || {
            error "Failed to set Munge key permissions on ${slave_ip}"
            return 1
        }
    done
}

# Distribute Slurm configuration
distribute_slurm_config() {
    local config_file=$1

    info "Distributing Slurm configuration to slave nodes..."

    local slave_ips=($(jq -r '.slaves[].ip' "$config_file"))
    local slave_users=($(jq -r '.slaves[].username' "$config_file"))

    for ((i = 0; i < ${#slave_ips[@]}; i++)); do
        local slave_ip="${slave_ips[i]}"
        local slave_user="${slave_users[i]}"

        info "Copying slurm.conf to ${slave_user}@${slave_ip}"
        if ! scp "/etc/slurm/slurm.conf" "${slave_user}@${slave_ip}:/tmp/slurm.conf"; then
            error "Failed to copy slurm.conf to ${slave_ip}"
            return 1
        fi

        ssh "${slave_user}@${slave_ip}" "
            sudo mv /tmp/slurm.conf /etc/slurm/slurm.conf && \
            sudo chown slurm:slurm /etc/slurm/slurm.conf && \
            sudo chmod 644 /etc/slurm/slurm.conf
        " || {
            error "Failed to set slurm.conf permissions on ${slave_ip}"
            return 1
        }
    done
}

# Restart services in proper order
restart_services() {
    local config_file=$1

    info "Restarting services in correct order..."

    local master_ip=$(jq -r '.master.ip' "$config_file")
    local slave_ips=($(jq -r '.slaves[].ip' "$config_file"))
    local slave_users=($(jq -r '.slaves[].username' "$config_file"))

    # 1. Restart Munge on all nodes first
    info "Restarting Munge on all nodes..."

    # Master node
    sudo systemctl restart munge || {
        error "Failed to restart Munge on master"
        return 1
    }

    # Slave nodes
    for ((i = 0; i < ${#slave_ips[@]}; i++)); do
        local slave_ip="${slave_ips[i]}"
        local slave_user="${slave_users[i]}"

        ssh "${slave_user}@${slave_ip}" "sudo systemctl restart munge" || {
            error "Failed to restart Munge on ${slave_ip}"
            return 1
        }
    done

    # 2. Restart slurmctld on master
    info "Restarting slurmctld on master..."
    sudo systemctl restart slurmctld || {
        error "Failed to restart slurmctld"
        return 1
    }

    # 3. Restart slurmd on all slaves
    info "Restarting slurmd on slave nodes..."
    for ((i = 0; i < ${#slave_ips[@]}; i++)); do
        local slave_ip="${slave_ips[i]}"
        local slave_user="${slave_users[i]}"

        ssh "${slave_user}@${slave_ip}" "sudo systemctl restart slurmd" || {
            error "Failed to restart slurmd on ${slave_ip}"
            return 1
        }
    done
}

# Verify cluster status
verify_cluster() {
    info "Verifying cluster status..."

    # Check master services
    if ! systemctl is-active --quiet munge || ! systemctl is-active --quiet slurmctld; then
        error "Master services are not running"
        return 1
    fi

    # Check slave services via sinfo
    if ! command -v sinfo >/dev/null; then
        error "sinfo command not found"
        return 1
    fi

    local nodes_expected=$(($(jq '.slaves | length' "$1") + 1))
    local nodes_active=$(sinfo -h -o "%A" | awk -F'/' '{print $2}')

    if [ "$nodes_active" -ne "$nodes_expected" ]; then
        error "Cluster verification failed: expected $nodes_expected nodes, found $nodes_active"
        return 1
    fi

    success "Cluster is healthy with $nodes_active/$nodes_expected nodes active"
}

main() {
    require_sudo

    if [[ $# -ne 1 ]]; then
        error "Usage: $0 <config_file>"
        exit 1
    fi

    local config_file=$1

    info "Starting final cluster configuration"

    distribute_munge_key "$config_file"
    distribute_slurm_config "$config_file"
    restart_services "$config_file"
    verify_cluster "$config_file"

    success "Cluster configuration completed successfully"
    info "Slurm cluster is now ready for use"
}

main "$@"
