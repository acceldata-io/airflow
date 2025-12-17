#!/usr/bin/env bash
# Build Apache Airflow tarball for ODP
set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
PY=python3.8
PY_VERSION=3.8
AIRFLOW_VERSION=2.8.1
CONSTRAINTS_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PY_VERSION}.txt"
REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"

echo "============================================"
echo "Airflow ${AIRFLOW_VERSION} Tarball Builder"
echo "============================================"

# Verify requirements.txt exists
if [ ! -f "${REQUIREMENTS_FILE}" ]; then
    echo "ERROR: requirements.txt not found at ${REQUIREMENTS_FILE}"
    exit 1
fi


echo "Creating virtual environment with ${PY}..."
$PY -m venv airflow

echo "Activating virtual environment..."
source airflow/bin/activate

echo "Upgrading pip..."
pip install --upgrade pip

echo "Installing requirements..."
pip install -r "${REQUIREMENTS_FILE}" --constraint "${CONSTRAINTS_URL}"

echo "Packing environment..."
venv-pack -o airflow_venv_all.tar.gz

deactivate

echo "============================================"
echo "Successfully created airflow_venv_all.tar.gz"
echo "============================================"
