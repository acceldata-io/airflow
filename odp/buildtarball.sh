#!/usr/bin/env bash
# Build Apache Airflow tarball for ODP
set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
PY=python3.11
PY_VERSION=3.11
AIRFLOW_VERSION=2.8.3
AIRFLOW_VERSION_UNDERSCORE="${AIRFLOW_VERSION//./_}"
CONSTRAINTS_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PY_VERSION}.txt"
REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"
LOCAL_CONSTRAINTS="${SCRIPT_DIR}/constraints-local.txt"
TARBALL_NAME="airflow_environment_${AIRFLOW_VERSION_UNDERSCORE}.tar.gz"

echo "============================================"
echo "Airflow ${AIRFLOW_VERSION} Tarball Builder"
echo "============================================"

# Verify requirements.txt exists
if [ ! -f "${REQUIREMENTS_FILE}" ]; then
    echo "ERROR: requirements.txt not found at ${REQUIREMENTS_FILE}"
    exit 1
fi

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
sed -i '/^platformdirs/d' "${LOCAL_CONSTRAINTS}"
sed -i '/^requests-oauthlib/d' "${LOCAL_CONSTRAINTS}"
sed -i '/^websocket-client/d' "${LOCAL_CONSTRAINTS}"
sed -i '/^apache-airflow-providers-cncf-kubernetes/d' "${LOCAL_CONSTRAINTS}"

# Remove google-re2 constraint to allow fresh build with re2-devel
sed -i '/^google-re2/d' "${LOCAL_CONSTRAINTS}"

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

# Reinstall google-re2 to ensure it compiles against system re2-devel
echo "Reinstalling google-re2 with system re2 library..."
pip uninstall -y google-re2 || true
pip install google-re2 --force-reinstall --no-cache-dir

echo "Packing environment..."
venv-pack -o "${TARBALL_NAME}"

deactivate

echo "============================================"
echo "Successfully created ${TARBALL_NAME}"
echo "============================================"
