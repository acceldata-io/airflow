#!/usr/bin/env python3
"""Assemble patched apache-airflow provider wheels from the ODP monorepo source.

Some provider CVE fixes cannot be delivered by bumping to the upstream fixed
provider version, because upstream only shipped the fix in provider releases
that require a newer Airflow core than we ship (e.g. samba/smtp fixes require
apache-airflow>=2.9/2.11, but ODP is on 2.8.3). Building the provider FROM our
local (patched) source keeps the 2.8.3-compatible provider version line while
including the fix.

Providers here are pure-Python, so a ``py3-none-any`` wheel is just a correctly
structured zip -- no build backend, network, or Docker/breeze required. Emits
wheels into ``odp/wheelhouse/`` which the tarball build then installs.

Add a new provider by appending an entry to PROVIDERS (translate its
provider.yaml). Bump the ``+odpN`` local version segment when you re-cut a build.
"""
from __future__ import annotations

import base64
import hashlib
import os
import shutil
import zipfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)                 # airflow source root (one level up from odp/)
OUT = os.path.join(SCRIPT_DIR, "wheelhouse")

# One entry per provider we build from source. `info` is a faithful translation
# of that provider's airflow/providers/<name>/provider.yaml (Airflow reads it via
# the get_provider_info entry point to register hooks/connection-types/etc.).
PROVIDERS = {
    "smtp": {
        "dist": "apache-airflow-providers-smtp",
        "version": "1.6.0+odp1",           # CVE-2026-49267 (STARTTLS cert validation), provider half
        "requires": ["apache-airflow>=2.6.0"],
        "info": {
            "package-name": "apache-airflow-providers-smtp",
            "name": "Simple Mail Transfer Protocol (SMTP)",
            "description": "`Simple Mail Transfer Protocol (SMTP) <https://tools.ietf.org/html/rfc5321>`__\n",
            "state": "ready",
            "source-date-epoch": 1703288172,
            "versions": ["1.6.0", "1.5.0", "1.4.1", "1.4.0", "1.3.2", "1.3.1", "1.3.0", "1.2.0", "1.1.0", "1.0.1", "1.0.0"],
            "dependencies": ["apache-airflow>=2.6.0"],
            "integrations": [{"integration-name": "Simple Mail Transfer Protocol (SMTP)",
                              "external-doc-url": "https://tools.ietf.org/html/rfc5321",
                              "logo": "/integration-logos/smtp/SMTP.png", "tags": ["protocol"]}],
            "operators": [{"integration-name": "Simple Mail Transfer Protocol (SMTP)",
                           "python-modules": ["airflow.providers.smtp.operators.smtp"]}],
            "hooks": [{"integration-name": "Simple Mail Transfer Protocol (SMTP)",
                       "python-modules": ["airflow.providers.smtp.hooks.smtp"]}],
            "connection-types": [{"hook-class-name": "airflow.providers.smtp.hooks.smtp.SmtpHook",
                                  "connection-type": "smtp"}],
            "notifications": ["airflow.providers.smtp.notifications.smtp.SmtpNotifier"],
        },
    },
    "samba": {
        "dist": "apache-airflow-providers-samba",
        "version": "4.4.0+odp1",           # CVE-2026-49818 (GCSToSambaOperator path traversal)
        "requires": ["apache-airflow>=2.6.0", "smbprotocol>=1.5.0"],
        "info": {
            "package-name": "apache-airflow-providers-samba",
            "name": "Samba",
            "description": "`Samba <https://www.samba.org/>`__\n",
            "state": "ready",
            "source-date-epoch": 1703288166,
            "versions": ["4.4.0", "4.3.0", "4.2.2", "4.2.1", "4.2.0", "4.1.0", "4.0.0", "3.0.4", "3.0.3", "3.0.2", "3.0.1", "3.0.0", "2.0.0", "1.0.1", "1.0.0"],
            "dependencies": ["apache-airflow>=2.6.0", "smbprotocol>=1.5.0"],
            "integrations": [{"integration-name": "Samba", "external-doc-url": "https://www.samba.org/",
                              "logo": "/integration-logos/samba/Samba.png", "tags": ["protocol"]}],
            "hooks": [{"integration-name": "Samba", "python-modules": ["airflow.providers.samba.hooks.samba"]}],
            "transfers": [{"source-integration-name": "Google Cloud Storage (GCS)", "target-integration-name": "Samba",
                           "how-to-guide": "/docs/apache-airflow-providers-samba/transfer/gcs_to_samba.rst",
                           "python-module": "airflow.providers.samba.transfers.gcs_to_samba"}],
            "connection-types": [{"hook-class-name": "airflow.providers.samba.hooks.samba.SambaHook",
                                  "connection-type": "samba"}],
        },
    },
}


