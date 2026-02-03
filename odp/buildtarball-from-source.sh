#!/usr/bin/env bash
# Build Apache Airflow tarball for ODP - FROM LOCAL SOURCE CODE
# This script builds Airflow from the local source code, allowing local patches to be included
set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Airflow source root is one level up from odp/
AIRFLOW_SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Configuration
PY=python3.11
PY_VERSION=3.11

# Read versions from VERSION file (format: AIRFLOW_VERSION.ODP_VERSION, e.g. 2.8.3.3.3.6.3-SNAPSHOT)
ODP_VERSION=$(cat "${SCRIPT_DIR}/VERSION" | tr -d '[:space:]')

# Extract Airflow version from source code
AIRFLOW_VERSION=$(grep -oP '__version__\s*=\s*"\K[^"]+' "${AIRFLOW_SOURCE_ROOT}/airflow/__init__.py")

# Combined version for tarball naming
ODP_AIRFLOW_VERSION="${AIRFLOW_VERSION}.${ODP_VERSION}"
ODP_AIRFLOW_VERSION_UNDERSCORE="${ODP_AIRFLOW_VERSION//./_}"
ODP_AIRFLOW_VERSION_UNDERSCORE="${ODP_AIRFLOW_VERSION_UNDERSCORE//-/_}"

REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements-source.txt"
TARBALL_NAME="airflow_environment_${ODP_AIRFLOW_VERSION_UNDERSCORE}.tar.gz"

echo "============================================"
echo "Airflow Tarball Builder (FROM SOURCE)"
echo "============================================"
echo "Source Directory: ${AIRFLOW_SOURCE_ROOT}"
echo "Airflow Version (from source): ${AIRFLOW_VERSION}"
echo "ODP Version: ${ODP_VERSION}"
echo "Combined Version: ${ODP_AIRFLOW_VERSION}"
echo "Tarball: ${TARBALL_NAME}"
echo "============================================"

# Verify source directory contains pyproject.toml
if [ ! -f "${AIRFLOW_SOURCE_ROOT}/pyproject.toml" ]; then
    echo "ERROR: pyproject.toml not found at ${AIRFLOW_SOURCE_ROOT}"
    echo "This script must be run from within the Airflow source tree"
    exit 1
fi

# Verify requirements file exists
if [ ! -f "${REQUIREMENTS_FILE}" ]; then
    echo "ERROR: requirements-source.txt not found at ${REQUIREMENTS_FILE}"
    echo "Please create requirements-source.txt with additional dependencies"
    exit 1
fi

# Step 1: Install Prerequisites
echo ""
echo "[Step 1] Installing Prerequisites"

PREREQS_SCRIPT="${SCRIPT_DIR}/install_prereqs.sh"
if [ -f "${PREREQS_SCRIPT}" ]; then
    echo "Running install_prereqs.sh..."
    chmod +x "${PREREQS_SCRIPT}"
    bash "${PREREQS_SCRIPT}"
else
    echo "WARNING: install_prereqs.sh not found at ${PREREQS_SCRIPT}"
    echo "Skipping prerequisites installation..."
fi

# Step 2: Install Python 3.11
echo ""
echo "[Step 2] Installing Python 3.11"

PYTHON_SCRIPT="${SCRIPT_DIR}/install_python311.sh"
if [ -f "${PYTHON_SCRIPT}" ]; then
    echo "Running install_python311.sh..."
    chmod +x "${PYTHON_SCRIPT}"
    bash "${PYTHON_SCRIPT}"
else
    echo "ERROR: install_python311.sh not found at ${PYTHON_SCRIPT}"
    exit 1
fi

# Verify Python 3.11 is available
if ! command -v ${PY} &>/dev/null; then
    echo "ERROR: ${PY} is not available after installation"
    exit 1
fi

echo "Python 3.11 is ready: $(${PY} --version)"

# Step 3: Build Tarball from Source
echo ""
echo "[Step 3] Building Airflow Tarball from Source"

# Set C99 mode for compiling C extensions (required for gssapi, krb5)
export CFLAGS="-std=gnu99"
export CXXFLAGS="-std=gnu99"
echo "CFLAGS set to: ${CFLAGS}"

