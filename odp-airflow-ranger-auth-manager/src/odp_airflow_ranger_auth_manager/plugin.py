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

from airflow.plugins_manager import AirflowPlugin

from odp_airflow_ranger_auth_manager.request_context import RequestContextMiddleware


class RangerAuthzPlugin(AirflowPlugin):
    """Captures client IP and path on the api-server for Ranger audit records."""

    name = "odp_ranger_authz"
    fastapi_root_middlewares = [
        {
            "middleware": RequestContextMiddleware,
            "args": [],
            "kwargs": {},
            "name": "RangerAuthzRequestContext",
        }
    ]
