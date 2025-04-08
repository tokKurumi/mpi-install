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

# Check if a JSON file and user-id are provided
if [ $# -ne 2 ]; then
    echo "Usage: $0 <path-to-json-file> <user-id>"
    exit 1
fi

# Install necessary packages
install_if_missing "jq"
install_if_missing "openmpi-bin"
install_if_missing "openmpi-common"
install_if_missing "openmpi-doc"
install_if_missing "libopenmpi-dev"
install_if_missing munge
install_if_missing slurmd
install_if_missing slurm-client

JSON_FILE="$1"
USER_ID="$2"

# Parse the JSON config file to extract necessary details
USER_CONFIG=$(jq --arg id "$USER_ID" '.slaves[] | select(.id == ($id | tonumber))' "$JSON_FILE")

# Extract username, password, and IP from the selected user
USERNAME=$(echo "$USER_CONFIG" | jq -r '.username')
PASSWORD=$(echo "$USER_CONFIG" | jq -r '.password')
IP=$(echo "$USER_CONFIG" | jq -r '.ip')

# Check if the user exists, if not create the user and set password
if ! id "$USERNAME" &>/dev/null; then
    echo "User $USERNAME does not exist. Creating user..."
    sudo useradd -m -s /bin/bash "$USERNAME"
    echo "$USERNAME:$PASSWORD" | sudo chpasswd
else
    echo "User $USERNAME already exists."
fi

# Setup SSH directory for the user
sudo -u "$USERNAME" bash -c "mkdir -p ~/.ssh"
sudo -u "$USERNAME" bash -c "chmod 700 ~/.ssh"
echo "Slave node was configured. Consider adding master SSH-key for user $USERNAME."

# Prepare Munge directories (master will provide munge.key)
sudo mkdir -p /etc/munge
sudo chown munge:munge /etc/munge
sudo chmod 0700 /etc/munge

# If munge.key already exists, ensure correct permissions
if [ -f /etc/munge/munge.key ]; then
    echo "munge.key already exists, setting permissions..."
    sudo chown munge:munge /etc/munge/munge.key
    sudo chmod 0400 /etc/munge/munge.key
fi

# Prepare Slurm
sudo mkdir -p /etc/slurm
if [ ! -f /etc/slurm/slurm.conf ]; then
    sudo touch /etc/slurm/slurm.conf
fi
sudo chown slurm:slurm /etc/slurm/slurm.conf

# Enable services to auto-start on boot
sudo systemctl enable munge
sudo systemctl enable slurmd

echo "Slave node setup complete. Services will start correctly once master provides configuration:"
echo "- /etc/munge/munge.key"
echo "- /etc/slurm/slurm.conf"