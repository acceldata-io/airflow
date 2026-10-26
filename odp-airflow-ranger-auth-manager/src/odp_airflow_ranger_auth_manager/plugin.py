#
# Copyright 2026 Acceldata Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#

from __future__ import annotations

import logging

from airflow.plugins_manager import AirflowPlugin

from odp_airflow_ranger_auth_manager.request_context import RequestContextMiddleware

log = logging.getLogger(__name__)

# Any auth manager shipped by this package.
_AUTH_MANAGER_PREFIX = "odp_airflow_ranger_auth_manager."

_MIDDLEWARE = {
    "middleware": RequestContextMiddleware,
    "args": [],
    "kwargs": {},
    "name": "RangerAuthzRequestContext",
}


def _ranger_is_the_auth_manager() -> bool:
    """Whether [core] auth_manager names an auth manager from this package.

    This package is installed into the ODP Airflow venv whether or not anyone
    enables Ranger, and an ``airflow.plugins`` entry point registers on
    install rather than on enable. Without this check every ODP Airflow would
    run our middleware on every api-server request, including deployments
    that never configured Ranger at all.

    On any doubt the answer is True. A redundant middleware costs one ASGI
    frame; a missing one silently drops the client IP from every audit
    record, and an audit trail that says 0.0.0.0 is worse than a slow one.
    """
    try:
        from airflow.configuration import conf

        configured = conf.get("core", "auth_manager", fallback="") or ""
    except Exception:
        log.debug("could not read [core] auth_manager; registering the request-context middleware")
        return True
    return configured.strip().startswith(_AUTH_MANAGER_PREFIX)


class RangerAuthzPlugin(AirflowPlugin):
    """Captures client IP and path on the api-server for Ranger audit records.

    Contributes nothing unless Ranger is the configured auth manager.
    """

    name = "odp_ranger_authz"
    fastapi_root_middlewares = [_MIDDLEWARE] if _ranger_is_the_auth_manager() else []
