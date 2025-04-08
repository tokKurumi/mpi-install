#!/bin/bash

set -e

# Function to install packages if not already installed
install_if_missing() {
    if ! command -v "$1" &>/dev/null; then
        echo "Installing $1..."
        sudo apt update && sudo apt install -y "$1"
    fi
}

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# Check if a JSON file or config file is provided
if [ $# -ne 1 ]; then
    echo "Usage: $0 <path-to-json-file>"
    exit 1
fi

# Install necessary packages
install_if_missing jq
install_if_missing sshpass
install_if_missing openmpi-bin
install_if_missing openmpi-common
install_if_missing openmpi-doc
install_if_missing libopenmpi-dev
install_if_missing slurm-wlm
install_if_missing munge

json_file=$1

# Extract master node details
master_username=$(jq -r '.master.username' "$json_file")
master_ip=$(jq -r '.master.ip' "$json_file")
master_password=$(jq -r '.master.password' "$json_file")
cluster_name=$(jq -r '.master.cluster_name' "$json_file")
slurmctld_port=$(jq -r '.master.slurmctld_port' "$json_file")
slurmd_port=$(jq -r '.master.slurmd_port' "$json_file")

# Install master node user and setup SSH keys
if ! id "$master_username" &>/dev/null; then
    sudo adduser --disabled-password --gecos "" "$master_username"
    echo "$master_username:$master_password" | sudo chpasswd
fi

echo "$master_ip slots=2" >/home/$master_username/mpi_hosts

su - "$master_username" -c "ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa"
su - "$master_username" -c "cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys"
su - "$master_username" -c "eval \$(ssh-agent -s) && ssh-add ~/.ssh/id_rsa"
su - "$master_username" -c "chmod 600 ~/.ssh/authorized_keys"

echo "Master node was configured with username $master_username."

# Ensure SSH keys are generated
if [ ! -f "/home/$master_username/.ssh/id_rsa" ]; then
    echo "Error: SSH-keys are not found in /home/$master_username/.ssh/id_rsa"
    echo "Consider executing the script again to generate them."
    exit 1
fi

# Add users and distribute SSH keys to the slaves
jq -c '.slaves[]' "$json_file" | while read -r user; do
    USERNAME=$(echo "$user" | jq -r '.username')
    IP=$(echo "$user" | jq -r '.ip')
    PASSWORD=$(echo "$user" | jq -r '.password')

    echo "Adding SSH-key for $USERNAME@$IP"

    sshpass -p "$PASSWORD" ssh-copy-id -i "/home/$master_username/.ssh/id_rsa.pub" -o StrictHostKeyChecking=no "$USERNAME@$IP"

    echo "SSH-key was added for $USERNAME@$IP"
done

# Munge setup
systemctl enable --now munge
for i in {1..10}; do
    if systemctl is-active --quiet munge; then
        echo "munge is active."
        break
    fi
    echo "Attempt $i: munge is not active yet..."
    sleep 1
    if [ "$i" -eq 10 ]; then
        echo "Error: munge service did not become active after 10 seconds." >&2
        exit 1
    fi
done

# Generate munge.key and distribute to all slaves
munge_key_path="/etc/munge/munge.key"
if [ ! -f "$munge_key_path" ]; then
    echo "Generating new munge.key..."
    /usr/sbin/create-munge-key
    chown munge:munge "$munge_key_path"
    chmod 400 "$munge_key_path"
fi

# Copy munge.key to all slaves and restart munge there
jq -c '.slaves[]' "$json_file" | while read -r slave; do
    SLAVE_USER=$(echo "$slave" | jq -r '.username')
    SLAVE_IP=$(echo "$slave" | jq -r '.ip')
    SLAVE_PASS=$(echo "$slave" | jq -r '.password')

    echo "Copying munge.key to $SLAVE_USER@$SLAVE_IP..."

    sshpass -p "$SLAVE_PASS" scp -o StrictHostKeyChecking=no "$munge_key_path" "$SLAVE_USER@$SLAVE_IP:/tmp/munge.key"
    sshpass -p "$SLAVE_PASS" ssh -o StrictHostKeyChecking=no "$SLAVE_USER@$SLAVE_IP" "
        sudo mv /tmp/munge.key /etc/munge/munge.key && \
        sudo chown munge:munge /etc/munge/munge.key && \
        sudo chmod 400 /etc/munge/munge.key && \
        sudo systemctl enable --now munge && \
        for i in {1..10}; do
            if systemctl is-active --quiet munge; then
                echo 'munge is active on slave $SLAVE_IP'
                break
            fi
            echo "Attempt $i: munge is not active yet on $SLAVE_IP..."
            sleep 1
            if [ "$i" -eq 10 ]; then
                echo "Error: munge service did not become active after 10 seconds." >&2
                exit 1
            fi
        done
    "
done

echo "[SUCCESS] Master and slaves are configured with synchronized munge.key"

# SLURM Configuration
echo "Configuring SLURM..."

# Create Slurm config file
slurm_conf="/etc/slurm-llnl/slurm.conf"

# Write SLURM config file
echo "
# Basic SLURM configuration for cluster '$cluster_name'

ClusterName=$cluster_name
SlurmdPort=$slurmd_port
SlurmctldPort=$slurmctld_port

# Nodes configuration
NodeName=master NodeAddr=$master_ip CPUs=2 Sockets=1 CoresPerSocket=2 ThreadsPerCore=1 State=UNKNOWN
PartitionName=debug Nodes=master Default=YES MaxTime=INFINITE State=UP
" | sudo tee "$slurm_conf"

# Start SLURM services
echo "Starting SLURM control daemon and node daemons..."
sudo systemctl enable --now slurmctld
sudo systemctl enable --now slurmd

echo "[SUCCESS] SLURM is configured and running."