#!/usr/bin/env bash
# Build Apache Airflow tarball for ODP - PATCHED BUILD
#
# Strategy: Install stock Airflow from PyPI (fast), then overlay local
# source file changes on top. Listed in patch_files.txt.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRFLOW_SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Configuration
PY=python3.11
PY_VERSION=3.11
AIRFLOW_VERSION=2.8.3

ODP_VERSION=$(cat "${SCRIPT_DIR}/VERSION" | tr -d '[:space:]')
ODP_AIRFLOW_VERSION="${AIRFLOW_VERSION}.${ODP_VERSION}"
ODP_AIRFLOW_VERSION_UNDERSCORE="${ODP_AIRFLOW_VERSION//./_}"
ODP_AIRFLOW_VERSION_UNDERSCORE="${ODP_AIRFLOW_VERSION_UNDERSCORE//-/_}"

CONSTRAINTS_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PY_VERSION}.txt"
REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"
PATCH_FILES_LIST="${SCRIPT_DIR}/patch_files.txt"
LOCAL_CONSTRAINTS="${SCRIPT_DIR}/constraints-local.txt"
TARBALL_NAME="airflow_environment_${ODP_AIRFLOW_VERSION_UNDERSCORE}.tar.gz"
VENV_DIR="${SCRIPT_DIR}/airflow"

echo "============================================"
echo "Airflow Tarball Builder (PATCHED)"
echo "============================================"
echo "Airflow Version: ${AIRFLOW_VERSION} (from PyPI)"
echo "ODP Version:     ${ODP_VERSION}"
echo "Combined:        ${ODP_AIRFLOW_VERSION}"
echo "Source Root:     ${AIRFLOW_SOURCE_ROOT}"
echo "Tarball:         ${TARBALL_NAME}"
echo "============================================"

# --- Validate inputs ---

if [ ! -f "${REQUIREMENTS_FILE}" ]; then
    echo "ERROR: requirements.txt not found at ${REQUIREMENTS_FILE}"
    exit 1
fi

if [ ! -f "${PATCH_FILES_LIST}" ]; then
    echo "ERROR: patch_files.txt not found at ${PATCH_FILES_LIST}"
    echo "Create it with one changed file path per line (relative to source root)."
    exit 1
fi

# Parse patch_files.txt: strip comments/blanks
PATCH_FILES=()
while IFS= read -r line; do
    line="${line%%#*}"       # strip inline comments
    line="$(echo "$line" | xargs)" # trim whitespace
    [ -z "$line" ] && continue
    PATCH_FILES+=("$line")
done < "${PATCH_FILES_LIST}"

