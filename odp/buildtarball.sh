#!/usr/bin/env bash
# Build Apache Airflow tarball for ODP
# This script handles the complete build process:
#   1. Install prerequisites (system dependencies)
#   2. Install Python 3.8 (based on OS)
#   3. Create virtual environment and build tarball
set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
PY=python3.8
PY_VERSION=3.8
AIRFLOW_VERSION=2.8.1

# Read ODP version from VERSION file
VERSION_FILE="${SCRIPT_DIR}/VERSION"
if [ ! -f "${VERSION_FILE}" ]; then
    echo "ERROR: VERSION file not found at ${VERSION_FILE}"
    exit 1
fi
ODP_VERSION=$(cat "${VERSION_FILE}" | tr -d '[:space:]')

# Combined version for tarball naming
ODP_AIRFLOW_VERSION="${AIRFLOW_VERSION}-${ODP_VERSION}"
ODP_AIRFLOW_VERSION_UNDERSCORE="${ODP_AIRFLOW_VERSION//./_}"
ODP_AIRFLOW_VERSION_UNDERSCORE="${ODP_AIRFLOW_VERSION_UNDERSCORE//-/_}"

CONSTRAINTS_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PY_VERSION}.txt"
REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"
LOCAL_CONSTRAINTS="${SCRIPT_DIR}/constraints-local.txt"
TARBALL_NAME="airflow_environment_${ODP_AIRFLOW_VERSION_UNDERSCORE}.tar.gz"

echo "============================================"
echo "Airflow Tarball Builder"
echo "Airflow Version: ${AIRFLOW_VERSION}"
echo "ODP Version: ${ODP_VERSION}"
echo "Combined Version: ${ODP_AIRFLOW_VERSION}"
echo "Tarball: ${TARBALL_NAME}"
echo "============================================"

# Verify requirements.txt exists
if [ ! -f "${REQUIREMENTS_FILE}" ]; then
    echo "ERROR: requirements.txt not found at ${REQUIREMENTS_FILE}"
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


# Step 2: Install Python 3.8
echo ""
echo "[Step 2] Installing Python 3.8"


PYTHON_SCRIPT="${SCRIPT_DIR}/install_python38.sh"
if [ -f "${PYTHON_SCRIPT}" ]; then
    echo "Running install_python38.sh..."
    chmod +x "${PYTHON_SCRIPT}"
    bash "${PYTHON_SCRIPT}"
else
    echo "ERROR: install_python38.sh not found at ${PYTHON_SCRIPT}"
    exit 1
fi

# Verify Python 3.8 is available
if ! command -v ${PY} &>/dev/null; then
    echo "ERROR: ${PY} is not available after installation"
    exit 1
fi

echo "Python 3.8 is ready: $(${PY} --version)"

# Step 3: Build Tarball
echo ""
echo "[Step 3] Building Airflow Tarball"

# Download and modify constraints file
echo "Downloading constraints file..."
curl -sL "${CONSTRAINTS_URL}" -o "${LOCAL_CONSTRAINTS}"

echo "Modifying constraints file..."
# Remove mysqlclient (we use PyMySQL instead)
sed -i '/^mysqlclient/d' "${LOCAL_CONSTRAINTS}"

# Remove packages that we explicitly pin in requirements.txt (our versions take precedence)
sed -i '/^aiofiles/d' "${LOCAL_CONSTRAINTS}"
sed -i '/^cachetools/d' "${LOCAL_CONSTRAINTS}"
sed -i '/^distlib/d' "${LOCAL_CONSTRAINTS}"
sed -i '/^filelock/d' "${LOCAL_CONSTRAINTS}"
sed -i '/^google-auth/d' "${LOCAL_CONSTRAINTS}"
sed -i '/^kubernetes/d' "${LOCAL_CONSTRAINTS}"
sed -i '/^kubernetes-asyncio/d' "${LOCAL_CONSTRAINTS}"
sed -i '/^lxml/d' "${LOCAL_CONSTRAINTS}"
sed -i '/^platformdirs/d' "${LOCAL_CONSTRAINTS}"
sed -i '/^requests-oauthlib/d' "${LOCAL_CONSTRAINTS}"
sed -i '/^websocket-client/d' "${LOCAL_CONSTRAINTS}"
sed -i '/^xmlsec/d' "${LOCAL_CONSTRAINTS}"
sed -i '/^apache-airflow-providers-cncf-kubernetes/d' "${LOCAL_CONSTRAINTS}"

# Set C99 mode for compiling C extensions (required for gssapi, krb5)
export CFLAGS="-std=gnu99"
export CXXFLAGS="-std=gnu99"
echo "CFLAGS set to: ${CFLAGS}"

echo "Creating virtual environment with ${PY}..."
$PY -m venv airflow

echo "Activating virtual environment..."
source airflow/bin/activate

echo "Upgrading pip..."
pip install --upgrade pip

echo "Installing requirements with modified constraints..."
pip install -r "${REQUIREMENTS_FILE}" --constraint "${LOCAL_CONSTRAINTS}"

# Generate BUILD_INFO manifest inside venv (so it's included in tarball)
BUILD_INFO_FILE="airflow/BUILD_INFO"
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
BUILD_DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
BUILD_OS=${BUILD_OS}
PYTHON_VERSION=${PYTHON_FULL_VERSION}
EOF

echo "BUILD_INFO contents:"
cat "${BUILD_INFO_FILE}"

echo "Packing environment..."
venv-pack -o "${TARBALL_NAME}"

deactivate

echo "============================================"
echo "Successfully created ${TARBALL_NAME}"
echo "============================================"
