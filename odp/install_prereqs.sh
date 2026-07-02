#!/usr/bin/env bash
# Install prerequisites for Apache Airflow
# Run this script as root
# Supported OS: RHEL/CentOS 8+, Ubuntu 20.04/22.04
# NOTE: CentOS 7 is NOT supported for Python 3.11 tarball builds.
#       For CentOS 7 / Python 3.8 builds, use the -2 branch.
# On CentOS 7, install Node.js 18 via unofficial glibc-217 build (for yarn/webpack UI builds).

set -euo pipefail


# Fix CentOS 7 repository URLs (only needed for CentOS 7)
if [ -f /etc/os-release ]; then
    source /etc/os-release
    if [ "$ID" = "centos" ] && [ "$VERSION_ID" = "7" ]; then
        echo "Detected CentOS 7, fixing repository URLs..."
        sed -i 's/mirror.centos.org/vault.centos.org/g' /etc/yum.repos.d/*.repo
        sed -i 's/^#.*baseurl=http/baseurl=http/g' /etc/yum.repos.d/*.repo
        sed -i 's/^mirrorlist=http/#mirrorlist=http/g' /etc/yum.repos.d/*.repo
    fi
fi

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION_ID="${VERSION_ID:-}"
    elif [ -f /etc/redhat-release ]; then
        OS_ID="rhel"
        OS_VERSION_ID=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
    else
        echo "ERROR: Unable to detect OS. Supported: RHEL/CentOS, Ubuntu"
        exit 1
    fi
}

# CentOS 7 ships glibc 2.17; use Node unofficial glibc-217 builds (standard Node 18+ binaries need newer glibc).
install_nodejs18_centos7() {
    local NODE_VERSION="18.20.5"
    local INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
    local name="node-v${NODE_VERSION}-linux-x64-glibc-217"
    local url="https://unofficial-builds.nodejs.org/download/release/v${NODE_VERSION}/${name}.tar.xz"
    local shasums_url="https://unofficial-builds.nodejs.org/download/release/v${NODE_VERSION}/SHASUMS256.txt"

    # nvm is a bash function (not a binary) — it's inherited in interactive shells but NOT
    # in scripts. We must source nvm.sh to load the function, then deactivate it.
    local nvm_sh="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
    if [[ -s "${nvm_sh}" ]]; then
        echo "Loading nvm from ${nvm_sh} and running nvm deactivate"
        # nvm.sh is not set -e safe; temporarily disable errexit while loading it
        set +e
        # shellcheck source=/dev/null
        . "${nvm_sh}"
        nvm deactivate 2>/dev/null
        hash -r 2>/dev/null
        set -e
    fi

    if command -v node >/dev/null 2>&1 && node -v 2>/dev/null | grep -qE '^v(18|20|22)\.'; then
        echo "Node.js $(node -v) already installed; skipping unofficial Node ${NODE_VERSION}."
        return 0
    fi

    echo "Installing Node.js ${NODE_VERSION} (linux-x64-glibc-217) into ${INSTALL_PREFIX}..."
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL -o "${tmp}/node.tar.xz" "${url}"

    echo "Verifying SHA256 checksum..."
    curl -fsSL -o "${tmp}/SHASUMS256.txt" "${shasums_url}"
    local expected_sha256 actual_sha256
    expected_sha256="$(grep "${name}.tar.xz" "${tmp}/SHASUMS256.txt" | awk '{print $1}')"
    if [[ -z "${expected_sha256}" ]]; then
        echo "ERROR: Could not find checksum for ${name}.tar.xz in SHASUMS256.txt"
        rm -rf "${tmp}"
        return 1
    fi
    actual_sha256="$(sha256sum "${tmp}/node.tar.xz" | awk '{print $1}')"
    if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
        echo "ERROR: SHA256 checksum mismatch for Node.js ${NODE_VERSION}"
        echo "  Expected: ${expected_sha256}"
        echo "  Actual:   ${actual_sha256}"
        rm -rf "${tmp}"
        return 1
    fi
    echo "Checksum verified OK."

    local node_dir="${INSTALL_PREFIX}/lib/nodejs/${name}"
    mkdir -p "${node_dir}"
    tar -xf "${tmp}/node.tar.xz" -C "${tmp}"
    cp -r "${tmp}/${name}/"* "${node_dir}/"
    rm -rf "${tmp}"

    mkdir -p "${INSTALL_PREFIX}/bin"
    ln -sf "${node_dir}/bin/node" "${INSTALL_PREFIX}/bin/node"
    ln -sf "${node_dir}/bin/npm"  "${INSTALL_PREFIX}/bin/npm"
    ln -sf "${node_dir}/bin/npx"  "${INSTALL_PREFIX}/bin/npx"

    hash -r 2>/dev/null || true
    echo "Node.js $(node --version) / npm $(npm --version)"
}

install_rhel_prereqs() {
    echo "Detected RHEL/CentOS - using yum package manager"

    echo "Installing XML and XMLSEC dependencies..."
    yum install -y libxml2 libxml2-devel xmlsec1 xmlsec1-devel

    echo "Installing libtool dependencies..."
    yum install -y libtool-ltdl-devel

    echo "Installing ODBC dependencies..."
    yum install -y unixODBC unixODBC-devel

    echo "Installing Kerberos dependencies..."
    yum install -y krb5-devel || true

    echo "Installing LDAP dependencies..."
    yum install -y openldap-devel || true

    echo "Installing PostgreSQL dependencies..."
    yum install -y postgresql-devel || true
}

install_ubuntu_prereqs() {
    echo "Detected Ubuntu ${OS_VERSION_ID} - using apt package manager"

    # Update package lists
    echo "Updating package lists..."
    apt-get update -y

    echo "Installing XML and XMLSEC dependencies..."
    apt-get install -y libxml2 libxml2-dev xmlsec1 libxmlsec1-dev libxmlsec1-openssl

    echo "Installing libtool dependencies..."
    apt-get install -y libltdl-dev

    echo "Installing ODBC dependencies..."
    apt-get install -y unixodbc unixodbc-dev

    echo "Installing Kerberos dependencies..."
    apt-get install -y libkrb5-dev krb5-config || true

    echo "Installing LDAP and SASL dependencies..."
    apt-get install -y libldap2-dev libsasl2-dev || true

    echo "Installing SSL dependencies..."
    apt-get install -y libssl-dev || true

    echo "Installing PostgreSQL dependencies..."
    apt-get install -y libpq-dev || true

    echo "Installing additional build dependencies..."
    apt-get install -y build-essential pkg-config || true
}

# Main

# Check for UBI9 first - if detected, use the dedicated UBI9 script
if [ -f /etc/yum.repos.d/ubi.repo ]; then
    echo "============================================"
    echo "Detected UBI9 (Red Hat Universal Base Image 9)"
    echo "Running dedicated UBI9 prerequisites script..."
    echo "============================================"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec bash "${SCRIPT_DIR}/install_prereqs_ubi9.sh"
fi

detect_os

echo "============================================"
echo "Installing Airflow Prerequisites"
echo "Detected OS: ${OS_ID} ${OS_VERSION_ID}"
echo "============================================"

case "${OS_ID}" in
    rhel|centos|rocky|almalinux|fedora)
        install_rhel_prereqs
        if [ "${OS_ID}" = "centos" ] && [ "${OS_VERSION_ID%%.*}" = "7" ]; then
            install_nodejs18_centos7
        fi
        ;;
    ubuntu)
        if [[ "${OS_VERSION_ID}" =~ ^(20|22) ]]; then
            install_ubuntu_prereqs
        else
            echo "WARNING: Ubuntu ${OS_VERSION_ID} is not officially tested. Proceeding anyway..."
            install_ubuntu_prereqs
        fi
        ;;
    debian)
        echo "Detected Debian - using Ubuntu installation steps"
        install_ubuntu_prereqs
        ;;
    *)
        echo "ERROR: Unsupported OS: ${OS_ID}"
        echo "Supported: RHEL/CentOS/Rocky/AlmaLinux, Ubuntu 20.04/22.04/24.04, Debian"
        exit 1
        ;;
esac

echo "============================================"
echo "Prerequisites installation complete!"
echo "============================================"
