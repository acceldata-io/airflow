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
from typing import TYPE_CHECKING

from airflow.providers.fab.auth_manager.fab_auth_manager import FabAuthManager

from odp_airflow_ranger_auth_manager.client import AuthorizeCheck, RangerAuthzClient
from odp_airflow_ranger_auth_manager.config import RangerClientConfig
from odp_airflow_ranger_auth_manager.constants import RESOURCE_TYPE_DAG
from odp_airflow_ranger_auth_manager.request_context import current_request_context

if TYPE_CHECKING:
    from airflow.api_fastapi.auth.managers.base_auth_manager import ResourceMethod
    from airflow.api_fastapi.auth.managers.models.resource_details import DagAccessEntity, DagDetails
    from airflow.providers.fab.auth_manager.models import User

log = logging.getLogger(__name__)


class RangerAuthManager(FabAuthManager):
    """FAB authentication, Ranger authorization for DAG access.

    M1 overrides ``is_authorized_dag`` only. Every other authorization method
    still uses FAB until the remaining surface is wired in later tickets.
    """

    def __init__(self, client: RangerAuthzClient | None = None):
        super().__init__()
        self._client = client

    def init(self) -> None:
        super().init()
        if self._client is None:
            from airflow import __version__

            self._client = RangerAuthzClient(RangerClientConfig.from_airflow_conf())
            self._client.handshake(__version__)

    def is_authorized_dag(
        self,
        *,
        method: ResourceMethod,
        user: User,
        access_entity: DagAccessEntity | None = None,
        details: DagDetails | None = None,
    ) -> bool:
        if self._client is None:
            log.error("ranger authz client is not initialized; denying dag access")
            return False
        check = AuthorizeCheck(
            id="0",
            resource_type=RESOURCE_TYPE_DAG,
            method=_method_str(method),
            access_entity=access_entity.value if access_entity is not None else None,
            key=details.id if details and details.id else None,
        )
        try:
            decisions = self._client.authorize(user.get_name(), current_request_context(), [check])
        except Exception:
            log.exception("ranger authorize failed; denying dag access")
            return False
        return bool(decisions) and decisions[0].allowed


def _method_str(method: object) -> str:
    value = getattr(method, "value", method)
    return str(value)
