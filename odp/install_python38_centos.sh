#!/usr/bin/env bash
# Install Python 3.8 on CentOS
# Run this script as root
# This script is idempotent - safe to run multiple times
set -euo pipefail

# Version configuration
SQLITE_MIN_VERSION="3.31.0"
PYTHON_VERSION="3.8.12"
PYTHON_MAJOR_MINOR="3.8"

# Helper function to compare versions
version_gte() {
    # Returns 0 (true) if $1 >= $2
    [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

echo "============================================"
echo "Python ${PYTHON_VERSION} Installation Script"
echo "============================================"

# ------------------------------------------------------------
# Step 1: Install base dependencies
# ------------------------------------------------------------
echo ""
echo "[Step 1] Checking base dependencies..."

DEPS_TO_INSTALL=""
for pkg in gcc wget bzip2-devel libffi-devel zlib-devel openssl-devel tcl; do
    if ! rpm -q "$pkg" &>/dev/null && ! rpm -q "${pkg}-devel" &>/dev/null; then
        DEPS_TO_INSTALL="$DEPS_TO_INSTALL $pkg"
    fi
done

if [ -n "$DEPS_TO_INSTALL" ]; then
    echo "Installing missing dependencies:$DEPS_TO_INSTALL"
    yum install -y $DEPS_TO_INSTALL
else
    echo "All base dependencies already installed. Skipping."
fi

# ------------------------------------------------------------
# Step 2: Install SQLite (if needed)
# ------------------------------------------------------------
echo ""
echo "[Step 2] Checking SQLite installation..."

SQLITE_INSTALLED=false
SQLITE_VERSION=""

# Check if sqlite3 exists and get version
if command -v sqlite3 &>/dev/null; then
    SQLITE_VERSION=$(sqlite3 --version | awk '{print $1}')
    if version_gte "$SQLITE_VERSION" "$SQLITE_MIN_VERSION"; then
        SQLITE_INSTALLED=true
    fi
fi

# Also check for sqlite3 header (needed for Python compilation)
SQLITE_HEADER_EXISTS=false
if [ -f /usr/include/sqlite3.h ] || [ -f /usr/local/include/sqlite3.h ]; then
    SQLITE_HEADER_EXISTS=true
fi

if [ "$SQLITE_INSTALLED" = true ] && [ "$SQLITE_HEADER_EXISTS" = true ]; then
    echo "SQLite ${SQLITE_VERSION} already installed with headers. Skipping."
else
    echo "Installing SQLite from source..."
    
    cd /opt
    
    # Download only if not already downloaded
    if [ ! -f sqlite.tar.gz ]; then
        echo "Downloading SQLite source..."
        wget https://www.sqlite.org/src/tarball/sqlite.tar.gz?r=release --no-check-certificate -O sqlite.tar.gz
    else
        echo "SQLite source already downloaded."
    fi
    
    # Extract and build
    if [ ! -d sqlite ]; then
        tar xzf sqlite.tar.gz
    fi
    
    cd sqlite/
    
    # Configure and build
    ./configure --prefix=/usr
    make
    sudo make install
    
    # Update library cache
    sudo ldconfig
    
    echo "SQLite installation complete."
fi

# Verify SQLite
echo "SQLite version: $(sqlite3 --version)"

# ------------------------------------------------------------
# Step 3: Install Python 3.8 (if needed)
# ------------------------------------------------------------
echo ""
echo "[Step 3] Checking Python ${PYTHON_MAJOR_MINOR} installation..."

PYTHON_INSTALLED=false
PYTHON_SQLITE_OK=false

# Check if python3.8 exists
if command -v python${PYTHON_MAJOR_MINOR} &>/dev/null; then
    INSTALLED_PY_VERSION=$(python${PYTHON_MAJOR_MINOR} --version 2>&1 | awk '{print $2}')
    echo "Found Python ${INSTALLED_PY_VERSION}"
    
    # Check if sqlite3 module works
    if python${PYTHON_MAJOR_MINOR} -c "import sqlite3; print(sqlite3.sqlite_version)" &>/dev/null; then
        PYTHON_SQLITE_OK=true
        PYTHON_INSTALLED=true
    else
        echo "Python exists but sqlite3 module is broken. Will rebuild."
    fi
fi

if [ "$PYTHON_INSTALLED" = true ] && [ "$PYTHON_SQLITE_OK" = true ]; then
    echo "Python ${PYTHON_MAJOR_MINOR} already installed with working sqlite3 module. Skipping."
else
    echo "Installing Python ${PYTHON_VERSION} from source..."
    
    cd /opt
    
    # Download only if not already downloaded
    if [ ! -f "Python-${PYTHON_VERSION}.tgz" ]; then
        echo "Downloading Python ${PYTHON_VERSION}..."
        curl -O "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz"
    else
        echo "Python source already downloaded."
    fi
    
    # Extract
    if [ ! -d "Python-${PYTHON_VERSION}" ]; then
        tar -zxvf "Python-${PYTHON_VERSION}.tgz"
    fi
    
    cd "Python-${PYTHON_VERSION}/"
    
    # Clean previous build if exists
    if [ -f Makefile ]; then
        echo "Cleaning previous build..."
        make clean || true
    fi
    
    # Set environment variables so Python can find SQLite
    export LDFLAGS="-L/usr/lib -L/usr/lib64"
    export CPPFLAGS="-I/usr/include"
    export LD_RUN_PATH="/usr/lib:/usr/lib64"
    
    # Configure the build
    echo "Configuring Python build..."
    ./configure --enable-shared \
        LDFLAGS="${LDFLAGS}" \
        CPPFLAGS="${CPPFLAGS}"
    
    # Build Python
    echo "Building Python (this may take a while)..."
    make
    
    # Install Python
    echo "Installing Python..."
    sudo make install
    
    # Copy shared library to /lib64/
    if [ -f ./libpython${PYTHON_MAJOR_MINOR}.so ]; then
        sudo cp --no-clobber ./libpython${PYTHON_MAJOR_MINOR}.so* /lib64/ || true
        sudo chmod 755 /lib64/libpython${PYTHON_MAJOR_MINOR}.so* || true
    fi
    
    echo "Python ${PYTHON_VERSION} installation complete."
fi

# ------------------------------------------------------------
# Step 4: Configure system paths and symlinks
# ------------------------------------------------------------
echo ""
echo "[Step 4] Configuring system paths..."

# Create symlink if it doesn't exist
if [ ! -L /usr/bin/python${PYTHON_MAJOR_MINOR} ] && [ ! -f /usr/bin/python${PYTHON_MAJOR_MINOR} ]; then
    if [ -f /usr/local/bin/python${PYTHON_MAJOR_MINOR} ]; then
        echo "Creating symlink /usr/bin/python${PYTHON_MAJOR_MINOR}..."
        sudo ln -s /usr/local/bin/python${PYTHON_MAJOR_MINOR} /usr/bin/python${PYTHON_MAJOR_MINOR}
    fi
else
    echo "Symlink /usr/bin/python${PYTHON_MAJOR_MINOR} already exists. Skipping."
fi

# Set permissions for Python library directory
if [ -d /usr/local/lib/python${PYTHON_MAJOR_MINOR} ]; then
    sudo chmod -R 755 /usr/local/lib/python${PYTHON_MAJOR_MINOR}
fi

# Add LD_LIBRARY_PATH to bashrc if not already present
if ! grep -q "/usr/local/lib/" ~/.bashrc 2>/dev/null; then
    echo "Adding LD_LIBRARY_PATH to ~/.bashrc..."
    echo 'export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:/usr/local/lib/"' >> ~/.bashrc
else
    echo "LD_LIBRARY_PATH already in ~/.bashrc. Skipping."
fi

# Set LD_LIBRARY_PATH for current session
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:/usr/local/lib/"

# Update library cache
sudo ldconfig

# ------------------------------------------------------------
# Step 5: Install Development Tools (if needed)
# ------------------------------------------------------------
echo ""
echo "[Step 5] Checking Development Tools..."

if yum grouplist installed 2>/dev/null | grep -q "Development Tools"; then
    echo "Development Tools already installed. Skipping."
else
    echo "Installing Development Tools..."
    sudo yum -y groupinstall "Development Tools"
fi

# ------------------------------------------------------------
# Verification
# ------------------------------------------------------------
echo ""
echo "============================================"
echo "Installation Verification"
echo "============================================"

echo "Python version:"
python${PYTHON_MAJOR_MINOR} --version

echo "SQLite version (system):"
sqlite3 --version

echo "SQLite version (in Python):"
python${PYTHON_MAJOR_MINOR} -c "import sqlite3; print(sqlite3.sqlite_version)"

echo ""
echo "============================================"
echo "Installation complete!"
echo "============================================"
