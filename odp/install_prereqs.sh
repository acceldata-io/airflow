#!/usr/bin/env bash
# Install prerequisites for Apache Airflow
# Run this script as root

set -euo pipefail

# Fix CentOS 7 repository URLs (only needed for CentOS 7)
if [ -f /etc/os-release ]; then
    source /etc/os-release
    if [ "$ID" = "centos" ] && [ "$VERSION_ID" = "7" ]; then
        echo "Detected CentOS 7, fixing repository URLs..."
        sed -i 's/mirror.centos.org/vault.centos.org/g' /etc/yum.repos.d/*.repo
        sed -i 's/^#.*baseurl=http/baseurl=http/g' /etc/yum.repos.d/*.repo
        sed -i 's/^mirrorlist=http/#mirrorlist=http/g' /etc/yum.repos.d/*.repo
        
        echo "Installing devtoolset-8 for newer GCC (required for gssapi, krb5)..."
        yum install -y centos-release-scl || true
        # Fix SCL repo URLs too
        sed -i 's/mirror.centos.org/vault.centos.org/g' /etc/yum.repos.d/CentOS-SCLo-scl*.repo 2>/dev/null || true
        sed -i 's/^#.*baseurl=http/baseurl=http/g' /etc/yum.repos.d/CentOS-SCLo-scl*.repo 2>/dev/null || true
        sed -i 's/^mirrorlist=http/#mirrorlist=http/g' /etc/yum.repos.d/CentOS-SCLo-scl*.repo 2>/dev/null || true
        yum install -y devtoolset-8-gcc devtoolset-8-gcc-c++ || true
    fi
fi

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

echo "Prerequisites installation complete!"
