#!/usr/bin/env bash
# Install prerequisites for Apache Airflow
# Run this script as root

set -euo pipefail

echo "Installing XML and XMLSEC dependencies..."
yum install -y libxml2 libxml2-devel xmlsec1 xmlsec1-devel

echo "Installing libtool dependencies..."
yum install -y libtool-ltdl-devel

echo "Installing ODBC dependencies..."
yum install -y unixODBC unixODBC-devel

echo "Prerequisites installation complete!"

