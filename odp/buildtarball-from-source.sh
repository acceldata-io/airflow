#!/usr/bin/env bash
# Build Apache Airflow tarball for ODP - FROM LOCAL SOURCE CODE
# This script builds Airflow from the local source code, allowing local patches to be included
set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Airflow source root is one level up from odp/
AIRFLOW_SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Configuration
PY=python3.14
PY_VERSION=3.14

# Read versions from VERSION file (format: AIRFLOW_VERSION.ODP_VERSION, e.g. 3.2.2.3.4.3.0-1)
ODP_VERSION=$(cat "${SCRIPT_DIR}/VERSION" | tr -d '[:space:]')

# Extract Airflow version from source code
AIRFLOW_VERSION=$(grep -oP '__version__\s*=\s*"\K[^"]+' "${AIRFLOW_SOURCE_ROOT}/airflow-core/src/airflow/__init__.py")

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

# Step 2: Install Python 3.14
echo ""
echo "[Step 2] Installing Python 3.14"

PYTHON_SCRIPT="${SCRIPT_DIR}/install_python314.sh"
if [ -f "${PYTHON_SCRIPT}" ]; then
    echo "Running install_python314.sh..."
    chmod +x "${PYTHON_SCRIPT}"
    bash "${PYTHON_SCRIPT}"
else
    echo "ERROR: install_python314.sh not found at ${PYTHON_SCRIPT}"
    exit 1
fi

# Verify Python 3.14 is available
if ! command -v ${PY} &>/dev/null; then
    echo "ERROR: ${PY} is not available after installation"
    exit 1
fi

echo "Python 3.14 is ready: $(${PY} --version)"

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

echo "Upgrading pip and installing uv..."
# uv is required (not plain pip) so that local-path installs resolve the
# [tool.uv.sources] workspace members (apache-airflow-core, apache-airflow-task-sdk)
# from ${AIRFLOW_SOURCE_ROOT} instead of fetching released versions from PyPI.
pip install --upgrade pip uv

echo "Installing setuptools, wheel, Cython..."
uv pip install setuptools wheel Cython

# Install build dependencies required by hatchling (must match airflow-core/pyproject.toml's
# [build-system] requires, since --no-build-isolation skips pip's own resolution of these)
echo "Installing build dependencies for Airflow..."
uv pip install \
    "GitPython==3.1.50" \
    "gitdb==4.0.12" \
    "hatchling==1.29.0" \
    "packaging==26.2" \
    "pathspec==1.1.1" \
    "pluggy==1.6.0" \
    "smmap==5.0.3" \
    "tomli==2.4.1; python_version < '3.11'" \
    "trove-classifiers==2026.5.20.19"

# hatchling's custom build hook for apache-airflow-core (airflow-core/hatch_build.py) shells
# out to `prek run --stage manual compile-ui-assets --all-files` to build the React/Vite UI
# (airflow-core/src/airflow/ui) as part of the wheel build. prek must be on PATH for this.
echo "Installing prek (required by airflow-core's UI asset build hook)..."
uv pip install prek

# Install Airflow from local source with specific extras
# The extras are similar to what was in the original requirements.txt
echo ""
echo "============================================"
echo "Installing Airflow from LOCAL SOURCE CODE"
echo "Source path: ${AIRFLOW_SOURCE_ROOT}"
echo "Source version: ${AIRFLOW_VERSION}"
echo "pyproject.toml: ${AIRFLOW_SOURCE_ROOT}/pyproject.toml"
echo "============================================"
echo ""
echo "NOTE: You should see 'apache-airflow-core @ file://...' and"
echo "'apache-airflow-task-sdk @ file://...' below (local workspace paths, NOT PyPI downloads)"
echo ""

# Define the extras we want (same as the original requirements.txt, minus 'mysql' which pulls
# mysqlclient, and minus 'crypto'/'password' which no longer exist as extras on apache-airflow==3.2.2:
# cryptography is now a core apache-airflow-core dependency, and there is no 'password' extra)
AIRFLOW_EXTRAS="celery,cncf.kubernetes,ldap,kerberos,statsd,openlineage,postgres,redis,ftp,http,imap,sqlite,async"