if [ ${#PATCH_FILES[@]} -eq 0 ]; then
    echo "WARNING: patch_files.txt is empty (no files to overlay)."
    echo "Building a stock tarball with no patches."
fi

# Verify every listed source file actually exists
echo ""
echo "Patch files to overlay (${#PATCH_FILES[@]}):"
for f in "${PATCH_FILES[@]+"${PATCH_FILES[@]}"}"; do
    src="${AIRFLOW_SOURCE_ROOT}/${f}"
    if [ ! -f "$src" ]; then
        echo "  ERROR: ${f} not found at ${src}"
        exit 1
    fi
    echo "  ${f}"
done
echo ""

# --- Step 1: Prerequisites ---
echo "[Step 1] Installing Prerequisites"

PREREQS_SCRIPT="${SCRIPT_DIR}/install_prereqs.sh"
if [ -f "${PREREQS_SCRIPT}" ]; then
    chmod +x "${PREREQS_SCRIPT}"
    bash "${PREREQS_SCRIPT}"
else
    echo "WARNING: install_prereqs.sh not found, skipping."
fi

# --- Step 2: Python 3.11 ---
echo ""
echo "[Step 2] Installing Python 3.11"

PYTHON_SCRIPT="${SCRIPT_DIR}/install_python311.sh"
if [ -f "${PYTHON_SCRIPT}" ]; then
    chmod +x "${PYTHON_SCRIPT}"
    bash "${PYTHON_SCRIPT}"
else
    echo "ERROR: install_python311.sh not found"
    exit 1
fi

if ! command -v ${PY} &>/dev/null; then
    echo "ERROR: ${PY} is not available"
    exit 1
fi
echo "Python: $(${PY} --version)"

# --- Step 3: Pip install stock Airflow ---
echo ""
echo "[Step 3] Installing Stock Airflow ${AIRFLOW_VERSION} from PyPI"

echo "Downloading constraints..."
curl -sL "${CONSTRAINTS_URL}" -o "${LOCAL_CONSTRAINTS}"

echo "Modifying constraints..."
sed -i '/^mysqlclient/d' "${LOCAL_CONSTRAINTS}"
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
sed -i '/^google-re2/d' "${LOCAL_CONSTRAINTS}"

export CFLAGS="-std=gnu99"
export CXXFLAGS="-std=gnu99"

echo "Creating virtual environment..."
rm -rf "${VENV_DIR}"
$PY -m venv "${VENV_DIR}"

echo "Activating virtual environment..."
source "${VENV_DIR}/bin/activate"

echo "Upgrading pip..."
pip install --upgrade pip

echo "Installing requirements (stock Airflow from PyPI)..."
pip install -r "${REQUIREMENTS_FILE}" --constraint "${LOCAL_CONSTRAINTS}"

echo "Reinstalling google-re2 with system re2 library..."
pip uninstall -y google-re2 || true
pip install google-re2 --force-reinstall --no-cache-dir

# --- Step 4: Overlay patched files ---
echo ""
echo "[Step 4] Overlaying Patched Files"

SITE_PACKAGES="${VENV_DIR}/lib/python${PY_VERSION}/site-packages"

if [ ! -d "${SITE_PACKAGES}" ]; then
    echo "ERROR: site-packages not found at ${SITE_PACKAGES}"
    deactivate
    exit 1
fi

PATCHED_COUNT=0
for f in "${PATCH_FILES[@]+"${PATCH_FILES[@]}"}"; do
    src="${AIRFLOW_SOURCE_ROOT}/${f}"
    dest="${SITE_PACKAGES}/${f}"
    dest_dir="$(dirname "$dest")"

    if [ ! -d "$dest_dir" ]; then
        echo "  WARNING: target directory ${dest_dir} does not exist, creating it."
        mkdir -p "$dest_dir"
    fi

    cp -v "$src" "$dest"
    PATCHED_COUNT=$((PATCHED_COUNT + 1))
done

echo ""
echo "Overlayed ${PATCHED_COUNT} file(s) onto installed Airflow."

# --- Step 5: BUILD_INFO ---
echo ""
echo "[Step 5] Generating BUILD_INFO"

BUILD_INFO_FILE="${VENV_DIR}/BUILD_INFO"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    BUILD_OS="${ID}-${VERSION_ID}"
else
    BUILD_OS="unknown"
fi

PYTHON_FULL_VERSION=$(${PY} --version 2>&1 | awk '{print $2}')

cat > "${BUILD_INFO_FILE}" <<EOF
AIRFLOW_VERSION=${AIRFLOW_VERSION}
ODP_VERSION=${ODP_VERSION}
ODP_AIRFLOW_VERSION=${ODP_AIRFLOW_VERSION}
BUILD_TYPE=patched
BUILD_DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
BUILD_OS=${BUILD_OS}
PYTHON_VERSION=${PYTHON_FULL_VERSION}
PATCHED_FILES=${PATCH_FILES[*]+"${PATCH_FILES[*]}"}
EOF

echo "BUILD_INFO:"
cat "${BUILD_INFO_FILE}"

# --- Step 6: Pack tarball ---
echo ""
echo "[Step 6] Packing tarball"

venv-pack -o "${SCRIPT_DIR}/${TARBALL_NAME}"

deactivate

# --- Step 7: Verify patched files are in tarball ---
echo ""
echo "[Step 7] Verifying patched files in tarball"

TARBALL_PATH="${SCRIPT_DIR}/${TARBALL_NAME}"
ALL_GOOD=true

for f in "${PATCH_FILES[@]+"${PATCH_FILES[@]}"}"; do
    # In the tarball, paths are relative to venv root: lib/python3.11/site-packages/airflow/...
    tarball_path="lib/python${PY_VERSION}/site-packages/${f}"
    if tar tzf "${TARBALL_PATH}" | grep -q "${tarball_path}"; then
        echo "  OK: ${f}"
    else
        echo "  MISSING: ${f} (expected at ${tarball_path})"
        ALL_GOOD=false
    fi
done

if [ "$ALL_GOOD" = true ]; then
    echo ""
    echo "All patched files verified in tarball."
else
    echo ""
    echo "WARNING: Some patched files were not found in the tarball!"
fi

echo ""
echo "============================================"
echo "Successfully created ${TARBALL_NAME}"
echo "Location: ${TARBALL_PATH}"
echo ""
echo "Build type: PATCHED (stock PyPI + ${PATCHED_COUNT} file overlay)"
echo "Patched files:"
for f in "${PATCH_FILES[@]+"${PATCH_FILES[@]}"}"; do
    echo "  - ${f}"
done
echo "============================================"
