#!/bin/bash

set -e

# Function to install packages if not already installed
install_if_missing() {
    if ! command -v "$1" &>/dev/null; then
        echo "Installing $1..."
        sudo apt update && sudo apt install -y "$1"
    fi
}

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

json_file=$1

# Extract master node details
master_username=$(jq -r '.master.username' "$json_file")
master_ip=$(jq -r '.master.ip' "$json_file")
master_password=$(jq -r '.master.password' "$json_file")

# Install master node user and setup SSH keys
if ! id "$master_username" &>/dev/null; then
    sudo adduser --disabled-password --gecos "" "$master_username"
    echo "$master_username:$master_password" | sudo chpasswd
fi

echo "$master_ip slots=2" > /home/$master_username/mpi_hosts

su - "$master_username" -c "ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa"
su - "$master_username" -c "cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys"
su - "$master_username" -c "chmod 600 ~/.ssh/authorized_keys"

echo "Master node was configured with username $master_username. Consider adding slaves and checking ssh access to slaves."

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

    sshpass -p "$PASSWORD" ssh-copy-id -o StrictHostKeyChecking=no "$USERNAME@$IP"

    echo "SSH-key was added for $USERNAME@$IP"
done