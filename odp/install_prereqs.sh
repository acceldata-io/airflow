#!/usr/bin/env bash
# Install prerequisites for Apache Airflow
# Run this script as root
# NOTE: CentOS 7 is NOT supported for Python 3.11 tarball builds.
#       For CentOS 7 / Python 3.8 builds, use the -2 branch.

set -euo pipefail

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
