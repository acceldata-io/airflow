#!/usr/bin/env bash
# Install Python 3.11 on various Linux distributions
# Run this script as root
# Supported OS: RHEL 8/9, Ubuntu 20.04/22.04
# This script is idempotent - safe to run multiple times
set -euo pipefail

PYTHON_MAJOR_MINOR="3.11"

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION_ID="${VERSION_ID:-}"
        OS_VERSION_MAJOR=$(echo "$OS_VERSION_ID" | cut -d. -f1)
    elif [ -f /etc/redhat-release ]; then
        OS_ID="rhel"
        OS_VERSION_ID=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
        OS_VERSION_MAJOR="$OS_VERSION_ID"
    else
        echo "ERROR: Unable to detect OS."
        exit 1
    fi
    
    echo "Detected OS: ${OS_ID} ${OS_VERSION_ID}"
}

# Check if Python 3.11 is already installed and working
check_python311() {
    if command -v python${PYTHON_MAJOR_MINOR} &>/dev/null; then
        INSTALLED_PY_VERSION=$(python${PYTHON_MAJOR_MINOR} --version 2>&1 | awk '{print $2}')
        echo "Found Python ${INSTALLED_PY_VERSION}"
        
        # Check if venv module works
        if python${PYTHON_MAJOR_MINOR} -m venv --help &>/dev/null; then
            echo "Python ${PYTHON_MAJOR_MINOR} already installed with working venv module."
            return 0
        else
            echo "Python exists but venv module is not working. Will reinstall."
            return 1
        fi
    fi
    return 1
}

# ============================================================
# RHEL 8/9 Installation (via yum/dnf)
# ============================================================
install_python311_rhel() {
    echo "Installing Python 3.11 on RHEL ${OS_VERSION_MAJOR} (via package manager)..."
    
    # Install Python 3.11
    echo "Installing Python 3.11..."
    yum install -y python3.11 python3.11-devel python3.11-pip || dnf install -y python3.11 python3.11-devel python3.11-pip
    
    echo "Python 3.11 installation complete via package manager."
}

# ============================================================
# Ubuntu 20.04/22.04 Installation (via deadsnakes PPA)
# ============================================================
install_python311_ubuntu() {
    echo "Installing Python 3.11 on Ubuntu ${OS_VERSION_ID} (via deadsnakes PPA)..."
    
    # Update apt
    echo "Updating package lists..."
    apt update -y
    
    # Install software-properties-common for add-apt-repository
    apt install -y software-properties-common
    
    # Add deadsnakes PPA
    echo "Adding deadsnakes PPA..."
    add-apt-repository -y ppa:deadsnakes/ppa
    
    # Update after adding PPA
    apt update -y
    
    # Install Python 3.11 and related packages
    echo "Installing Python 3.11..."
    apt install -y python3.11 python3.11-venv python3.11-dev
    
    # Install distutils (needed for some packages)
    apt install -y python3.11-distutils || true
    
    # Ensure pip is available for Python 3.11
    if ! python3.11 -m pip --version &>/dev/null; then
        echo "Installing pip for Python 3.11..."
        curl -sS https://bootstrap.pypa.io/get-pip.py | python3.11
    fi
    
    echo "Python 3.11 installation complete via deadsnakes PPA."
}

# ============================================================
# Main Installation Logic
# ============================================================

echo "============================================"
echo "Python ${PYTHON_MAJOR_MINOR} Installation Script"
echo "============================================"

detect_os

# Check if Python 3.11 is already properly installed
if check_python311; then
    echo "Python 3.11 is already installed and working. Skipping installation."
else
    # Install based on detected OS
    case "${OS_ID}" in
        rhel|centos|rocky|almalinux)
            if [ "${OS_VERSION_MAJOR}" = "8" ] || [ "${OS_VERSION_MAJOR}" = "9" ]; then
                install_python311_rhel
            else
                echo "ERROR: ${OS_ID} ${OS_VERSION_MAJOR} is not supported for Python 3.11"
                echo "Use RHEL/CentOS 8 or 9, or Ubuntu 20/22"
                exit 1
            fi
            ;;
        fedora)
            install_python311_rhel
            ;;
        ubuntu)
            if [[ "${OS_VERSION_MAJOR}" =~ ^(20|22|24)$ ]]; then
                install_python311_ubuntu
            else
                echo "WARNING: Ubuntu ${OS_VERSION_ID} may not be fully supported."
                install_python311_ubuntu
            fi
            ;;
        debian)
            echo "Detected Debian - using Ubuntu installation method"
            install_python311_ubuntu
            ;;
        *)
            echo "ERROR: Unsupported OS: ${OS_ID}"
            echo "Supported: RHEL/CentOS 8/9, Rocky, AlmaLinux, Ubuntu 20/22, Debian"
            exit 1
            ;;
    esac
fi

# ============================================================
# Verification
# ============================================================
echo ""
echo "============================================"
echo "Installation Verification"
echo "============================================"

echo "Python version:"
python${PYTHON_MAJOR_MINOR} --version

echo "Python location:"
which python${PYTHON_MAJOR_MINOR}

# Verify venv works
echo "Checking venv module:"
python${PYTHON_MAJOR_MINOR} -m venv --help &>/dev/null && echo "venv module: OK" || echo "WARNING: venv module not working"

# Verify pip works
echo "Checking pip:"
python${PYTHON_MAJOR_MINOR} -m pip --version || echo "WARNING: pip not working"

echo ""
echo "============================================"
echo "Python 3.11 Installation complete!"
echo "============================================"
