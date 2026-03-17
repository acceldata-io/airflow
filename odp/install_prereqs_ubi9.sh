#!/usr/bin/env bash
# Install prerequisites for Apache Airflow
# Run this script as root
# Supported OS: RHEL/CentOS/Rocky/AlmaLinux 8+, Ubuntu 20.04/22.04, UBI 9
# NOTE: CentOS 7 is NOT supported for Python 3.11 tarball builds.

set -euo pipefail

# -----------------------------
# Detect OS
# -----------------------------
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

# -----------------------------
# Check if running in UBI container
# -----------------------------
is_ubi_container() {
    [[ -f /etc/os-release ]] && grep -q "platform:el9" /etc/os-release 2>/dev/null && \
    command -v microdnf >/dev/null 2>&1
}

# -----------------------------
# Install packages missing from UBI 9 repos (from AlmaLinux)
# -----------------------------
install_ubi9_missing_packages() {
    echo "============================================"
    echo "Installing packages missing from UBI 9 repos (from AlmaLinux)..."
    echo "============================================"

    # Ensure dnf is available for dependency resolution
    if ! command -v dnf >/dev/null 2>&1; then
        echo "Installing dnf for better package management..."
        microdnf install -y dnf || true
    fi

    # Check if xmlsec1-devel is missing
    if ! rpm -q xmlsec1-devel &>/dev/null; then
        echo "Downloading xmlsec1-devel from AlmaLinux..."
        curl -sLO https://repo.almalinux.org/almalinux/9/CRB/x86_64/os/Packages/xmlsec1-devel-1.2.29-13.el9.x86_64.rpm
        if [ -s xmlsec1-devel-1.2.29-13.el9.x86_64.rpm ]; then
            dnf install -y ./xmlsec1-devel-1.2.29-13.el9.x86_64.rpm || true
            rm -f xmlsec1-devel-*.rpm
        else
            echo "WARNING: Failed to download xmlsec1-devel"
        fi
    else
        echo "xmlsec1-devel already installed"
    fi

    # Check if libtool-ltdl-devel is missing
    if ! rpm -q libtool-ltdl-devel &>/dev/null; then
        echo "Downloading libtool-ltdl-devel from AlmaLinux..."
        curl -sLO https://repo.almalinux.org/almalinux/9/CRB/x86_64/os/Packages/libtool-ltdl-devel-2.4.6-46.el9.x86_64.rpm
        if [ -s libtool-ltdl-devel-2.4.6-46.el9.x86_64.rpm ]; then
            dnf install -y ./libtool-ltdl-devel-2.4.6-46.el9.x86_64.rpm || true
            rm -f libtool-ltdl-devel-*.rpm
        else
            echo "WARNING: Failed to download libtool-ltdl-devel"
        fi
    else
        echo "libtool-ltdl-devel already installed"
    fi

    # Check if readline-devel is missing
    if ! rpm -q readline-devel &>/dev/null; then
        echo "Downloading readline-devel from AlmaLinux..."
        curl -sLO https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/Packages/readline-devel-8.1-4.el9.x86_64.rpm
        if [ -s readline-devel-8.1-4.el9.x86_64.rpm ]; then
            dnf install -y ./readline-devel-8.1-4.el9.x86_64.rpm || true
            rm -f readline-devel-*.rpm
        else
            echo "WARNING: Failed to download readline-devel"
        fi
    else
        echo "readline-devel already installed"
    fi

    # Check if re2-devel is missing
    if ! rpm -q re2-devel &>/dev/null; then
        echo "Downloading re2 and re2-devel from EPEL..."
        curl -sLO https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/Packages/r/re2-20211101-20.el9.x86_64.rpm
        curl -sLO https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/Packages/r/re2-devel-20211101-20.el9.x86_64.rpm
        if [ -s re2-20211101-20.el9.x86_64.rpm ] && [ -s re2-devel-20211101-20.el9.x86_64.rpm ]; then
            dnf install -y ./re2-20211101-20.el9.x86_64.rpm ./re2-devel-20211101-20.el9.x86_64.rpm || true
            rm -f re2-*.rpm
        else
            echo "WARNING: Failed to download re2-devel"
        fi
    else
        echo "re2-devel already installed"
    fi
}

