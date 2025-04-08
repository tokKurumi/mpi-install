#!/bin/bash

# common.sh - Common functions for cluster setup

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print error messages
function error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Function to print success messages
function success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Function to print info messages
function info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

# Function to check and install package on Ubuntu
# Usage: install_package <package_name>
function install_package() {
    local package=$1

    # Check if package is already installed
    if dpkg -l | grep -q "^ii  $package "; then
        info "Package $package is already installed"
        return 0
    fi

    info "Installing package: $package"

    # Update package list (only once at the beginning would be better)
    if ! sudo apt-get update >/dev/null 2>&1; then
        error "Failed to update package list"
        return 1
    fi

    # Install package
    if ! sudo apt-get install -y "$package" >/dev/null 2>&1; then
        error "Failed to install package $package"
        return 1
    fi

    success "Package $package installed successfully"
    return 0
}

# Function to check if command exists
# Usage: command_exists <command>
function command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to validate JSON configuration file
# Usage: validate_config <config_file>
function validate_config() {
    local config_file=$1

    if ! command_exists jq; then
        install_package jq || {
            error "jq is required but could not be installed"
            return 1
        }
    fi

    if ! jq empty "$config_file" >/dev/null 2>&1; then
        error "Invalid JSON configuration file: $config_file"
        return 1
    fi

    # Add more specific validations as needed
    return 0
}
