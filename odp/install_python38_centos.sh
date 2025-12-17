#!/usr/bin/env bash
# Install Python 3.8 on CentOS
# Run this script as root
set -euo pipefail

# Install Dependencies:
# Install development tools and dependencies
yum install gcc openssl-devel wget bzip2-devel libffi-devel zlib-devel -y

# ------------------------------------------------------------

#Install SQLite:
# Download SQLite source
cd /opt
wget https://www.sqlite.org/src/tarball/sqlite.tar.gz?r=release --no-check-certificate
mv sqlite.tar.gz?r=release sqlite.tar.gz
tar xzf sqlite.tar.gz

# Navigate to the SQLite directory
cd sqlite/

# Configure SQLite
./configure --prefix=/usr

# Install Tcl (a dependency for SQLite)
sudo yum install tcl -y

# Build and install SQLite
make
sudo make install

# Check SQLite version
sqlite3 --version

# Print the current PATH
echo $PATH

# ------------------------------------------------------------

## install python 3.8
# Change to the /opt directory
cd /opt

# Install required dependencies
sudo yum install gcc openssl-devel bzip2-devel libffi-devel zlib-devel -y

# Download Python 3.8.12 source tarball
curl -O https://www.python.org/ftp/python/3.8.12/Python-3.8.12.tgz

# Extract the tarball
tar -zxvf Python-3.8.12.tgz

# Change into the Python source directory
cd Python-3.8.12/

# Configure the build, enabling shared libraries
./configure --enable-shared

# Build Python
make

# Install Python
sudo make install

# Copy libpython3.8.so to /lib64/
sudo cp --no-clobber ./libpython3.8.so* /lib64/

# Set the correct permissions for libpython3.8.so
sudo chmod 755 /lib64/libpython3.8.so*

# Add the path to the shared libraries to LD_LIBRARY_PATH in .bashrc
echo 'export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:/usr/local/lib/"' >> ~/.bashrc

# Reload .bashrc to apply changes
source ~/.bashrc

# Create a symbolic link from /usr/local/bin/python3.8 to /usr/bin/python3.8
sudo ln -s /usr/local/bin/python3.8 /usr/bin/python3.8

# Set permissions for the Python library directory
sudo chmod -R 755 /usr/local/lib/python3.8

# Check Python and SQLite versions
python3.8 --version
sqlite3 --version

# Run ldconfig to update the system library cache
sudo ldconfig

# Check the SQLite version using Python 3.8
python3.8 -c "import sqlite3; print(sqlite3.sqlite_version)"

# Install additional development tools
sudo yum -y groupinstall "Development Tools"
