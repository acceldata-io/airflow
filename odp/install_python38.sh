#!/usr/bin/env bash
# Install Python 3.8 on various Linux distributions
# Run this script as root
# Supported OS: CentOS 7, RHEL 8+, Ubuntu 20.04/22.04
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

# Check if Python 3.8 is already installed and working
check_python38() {
    if command -v python${PYTHON_MAJOR_MINOR} &>/dev/null; then
        INSTALLED_PY_VERSION=$(python${PYTHON_MAJOR_MINOR} --version 2>&1 | awk '{print $2}')
        echo "Found Python ${INSTALLED_PY_VERSION}"
        
        # Check if sqlite3 module works
        if python${PYTHON_MAJOR_MINOR} -c "import sqlite3; print(sqlite3.sqlite_version)" &>/dev/null; then
            echo "Python ${PYTHON_MAJOR_MINOR} already installed with working sqlite3 module."
            return 0
        else
            echo "Python exists but sqlite3 module is broken. Will reinstall."
            return 1
        fi
    fi
    return 1
}

# ============================================================
# CentOS 7 Installation (from source)
# ============================================================
install_python38_centos7() {
    echo "Installing Python 3.8 on CentOS 7 (from source)..."
    
    # Fix CentOS 7 repository URLs
    echo "Fixing CentOS 7 repository URLs..."
    sed -i 's/mirror.centos.org/vault.centos.org/g' /etc/yum.repos.d/*.repo || true
    sed -i 's/^#.*baseurl=http/baseurl=http/g' /etc/yum.repos.d/*.repo || true
    sed -i 's/^mirrorlist=http/#mirrorlist=http/g' /etc/yum.repos.d/*.repo || true

    # Step 1: Install base dependencies
    echo "[Step 1] Installing base dependencies..."
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
        echo "All base dependencies already installed."
    fi

    # Step 2: Install SQLite (if needed)
    echo "[Step 2] Checking SQLite installation..."
    
    SQLITE_INSTALLED=false
    SQLITE_VERSION=""
    
    if command -v sqlite3 &>/dev/null; then
        SQLITE_VERSION=$(sqlite3 --version | awk '{print $1}')
        if version_gte "$SQLITE_VERSION" "$SQLITE_MIN_VERSION"; then
            SQLITE_INSTALLED=true
        fi
    fi
    
    SQLITE_HEADER_EXISTS=false
    if [ -f /usr/include/sqlite3.h ] || [ -f /usr/local/include/sqlite3.h ]; then
        SQLITE_HEADER_EXISTS=true
    fi
    
    if [ "$SQLITE_INSTALLED" = true ] && [ "$SQLITE_HEADER_EXISTS" = true ]; then
        echo "SQLite ${SQLITE_VERSION} already installed with headers."
    else
        echo "Installing SQLite from source..."
        cd /opt
        
        if [ ! -f sqlite.tar.gz ]; then
            echo "Downloading SQLite source..."
            wget https://www.sqlite.org/src/tarball/sqlite.tar.gz?r=release --no-check-certificate -O sqlite.tar.gz
        fi
        
        if [ ! -d sqlite ]; then
            tar xzf sqlite.tar.gz
        fi
        
        cd sqlite/
        ./configure --prefix=/usr
        make
        sudo make install
        sudo ldconfig
        echo "SQLite installation complete."
    fi
    
    echo "SQLite version: $(sqlite3 --version)"

    # Step 3: Install Python 3.8 from source
    echo "[Step 3] Installing Python ${PYTHON_VERSION} from source..."
    
    cd /opt
    
    if [ ! -f "Python-${PYTHON_VERSION}.tgz" ]; then
        echo "Downloading Python ${PYTHON_VERSION}..."
        curl -O "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz"
    fi
    
    if [ ! -d "Python-${PYTHON_VERSION}" ]; then
        tar -zxvf "Python-${PYTHON_VERSION}.tgz"
    fi
    
    cd "Python-${PYTHON_VERSION}/"
    
    if [ -f Makefile ]; then
        echo "Cleaning previous build..."
        make clean || true
    fi
    
    export LDFLAGS="-L/usr/lib -L/usr/lib64"
    export CPPFLAGS="-I/usr/include"
    export LD_RUN_PATH="/usr/lib:/usr/lib64"
    
    echo "Configuring Python build..."
    ./configure --enable-shared \
        LDFLAGS="${LDFLAGS}" \
        CPPFLAGS="${CPPFLAGS}"
    
    echo "Building Python (this may take a while)..."
    make
    
    echo "Installing Python..."
    sudo make install
    
    if [ -f ./libpython${PYTHON_MAJOR_MINOR}.so ]; then
        sudo cp --no-clobber ./libpython${PYTHON_MAJOR_MINOR}.so* /lib64/ || true
        sudo chmod 755 /lib64/libpython${PYTHON_MAJOR_MINOR}.so* || true
    fi

    # Step 4: Configure system paths
    echo "[Step 4] Configuring system paths..."
    
    if [ ! -L /usr/bin/python${PYTHON_MAJOR_MINOR} ] && [ ! -f /usr/bin/python${PYTHON_MAJOR_MINOR} ]; then
        if [ -f /usr/local/bin/python${PYTHON_MAJOR_MINOR} ]; then
            echo "Creating symlink /usr/bin/python${PYTHON_MAJOR_MINOR}..."
            sudo ln -s /usr/local/bin/python${PYTHON_MAJOR_MINOR} /usr/bin/python${PYTHON_MAJOR_MINOR}
        fi
    fi
    
    if [ -d /usr/local/lib/python${PYTHON_MAJOR_MINOR} ]; then
        sudo chmod -R 755 /usr/local/lib/python${PYTHON_MAJOR_MINOR}
    fi
    
    if ! grep -q "/usr/local/lib/" ~/.bashrc 2>/dev/null; then
        echo "Adding LD_LIBRARY_PATH to ~/.bashrc..."
        echo 'export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:/usr/local/lib/"' >> ~/.bashrc
    fi
    
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:/usr/local/lib/"
    sudo ldconfig

    # Step 5: Install Development Tools
    echo "[Step 5] Checking Development Tools..."
    if yum grouplist installed 2>/dev/null | grep -q "Development Tools"; then
        echo "Development Tools already installed."
    else
        echo "Installing Development Tools..."
        sudo yum -y groupinstall "Development Tools"
    fi
}

# ============================================================
# RHEL 8+ Installation (via yum/dnf)
# ============================================================
install_python38_rhel8() {
    echo "Installing Python 3.8 on RHEL/CentOS 8+ (via package manager)..."
    
    # Install Python 3.8
    echo "Installing Python 3.8 via yum..."
    yum install -y python38 python38-devel python38-pip || dnf install -y python38 python38-devel python38-pip
    
    echo "Python 3.8 installation complete via package manager."
}

# ============================================================
# Ubuntu 20.04/22.04 Installation (via deadsnakes PPA)
# ============================================================
install_python38_ubuntu() {
    echo "Installing Python 3.8 on Ubuntu ${OS_VERSION_ID} (via deadsnakes PPA)..."
    
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
    
    # Install Python 3.8 and related packages
    echo "Installing Python 3.8..."
    apt install -y python3.8
    
    echo "Installing Python 3.8 venv..."
    apt install -y python3.8-venv
    
    echo "Installing Python 3.8 dev..."
    apt install -y python3.8-dev
    
    # Install distutils (needed for pip)
    apt install -y python3.8-distutils || true
    
    # Ensure pip is available for Python 3.8
    if ! python3.8 -m pip --version &>/dev/null; then
        echo "Installing pip for Python 3.8..."
        curl -sS https://bootstrap.pypa.io/get-pip.py | python3.8
    fi
    
    echo "Python 3.8 installation complete via deadsnakes PPA."
}

# ============================================================
# Main Installation Logic
# ============================================================

echo "============================================"
echo "Python ${PYTHON_VERSION} Installation Script"
echo "============================================"

detect_os

# Check if Python 3.8 is already properly installed
if check_python38; then
    echo "Python 3.8 is already installed and working. Skipping installation."
else
    # Install based on detected OS
    case "${OS_ID}" in
        centos)
            if [ "${OS_VERSION_MAJOR}" = "7" ]; then
                install_python38_centos7
            else
                # CentOS 8+
                install_python38_rhel8
            fi
            ;;
        rhel|rocky|almalinux)
            if [ "${OS_VERSION_MAJOR}" -ge 8 ]; then
                install_python38_rhel8
            else
                # RHEL 7 - use source installation
                install_python38_centos7
            fi
            ;;
        fedora)
            install_python38_rhel8
            ;;
        ubuntu)
            if [[ "${OS_VERSION_MAJOR}" =~ ^(20|22|24)$ ]]; then
                install_python38_ubuntu
            else
                echo "WARNING: Ubuntu ${OS_VERSION_ID} may not be fully supported."
                install_python38_ubuntu
            fi
            ;;
        debian)
            echo "Detected Debian - using Ubuntu installation method"
            install_python38_ubuntu
            ;;
        *)
            echo "ERROR: Unsupported OS: ${OS_ID}"
            echo "Supported: CentOS 7/8+, RHEL 7/8+, Rocky, AlmaLinux, Ubuntu 20/22/24, Debian"
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

echo "SQLite version (in Python):"
python${PYTHON_MAJOR_MINOR} -c "import sqlite3; print(sqlite3.sqlite_version)" || echo "WARNING: sqlite3 module not working"

# Verify venv works
echo "Checking venv module:"
python${PYTHON_MAJOR_MINOR} -m venv --help &>/dev/null && echo "venv module: OK" || echo "WARNING: venv module not working"

echo ""
echo "============================================"
echo "Python 3.8 Installation complete!"
echo "============================================"