def _record(data: bytes) -> tuple[str, int]:
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
    return f"sha256={digest}", len(data)


def _gen_get_provider_info(info: dict) -> bytes:
    return ("def get_provider_info():\n    return " + repr(info) + "\n").encode()


def build(name: str, spec: dict) -> str:
    dist, version, requires, info = spec["dist"], spec["version"], spec["requires"], spec["info"]
    dist_us = dist.replace("-", "_")
    src_root = os.path.join(REPO_ROOT, "airflow", "providers", name)
    if not os.path.isdir(src_root):
        raise SystemExit(f"provider source not found: {src_root}")
    records: list[tuple[str, str, int]] = []
    whl_path = os.path.join(OUT, f"{dist_us}-{version}-py3-none-any.whl")
    with zipfile.ZipFile(whl_path, "w", zipfile.ZIP_DEFLATED) as z:
        def add(arc: str, data: bytes) -> None:
            z.writestr(arc, data)
            hf, sz = _record(data)
            records.append((arc, hf, sz))

        # 1) provider source tree (skip caches); inject the generated get_provider_info.py
        for root, dirs, files in os.walk(src_root):
            dirs[:] = [d for d in dirs if d != "__pycache__"]
            for f in files:
                if f.endswith((".pyc", ".pyo")):
                    continue
                full = os.path.join(root, f)
                arc = os.path.relpath(full, REPO_ROOT)          # airflow/providers/<name>/...
                with open(full, "rb") as fh:
                    add(arc, fh.read())
        add(f"airflow/providers/{name}/get_provider_info.py", _gen_get_provider_info(info))

        # 2) dist-info metadata
        di = f"{dist_us}-{version}.dist-info"
        metadata = (
            f"Metadata-Version: 2.1\nName: {dist}\nVersion: {version}\n"
            f"Summary: Provider package {dist} for Apache Airflow (ODP CVE backport build)\n"
            f"Requires-Python: ~=3.8\n"
            + "".join(f"Requires-Dist: {r}\n" for r in requires)
        )
        add(f"{di}/METADATA", metadata.encode())
        add(f"{di}/WHEEL",
            b"Wheel-Version: 1.0\nGenerator: odp-build_providers (1.0)\nRoot-Is-Purelib: true\nTag: py3-none-any\n")
        add(f"{di}/entry_points.txt",
            f"[apache_airflow_provider]\nprovider_info=airflow.providers.{name}.get_provider_info:get_provider_info\n".encode())
        add(f"{di}/top_level.txt", b"airflow\n")

        # 3) RECORD (its own line carries no hash/size)
        rec = "".join(f"{a},{h},{s}\n" for a, h, s in records) + f"{di}/RECORD,,\n"
        z.writestr(f"{di}/RECORD", rec)
    return whl_path


def main() -> None:
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT, exist_ok=True)
    for name, spec in PROVIDERS.items():
        path = build(name, spec)
        print(f"built {os.path.basename(path)}  ({os.path.getsize(path)} bytes)")
    print(f"wheelhouse: {OUT}")


if __name__ == "__main__":
    main()