# -----------------------------
# RHEL / UBI prereqs
# -----------------------------
install_rhel_prereqs() {
    # Detect package manager
    if command -v microdnf >/dev/null 2>&1; then
        PKG=microdnf
        echo "Detected RHEL-like OS - using microdnf"
    elif command -v dnf >/dev/null 2>&1; then
        PKG=dnf
        echo "Detected RHEL-like OS - using dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG=yum
        echo "Detected RHEL-like OS - using yum"
    else
        echo "ERROR: No supported package manager found (microdnf/dnf/yum)"
        exit 1
    fi

    echo "Installing build tools..."
    $PKG install -y \
        gcc gcc-c++ make pkg-config || true

    echo "Installing XML and XMLSEC dependencies..."
    $PKG install -y \
        libxml2 libxml2-devel \
        xmlsec1 xmlsec1-devel xmlsec1-openssl || true

    echo "Installing libtool dependencies..."
    $PKG install -y libtool-ltdl libtool-ltdl-devel || true

    echo "Installing ODBC dependencies..."
    $PKG install -y unixODBC unixODBC-devel || true

    echo "Installing Kerberos dependencies..."
    $PKG install -y krb5-devel krb5-libs || true

    echo "Installing LDAP and SASL dependencies..."
    $PKG install -y openldap-devel cyrus-sasl-devel || true

    echo "Installing SSL dependencies..."
    $PKG install -y openssl-devel || true

    echo "Installing PostgreSQL dependencies..."
    $PKG install -y libpq libpq-devel || true
    # Fallback for older systems
    $PKG install -y postgresql-devel || true

    echo "Installing libffi dependencies..."
    $PKG install -y libffi-devel || true

    echo "Installing zlib dependencies..."
    $PKG install -y zlib-devel || true

    echo "Installing bzip2 dependencies..."
    $PKG install -y bzip2-devel || true

    echo "Installing readline dependencies..."
    $PKG install -y readline-devel || true

    echo "Installing sqlite dependencies..."
    $PKG install -y sqlite-devel || true

    echo "Installing xz dependencies..."
    $PKG install -y xz-devel || true

    # For UBI 9 containers, install missing packages from AlmaLinux
    if is_ubi_container; then
        install_ubi9_missing_packages
    fi

    # Cleanup for minimal images
    if [ "$PKG" = "microdnf" ]; then
        microdnf clean all || true
    fi
}

# -----------------------------
# Ubuntu / Debian prereqs
# -----------------------------
install_ubuntu_prereqs() {
    echo "Detected Ubuntu/Debian ${OS_VERSION_ID} - using apt"

    echo "Updating package lists..."
    apt-get update -y

    echo "Installing build tools..."
    apt-get install -y build-essential pkg-config || true

    echo "Installing XML and XMLSEC dependencies..."
    apt-get install -y \
        libxml2 libxml2-dev \
        xmlsec1 libxmlsec1-dev libxmlsec1-openssl || true

    echo "Installing libtool dependencies..."
    apt-get install -y libltdl-dev || true

    echo "Installing ODBC dependencies..."
    apt-get install -y unixodbc unixodbc-dev || true

    echo "Installing Kerberos dependencies..."
    apt-get install -y libkrb5-dev krb5-config || true

    echo "Installing LDAP and SASL dependencies..."
    apt-get install -y libldap2-dev libsasl2-dev || true

    echo "Installing SSL dependencies..."
    apt-get install -y libssl-dev || true

    echo "Installing PostgreSQL dependencies..."
    apt-get install -y libpq-dev || true

    echo "Installing libffi dependencies..."
    apt-get install -y libffi-dev || true

    echo "Installing zlib dependencies..."
    apt-get install -y zlib1g-dev || true

    echo "Installing bzip2 dependencies..."
    apt-get install -y libbz2-dev || true

    echo "Installing readline dependencies..."
    apt-get install -y libreadline-dev || true

    echo "Installing sqlite dependencies..."
    apt-get install -y libsqlite3-dev || true

    echo "Installing xz dependencies..."
    apt-get install -y liblzma-dev || true

    echo "Installing curl dependencies..."
    apt-get install -y curl libcurl4-openssl-dev || true
}

# -----------------------------
# Main
# -----------------------------
detect_os

echo "============================================"
echo "Installing Airflow Prerequisites"
echo "Detected OS: ${OS_ID} ${OS_VERSION_ID}"
echo "============================================"

case "${OS_ID}" in
    rhel|centos|rocky|almalinux|fedora)
        install_rhel_prereqs
        ;;
    ubuntu|debian)
        install_ubuntu_prereqs
        ;;
    *)
        echo "ERROR: Unsupported OS: ${OS_ID}"
        echo "Supported: RHEL/CentOS/Rocky/AlmaLinux, Ubuntu/Debian"
        exit 1
        ;;
esac

echo "============================================"
echo "Prerequisites installation complete!"
echo "============================================"