# Create virtual environment
VENV_DIR="${SCRIPT_DIR}/airflow"
echo "Creating virtual environment with ${PY} at ${VENV_DIR}..."
rm -rf "${VENV_DIR}"
$PY -m venv "${VENV_DIR}"

echo "Activating virtual environment..."
source "${VENV_DIR}/bin/activate"

echo "Upgrading pip and installing build tools..."
pip install --upgrade pip setuptools wheel

# Install build dependencies required by hatchling
echo "Installing build dependencies for Airflow..."
pip install \
    "GitPython==3.1.42" \
    "hatchling==1.21.1" \
    "editables==0.5" \
    "gitdb==4.0.11" \
    "packaging==23.2" \
    "pathspec==0.12.1" \
    "pluggy==1.4.0" \
    "smmap==5.0.1" \
    "trove-classifiers==2024.3.3"

# Install Airflow from local source with specific extras
# The extras are similar to what was in the original requirements.txt
echo ""
echo "Installing Airflow from local source with extras..."
echo "Source path: ${AIRFLOW_SOURCE_ROOT}"

# Define the extras we want (same as original requirements.txt but without 'mysql' which pulls mysqlclient)
AIRFLOW_EXTRAS="celery,cncf.kubernetes,ldap,kerberos,statsd,openlineage,postgres,redis,ftp,http,imap,sqlite,async,crypto,password"

# Install Airflow from source with extras
# Using --no-build-isolation to use already installed build dependencies
pip install "${AIRFLOW_SOURCE_ROOT}[${AIRFLOW_EXTRAS}]" --no-build-isolation

# Install additional dependencies from requirements-source.txt
echo ""
echo "Installing additional dependencies from requirements-source.txt..."
pip install -r "${REQUIREMENTS_FILE}"

# Generate BUILD_INFO manifest inside venv (so it's included in tarball)
BUILD_INFO_FILE="${VENV_DIR}/BUILD_INFO"
echo ""
echo "Generating BUILD_INFO manifest..."

# Detect OS for manifest
if [ -f /etc/os-release ]; then
    . /etc/os-release
    BUILD_OS="${ID}-${VERSION_ID}"
else
    BUILD_OS="unknown"
fi

# Get actual Python version
PYTHON_FULL_VERSION=$(${PY} --version 2>&1 | awk '{print $2}')

cat > "${BUILD_INFO_FILE}" <<EOF
AIRFLOW_VERSION=${AIRFLOW_VERSION}
ODP_VERSION=${ODP_VERSION}
ODP_AIRFLOW_VERSION=${ODP_AIRFLOW_VERSION}
BUILD_TYPE=source
BUILD_DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
BUILD_OS=${BUILD_OS}
PYTHON_VERSION=${PYTHON_FULL_VERSION}
EOF

echo "BUILD_INFO contents:"
cat "${BUILD_INFO_FILE}"

# Verify Airflow is installed correctly from source
echo ""
echo "Verifying Airflow installation..."
INSTALLED_VERSION=$(pip show apache-airflow 2>/dev/null | grep "^Version:" | cut -d' ' -f2 || echo "NOT INSTALLED")
echo "Installed Airflow version: ${INSTALLED_VERSION}"

if [ "${INSTALLED_VERSION}" == "NOT INSTALLED" ]; then
    echo "ERROR: Airflow was not installed correctly"
    deactivate
    exit 1
fi

# List installed packages for reference
echo ""
echo "Installed packages:"
pip list

# Pack the environment
echo ""
echo "Packing environment..."
pip install venv-pack
venv-pack -o "${SCRIPT_DIR}/${TARBALL_NAME}"

deactivate

echo ""
echo "============================================"
echo "Successfully created ${TARBALL_NAME}"
echo "Location: ${SCRIPT_DIR}/${TARBALL_NAME}"
echo ""
echo "This tarball was built from LOCAL SOURCE CODE"
echo "Any local patches in ${AIRFLOW_SOURCE_ROOT} are included"
echo "============================================"
