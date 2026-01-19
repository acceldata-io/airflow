#!/usr/bin/env bash
# Install prerequisites for Apache Airflow
# Run this script as root
# Supported OS: RHEL/CentOS 8+, Ubuntu 20.04/22.04
# NOTE: CentOS 7 is NOT supported for Python 3.11 tarball builds.
#       For CentOS 7 / Python 3.8 builds, use the -2 branch.

set -euo pipefail

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
detect_os

echo "============================================"
echo "Installing Airflow Prerequisites"
echo "Detected OS: ${OS_ID} ${OS_VERSION_ID}"
echo "============================================"

case "${OS_ID}" in
    rhel|centos|rocky|almalinux|fedora)
        install_rhel_prereqs
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
