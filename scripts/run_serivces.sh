#!/bin/bash

# run_services.sh - Final cluster activation and verification

set -euo pipefail

# Load common functions
SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/../lib/common.sh"

# Start services in correct order
start_services() {
    local config_file=$1

    info "Starting services in proper sequence..."

    local master=$(jq -r '.master' "$config_file")
    local master_ip=$(jq -r '.ip' <<<"$master")
    local master_user=$(jq -r '.username' <<<"$master")
    local master_pass=$(jq -r '.password' <<<"$master")

    info "Starting Munge on all nodes..."

    # Start Munge on master
    echo "$master_pass" | sudo -S systemctl restart munge || {
        error "Failed to start Munge on master"
        return 1
    }

    # Start Munge on slaves
    jq -c '.slaves[]' "$config_file" | while read -r slave; do
        local slave_ip=$(jq -r '.ip' <<<"$slave")
        local slave_user=$(jq -r '.username' <<<"$slave")
        local slave_pass=$(jq -r '.password' <<<"$slave")

        sshpass -p "$slave_pass" ssh -o StrictHostKeyChecking=no "${slave_user}@${slave_ip}" \
            "sudo systemctl restart munge" || {
            error "Failed to start Munge on ${slave_ip}"
            return 1
        }
    done

    # Start slurmctld on master
    info "Starting slurmctld on master..."
    echo "$master_pass" | sudo -S systemctl restart slurmctld || {
        error "Failed to start slurmctld"
        return 1
    }

    # Start slurmd on all slaves
    info "Starting slurmd on slave nodes..."
    jq -c '.slaves[]' "$config_file" | while read -r slave; do
        local slave_ip=$(jq -r '.ip' <<<"$slave")
        local slave_user=$(jq -r '.username' <<<"$slave")
        local slave_pass=$(jq -r '.password' <<<"$slave")

        sshpass -p "$slave_pass" ssh -o StrictHostKeyChecking=no "${slave_user}@${slave_ip}" \
            "sudo systemctl restart slurmd" || {
            error "Failed to start slurmd on ${slave_ip}"
            return 1
        }
    done
}

# Verify cluster status
verify_cluster() {
    local config_file=$1

    info "Verifying cluster health..."

    local expected_nodes=$(($(jq '.slaves | length' "$config_file") + 1))
    local retries=5
    local delay=10

    # Check services locally
    if ! systemctl is-active munge slurmctld >/dev/null; then
        error "Critical services not running on master"
        return 1
    fi

    # Check nodes via sinfo
    for ((i = 1; i <= retries; i++)); do
        local active_nodes=$(sinfo -h -o "%D" | awk '{sum += $1} END {print sum}')

        if [[ "$active_nodes" -eq "$expected_nodes" ]]; then
            success "All ${expected_nodes} nodes active and responsive"
            return 0
        fi

        warn "Attempt ${i}/${retries}: ${active_nodes}/${expected_nodes} nodes ready"
        [[ $i -lt $retries ]] && sleep $delay
    done

    error "Cluster verification failed: only ${active_nodes}/${expected_nodes} nodes responsive"
    sinfo -N -o "%N %T" # Show node status
    return 1
}

# Test Slurm with Hello World
test_slurm() {
    local config_file=$1

    info "Running Hello World test across cluster..."

    local output_file="/tmp/slurm_test.out"
    local slave_count=$(jq '.slaves | length' "$config_file")
    local total_nodes=$((slave_count + 1))

    # Create test script
    cat <<-'EOF' >/tmp/hello_world.sh
    #!/bin/bash
    echo "Hello World from $(hostname) (SLURM_NODEID: $SLURM_NODEID)"
    echo "Job ID: $SLURM_JOB_ID"
    echo "CPUs on node: $(nproc)"
    exit 0
	EOF

    chmod +x /tmp/hello_world.sh

    # Distribute to all nodes (master + slaves)
    jq -c '.master, .slaves[]' "$config_file" | while read -r node; do
        local ip=$(jq -r '.ip' <<<"$node")
        local user=$(jq -r '.username' <<<"$node")
        local pass=$(jq -r '.password' <<<"$node")

        sshpass -p "$pass" scp -o StrictHostKeyChecking=no \
            /tmp/hello_world.sh \
            "${user}@${ip}:/tmp/hello_world.sh" || {
            error "Failed to copy test script to ${ip}"
            return 1
        }

        sshpass -p "$pass" ssh -o StrictHostKeyChecking=no "${user}@${ip}" \
            "chmod +x /tmp/hello_world.sh" || {
            error "Failed to set permissions on ${ip}"
            return 1
        }
    done

    # Run test
    if srun -N${total_nodes} -l /tmp/hello_world.sh >"$output_file" 2>&1; then
        success "Cluster test successful. Output:"
        cat "$output_file"
        rm -f /tmp/hello_world.sh "$output_file"
        return 0
    else
        error "Cluster test failed"
        [[ -f "$output_file" ]] && cat "$output_file"
        return 1
    fi
}

main() {
    if [[ $# -ne 1 ]]; then
        error "Usage: $0 <config_file>"
        exit 1
    fi

    local config_file=$1

    info "Starting cluster activation"

    start_services "$config_file"
    verify_cluster "$config_file"
    test_slurm "$config_file"

    success "Cluster is fully operational"
    info "Nodes available: $(sinfo -h -o "%D")"
    info "Try: srun -N${slave_count} hostname"
}

main "$@"
