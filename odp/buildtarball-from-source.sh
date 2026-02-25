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

# Step 3: Compile Frontend Assets (JS/CSS via Webpack)
echo ""
echo "[Step 3] Compiling Frontend Assets (JavaScript/CSS)"
echo ""
echo "The Airflow web UI requires compiled JS/CSS bundles in airflow/www/static/dist/"
echo "These are NOT checked into the source tree - they must be built via webpack/yarn."
echo ""

WWW_DIR="${AIRFLOW_SOURCE_ROOT}/airflow/www"
DIST_DIR="${WWW_DIR}/static/dist"

# Check if dist/ already exists with content (e.g., from a previous build)
if [ -d "${DIST_DIR}" ] && [ "$(ls -A ${DIST_DIR} 2>/dev/null)" ]; then
    echo "WARNING: ${DIST_DIR} already exists with content."
    echo "Cleaning it to ensure a fresh build..."
    rm -rf "${DIST_DIR}"
fi

# Install Node.js if not available
if ! command -v node &>/dev/null; then
    echo "Node.js not found. Installing Node.js 18.x..."

    # Detect OS for Node.js installation
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        NODE_OS_ID="${ID}"
    else
        NODE_OS_ID="unknown"
    fi

    case "${NODE_OS_ID}" in
        rhel|centos|rocky|almalinux|fedora)
            curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
            yum install -y nodejs
            ;;
        ubuntu|debian)
            curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
            apt-get install -y nodejs
            ;;
        *)
            echo "ERROR: Cannot auto-install Node.js on ${NODE_OS_ID}."
            echo "Please install Node.js 18+ manually and re-run."
            exit 1
            ;;
    esac
fi

echo "Node.js version: $(node --version)"
echo "npm version: $(npm --version)"

# Install yarn if not available
if ! command -v yarn &>/dev/null; then
    echo "Installing yarn via npm..."
    npm install -g yarn
fi
echo "Yarn version: $(yarn --version)"

# Build frontend assets
echo ""
echo "Running yarn install in ${WWW_DIR}..."
cd "${WWW_DIR}"
yarn install --frozen-lockfile

echo ""
echo "Running yarn build (webpack production build)..."
yarn run build
cd "${SCRIPT_DIR}"

# Verify dist/ was created with expected files
if [ ! -d "${DIST_DIR}" ]; then
    echo "ERROR: Frontend build failed - ${DIST_DIR} was not created!"
    exit 1
fi

DIST_FILE_COUNT=$(find "${DIST_DIR}" -type f | wc -l)
if [ "${DIST_FILE_COUNT}" -lt 10 ]; then
    echo "ERROR: Frontend build appears incomplete - only ${DIST_FILE_COUNT} files in ${DIST_DIR}"
    exit 1
fi

# Check for critical files
if [ ! -f "${DIST_DIR}/manifest.json" ]; then
    echo "ERROR: manifest.json not found in ${DIST_DIR} - webpack build likely failed"
    exit 1
fi

