#!/usr/bin/env bash
# Install Python on various Linux distributions
# Run this script as root
# Usage: ./install_python.sh [3.11|3.12]   (default: 3.12)
# Supported OS: RHEL 8/9, Ubuntu 20.04/22.04
# This script is idempotent - safe to run multiple times
set -euo pipefail

# The ODP 3.3.6 line only ships python3.11 and python3.12 interpreters, so the
# tarball must be built against one of those.
SUPPORTED_PYTHON_VERSIONS=("3.11" "3.12")
PYTHON_MAJOR_MINOR="${1:-${ODP_PY_VERSION:-3.12}}"

version_supported=false
for candidate in "${SUPPORTED_PYTHON_VERSIONS[@]}"; do
    if [ "${candidate}" = "${PYTHON_MAJOR_MINOR}" ]; then
        version_supported=true
        break
    fi
done

if [ "${version_supported}" != true ]; then
    echo "ERROR: Unsupported Python version '${PYTHON_MAJOR_MINOR}'."
    echo "       Supported on the ODP 3.3.6 line: ${SUPPORTED_PYTHON_VERSIONS[*]}"
    exit 1
fi

PY="python${PYTHON_MAJOR_MINOR}"

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

# Check if the requested Python is already installed and working
check_python() {
    if command -v "${PY}" &>/dev/null; then
        INSTALLED_PY_VERSION=$(${PY} --version 2>&1 | awk '{print $2}')
        echo "Found Python ${INSTALLED_PY_VERSION}"

        # Check if venv module works
        if ${PY} -m venv --help &>/dev/null; then
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
install_python_rhel() {
    echo "Installing Python ${PYTHON_MAJOR_MINOR} on RHEL ${OS_VERSION_MAJOR} (via package manager)..."

    yum install -y "${PY}" "${PY}-devel" "${PY}-pip" ||
        dnf install -y "${PY}" "${PY}-devel" "${PY}-pip"

    echo "Python ${PYTHON_MAJOR_MINOR} installation complete via package manager."
}

# ============================================================
# Ubuntu 20.04/22.04 Installation (via deadsnakes PPA)
# ============================================================
install_python_ubuntu() {
    echo "Installing Python ${PYTHON_MAJOR_MINOR} on Ubuntu ${OS_VERSION_ID} (via deadsnakes PPA)..."

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

    # Install Python and related packages
    echo "Installing Python ${PYTHON_MAJOR_MINOR}..."
    apt install -y "${PY}" "${PY}-venv" "${PY}-dev"

    # Install distutils (needed for some packages)
    apt install -y "${PY}-distutils" || true

    # Ensure pip is available
    if ! ${PY} -m pip --version &>/dev/null; then
        echo "Installing pip for Python ${PYTHON_MAJOR_MINOR}..."
        curl -sS https://bootstrap.pypa.io/get-pip.py | ${PY}
    fi

    echo "Python ${PYTHON_MAJOR_MINOR} installation complete via deadsnakes PPA."
}

# ============================================================
# Main Installation Logic
# ============================================================

echo "============================================"
echo "Python ${PYTHON_MAJOR_MINOR} Installation Script"
echo "============================================"

detect_os

# Check if the requested Python is already properly installed
if check_python; then
    echo "Python ${PYTHON_MAJOR_MINOR} is already installed and working. Skipping installation."
else
    # Install based on detected OS
    case "${OS_ID}" in
        rhel|centos|rocky|almalinux)
            if [ "${OS_VERSION_MAJOR}" = "8" ] || [ "${OS_VERSION_MAJOR}" = "9" ]; then
                install_python_rhel
            else
                echo "ERROR: ${OS_ID} ${OS_VERSION_MAJOR} is not supported for Python ${PYTHON_MAJOR_MINOR}"
                echo "Use RHEL/CentOS 8 or 9, or Ubuntu 20/22"
                exit 1
            fi
            ;;
        fedora)
            install_python_rhel
            ;;
        ubuntu)
            if [[ "${OS_VERSION_MAJOR}" =~ ^(20|22|24)$ ]]; then
                install_python_ubuntu
            else
                echo "WARNING: Ubuntu ${OS_VERSION_ID} may not be fully supported."
                install_python_ubuntu
            fi
            ;;
        debian)
            echo "Detected Debian - using Ubuntu installation method"
            install_python_ubuntu
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
${PY} --version

echo "Python location:"
which "${PY}"

# Verify venv works
echo "Checking venv module:"
${PY} -m venv --help &>/dev/null && echo "venv module: OK" || echo "WARNING: venv module not working"

# Verify pip works
echo "Checking pip:"
${PY} -m pip --version || echo "WARNING: pip not working"

echo ""
echo "============================================"
echo "Python ${PYTHON_MAJOR_MINOR} Installation complete!"
echo "============================================"