# Use official Airflow 3.2.2 constraints to pin dependency versions (constraints-${PY_VERSION}.txt)
CONSTRAINTS_FILE="${SCRIPT_DIR}/constraints-${PY_VERSION}.txt"

if [ ! -f "${CONSTRAINTS_FILE}" ]; then
    echo "ERROR: Constraints file not found at ${CONSTRAINTS_FILE}"
    echo "This file is required for reproducible builds (Apache Airflow ${AIRFLOW_VERSION} / Python ${PY_VERSION})."
    deactivate
    exit 1
fi

echo "Using constraints file: ${CONSTRAINTS_FILE}"

# Install Airflow from source with extras
# Using --no-build-isolation to use already installed build dependencies
uv pip install "${AIRFLOW_SOURCE_ROOT}[${AIRFLOW_EXTRAS}]" --no-build-isolation --constraint "${CONSTRAINTS_FILE}"

# Install additional dependencies from requirements-source.txt
echo ""
echo "Installing additional dependencies from requirements-source.txt..."
uv pip install -r "${REQUIREMENTS_FILE}" --constraint "${CONSTRAINTS_FILE}"

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
INSTALLED_VERSION=$(uv pip show apache-airflow-core 2>/dev/null | grep "^Version:" | cut -d' ' -f2 || echo "NOT INSTALLED")
echo "Installed apache-airflow-core version: ${INSTALLED_VERSION}"

if [ "${INSTALLED_VERSION}" == "NOT INSTALLED" ]; then
    echo "ERROR: Airflow was not installed correctly"
    deactivate
    exit 1
fi

# Verify the UI assets were built and included (hatchling build hook, see above)
echo ""
echo "Verifying UI assets in installed package..."
INSTALLED_UI_DIR=$(${PY} -c "import airflow; import os; print(os.path.join(os.path.dirname(airflow.__file__), 'ui', 'dist'))")

if [ ! -d "${INSTALLED_UI_DIR}" ] || [ -z "$(ls -A "${INSTALLED_UI_DIR}" 2>/dev/null)" ]; then
    echo "ERROR: UI assets NOT found in installed package at ${INSTALLED_UI_DIR}"
    echo "The airflow-core wheel build did not produce the compiled UI (check that prek and"
    echo "its 'compile-ui-assets' hook ran successfully during the pip/uv install above)."
    deactivate
    exit 1
fi

echo "UI assets verified OK at ${INSTALLED_UI_DIR}"

# List installed packages for reference
echo ""
echo "Installed packages:"
uv pip list

# Pack the environment
echo ""
echo "Packing environment..."
venv-pack -o "${SCRIPT_DIR}/${TARBALL_NAME}"

deactivate

# Step 4: Verify Tarball Contents
echo ""
echo "[Step 4] Verifying Tarball Contents"
echo ""

TARBALL_PATH="${SCRIPT_DIR}/${TARBALL_NAME}"

# Save file listing for diffing
TARBALL_FILELIST="${SCRIPT_DIR}/${TARBALL_NAME%.tar.gz}_filelist.txt"
tar tzf "${TARBALL_PATH}" | sort > "${TARBALL_FILELIST}"
echo "Full file listing saved to: ${TARBALL_FILELIST}"

echo ""
echo "============================================"
echo "Successfully created ${TARBALL_NAME}"
echo "Location: ${TARBALL_PATH}"
echo "File listing: ${TARBALL_FILELIST}"
echo ""
echo "This tarball was built from LOCAL SOURCE CODE"
echo "Any local patches in ${AIRFLOW_SOURCE_ROOT} are included"
echo ""
echo "To diff with another tarball:"
echo "  tar tzf other_tarball.tar.gz | sort > other_filelist.txt"
echo "  diff ${TARBALL_FILELIST} other_filelist.txt"
echo "============================================"