echo ""
echo "Frontend build successful!"
echo "Files in ${DIST_DIR}: ${DIST_FILE_COUNT}"
echo "Key files:"
ls -la "${DIST_DIR}/manifest.json"
echo ""
echo "Webpack entry points built:"
ls "${DIST_DIR}"/*.js 2>/dev/null | head -20 || true
echo ""

# Step 4: Build Tarball from Source
echo ""
echo "[Step 4] Building Airflow Tarball from Source"

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
pip install --upgrade pip setuptools wheel Cython

# Install build dependencies required by hatchling and C extensions (gssapi, krb5)
echo "Installing build dependencies for Airflow..."
pip install \
    "GitPython==3.1.42" \
    "hatchling==1.21.1" \
    "editables==0.5" \
    "gitdb==4.0.11" \
    "packaging>=24.0" \
    "pathspec==0.12.1" \
    "pluggy==1.4.0" \
    "smmap==5.0.1" \
    "trove-classifiers==2024.3.3"

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
echo "NOTE: You should see 'Processing ${AIRFLOW_SOURCE_ROOT}' below (NOT 'Downloading apache-airflow')"
echo ""

# Define the extras we want (same as original requirements.txt but without 'mysql' which pulls mysqlclient)
AIRFLOW_EXTRAS="celery,cncf.kubernetes,ldap,kerberos,statsd,openlineage,postgres,redis,ftp,http,imap,sqlite,async,crypto,password"

# Install Airflow from source with extras
# Using --no-build-isolation to use already installed build dependencies
pip install "${AIRFLOW_SOURCE_ROOT}[${AIRFLOW_EXTRAS}]" --no-build-isolation -v

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

# Verify frontend assets were included in the installed package
echo ""
echo "Verifying frontend assets in installed package..."
INSTALLED_AIRFLOW_WWW=$(${PY} -c "import airflow.www; import os; print(os.path.dirname(airflow.www.__file__))")
INSTALLED_DIST_DIR="${INSTALLED_AIRFLOW_WWW}/static/dist"

if [ ! -d "${INSTALLED_DIST_DIR}" ]; then
    echo "ERROR: Frontend assets NOT found in installed package at ${INSTALLED_DIST_DIR}"
    echo "The pip install did not include the compiled JS/CSS files."
    echo "This means the Airflow web UI will be broken."
    deactivate
    exit 1
fi

INSTALLED_DIST_COUNT=$(find "${INSTALLED_DIST_DIR}" -type f | wc -l)
echo "Frontend assets in installed package: ${INSTALLED_DIST_COUNT} files"

if [ "${INSTALLED_DIST_COUNT}" -lt 10 ]; then
    echo "ERROR: Only ${INSTALLED_DIST_COUNT} frontend files found - expected many more."
    echo "Contents of ${INSTALLED_DIST_DIR}:"
    ls -la "${INSTALLED_DIST_DIR}/"
    deactivate
    exit 1
fi

if [ ! -f "${INSTALLED_DIST_DIR}/manifest.json" ]; then
    echo "ERROR: manifest.json not found in installed package's dist directory"
    deactivate
    exit 1
fi

echo "Frontend assets verified OK (${INSTALLED_DIST_COUNT} files including manifest.json)"

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

# Step 5: Verify Tarball Contents
echo ""
echo "[Step 5] Verifying Tarball Contents"
echo ""

TARBALL_PATH="${SCRIPT_DIR}/${TARBALL_NAME}"

# Save file listing for diffing
TARBALL_FILELIST="${SCRIPT_DIR}/${TARBALL_NAME%.tar.gz}_filelist.txt"
tar tzf "${TARBALL_PATH}" | sort > "${TARBALL_FILELIST}"
echo "Full file listing saved to: ${TARBALL_FILELIST}"

# Check for critical frontend files
echo ""
echo "Checking for frontend assets in tarball..."
JS_COUNT=$(tar tzf "${TARBALL_PATH}" | grep -c 'www/static/dist/.*\.js$' || true)
CSS_COUNT=$(tar tzf "${TARBALL_PATH}" | grep -c 'www/static/dist/.*\.css$' || true)
MANIFEST_COUNT=$(tar tzf "${TARBALL_PATH}" | grep -c 'www/static/dist/manifest\.json$' || true)

echo "  JS files in static/dist/:  ${JS_COUNT}"
echo "  CSS files in static/dist/: ${CSS_COUNT}"
echo "  manifest.json:             ${MANIFEST_COUNT}"

if [ "${JS_COUNT}" -lt 5 ]; then
    echo ""
    echo "WARNING: Only ${JS_COUNT} JS files found in tarball! Expected 15+."
    echo "The Airflow web UI may be broken."
fi

if [ "${MANIFEST_COUNT}" -eq 0 ]; then
    echo ""
    echo "ERROR: manifest.json NOT found in tarball! The Airflow web UI WILL be broken."
    exit 1
fi

# Show the frontend files for manual inspection
echo ""
echo "Frontend files in tarball:"
tar tzf "${TARBALL_PATH}" | grep 'www/static/dist/' | head -40

echo ""
echo "============================================"
echo "Successfully created ${TARBALL_NAME}"
echo "Location: ${TARBALL_PATH}"
echo "File listing: ${TARBALL_FILELIST}"
echo ""
echo "This tarball was built from LOCAL SOURCE CODE"
echo "Any local patches in ${AIRFLOW_SOURCE_ROOT} are included"
echo ""
echo "Frontend assets: ${JS_COUNT} JS + ${CSS_COUNT} CSS files"
echo ""
echo "To diff with another tarball:"
echo "  tar tzf other_tarball.tar.gz | sort > other_filelist.txt"
echo "  diff ${TARBALL_FILELIST} other_filelist.txt"
echo "============================================"
