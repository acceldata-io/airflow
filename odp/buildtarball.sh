#!/usr/bin/env bash
# Build Apache Airflow tarball for ODP
set -euo pipefail

PY=python3.8
PY_VERSION=3.8
AIRFLOW_VERSION=2.8.1
CONSTRAINTS_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PY_VERSION}.txt"

echo "Creating virtual environment with ${PY}..."
$PY -m venv airflow

echo "Activating virtual environment..."
source airflow/bin/activate

echo "Upgrading pip..."
pip install --upgrade pip

echo "Installing requirements..."
pip install -r requirements.txt --constraint "${CONSTRAINTS_URL}"

echo "Packing environment..."
venv-pack -o airflow_venv_all.tar.gz

deactivate

echo "Successfully created airflow_venv_all.tar.gz"
