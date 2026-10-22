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

from airflow.api_fastapi.auth.managers.base_auth_manager import BaseAuthManager
from airflow.providers.fab.auth_manager.fab_auth_manager import FabAuthManager
from airflow.utils.session import NEW_SESSION

from odp_airflow_ranger_auth_manager.client import AuthorizeCheck, RangerAuthzClient
from odp_airflow_ranger_auth_manager.config import RangerClientConfig
from odp_airflow_ranger_auth_manager.constants import (
    RESOURCE_TYPE_ASSET,
    RESOURCE_TYPE_ASSET_ALIAS,
    RESOURCE_TYPE_CONFIG,
    RESOURCE_TYPE_CONNECTION,
    RESOURCE_TYPE_CUSTOM_VIEW,
    RESOURCE_TYPE_DAG,
    RESOURCE_TYPE_POOL,
    RESOURCE_TYPE_VARIABLE,
    RESOURCE_TYPE_VIEW,
)
from odp_airflow_ranger_auth_manager.request_context import current_request_context

if TYPE_CHECKING:
    from collections.abc import Iterable

    from sqlalchemy.orm import Session

    from airflow.api_fastapi.auth.managers.base_auth_manager import ResourceMethod
    from airflow.api_fastapi.auth.managers.models.resource_details import (
        AccessView,
        AssetAliasDetails,
        AssetDetails,
        ConfigurationDetails,
        ConnectionDetails,
        DagAccessEntity,
        DagDetails,
        PoolDetails,
        VariableDetails,
    )
    from airflow.providers.fab.auth_manager.models import User

log = logging.getLogger(__name__)


class RangerAuthManager(FabAuthManager):
    """FAB authentication, Ranger authorization.

    Every resource type in the Airflow service definition is answered by the
    Ranger agent. Anything still inherited from ``FabAuthManager`` is decided by
    FAB roles and leaves no Ranger audit record, so new authorization methods
    appearing in a future Airflow release must be wired here explicitly.

    Two surfaces are deliberately NOT overridden:

    * ``is_authorized_team`` / ``filter_authorized_teams`` -- the service
      definition has no ``team`` resource.
    * ``is_authorized_hitl_task`` -- assignment is by user list, not by a
      Ranger resource.

    ``batch_is_authorized_*`` needs no override: ``BaseAuthManager`` implements
    each one by calling the singular method per request, and ``FabAuthManager``
    does not override them, so the batch paths resolve here too.
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

    def _authorize(
        self,
        resource_type: str,
        method: str,
        user: User,
        key: str | None = None,
        access_entity: str | None = None,
    ) -> bool:
        """Ask the agent about one resource. Any failure denies."""
        if self._client is None:
            log.error("ranger authz client is not initialized; denying %s access", resource_type)
            return False
        check = AuthorizeCheck(
            id="0",
            resource_type=resource_type,
            method=method,
            access_entity=access_entity,
            key=key or None,
        )
        try:
            decisions = self._client.authorize(user.get_name(), current_request_context(), [check])
        except Exception:
            log.exception("ranger authorize failed; denying %s access", resource_type)
            return False
        return bool(decisions) and decisions[0].allowed

    def _filter(self, resource_type: str, method: str, user: User, keys: Iterable[str]) -> set[str]:
        """Narrow ``keys`` to the permitted subset in one agent round trip.

        One ``/v1/filter`` call rather than one ``/v1/authorize`` per key: a
        998-Dag list is one request and one audit record instead of 998 of
        each. Fails closed to an empty set.
        """
        if self._client is None:
            log.error("ranger authz client is not initialized; returning no %s", resource_type)
            return set()
        try:
            return set(
                self._client.filter_keys(
                    user.get_name(),
                    current_request_context(),
                    resource_type,
                    method,
                    keys,
                )
            )
        except Exception:
            log.exception("ranger filter failed; returning no %s", resource_type)
            return set()

    # ------------------------------------------------------------------
    # List filtering.
    #
    # FabAuthManager overrides get_authorized_{dag_ids,connections,pools,
    # variables} with role lookups that never consult the agent -- its
    # get_authorized_dag_ids returns every row in DagModel as soon as the FAB
    # role allows "read on DAGs", which is why a user granted dag=etl_* still
    # saw all 998. Delegating to BaseAuthManager restores the correct shape:
    # it loads the candidates and calls filter_authorized_*, which is
    # overridden below to answer from Ranger in a single call.
    # ------------------------------------------------------------------

    def get_authorized_dag_ids(
        self, *, user: User, method: ResourceMethod = "GET", session: Session = NEW_SESSION
    ) -> set[str]:
        return BaseAuthManager.get_authorized_dag_ids(self, user=user, method=method, session=session)

    def filter_authorized_dag_ids(
        self,
        *,
        dag_ids: set[str],
        user: User,
        method: ResourceMethod = "GET",
        team_name: str | None = None,
    ) -> set[str]:
        return self._filter(RESOURCE_TYPE_DAG, _method_str(method), user, dag_ids)

    def get_authorized_connections(
        self, *, user: User, method: ResourceMethod = "GET", session: Session = NEW_SESSION
    ) -> set[str]:
        return BaseAuthManager.get_authorized_connections(self, user=user, method=method, session=session)

    def filter_authorized_connections(
        self,
        *,
        conn_ids: set[str],
        user: User,
        method: ResourceMethod = "GET",
        team_name: str | None = None,
    ) -> set[str]:
        return self._filter(RESOURCE_TYPE_CONNECTION, _method_str(method), user, conn_ids)

    def get_authorized_pools(
        self, *, user: User, method: ResourceMethod = "GET", session: Session = NEW_SESSION
    ) -> set[str]:
        return BaseAuthManager.get_authorized_pools(self, user=user, method=method, session=session)

    def filter_authorized_pools(
        self,
        *,
        pool_names: set[str],
        user: User,
        method: ResourceMethod = "GET",
        team_name: str | None = None,
    ) -> set[str]:
        return self._filter(RESOURCE_TYPE_POOL, _method_str(method), user, pool_names)

    def get_authorized_variables(
        self, *, user: User, method: ResourceMethod = "GET", session: Session = NEW_SESSION
    ) -> set[str]:
        return BaseAuthManager.get_authorized_variables(self, user=user, method=method, session=session)

    def filter_authorized_variables(
        self,
        *,
        variable_keys: set[str],
        user: User,
        method: ResourceMethod = "GET",
        team_name: str | None = None,
    ) -> set[str]:
        return self._filter(RESOURCE_TYPE_VARIABLE, _method_str(method), user, variable_keys)

    def is_authorized_dag(
        self,
        *,
        method: ResourceMethod,
        user: User,
        access_entity: DagAccessEntity | None = None,
        details: DagDetails | None = None,
    ) -> bool:
        return self._authorize(
            RESOURCE_TYPE_DAG,
            _method_str(method),
            user,
            key=details.id if details else None,
            access_entity=access_entity.value if access_entity is not None else None,
        )

    def is_authorized_connection(
        self,
        *,
        method: ResourceMethod,
        user: User,
        details: ConnectionDetails | None = None,
    ) -> bool:
        return self._authorize(
            RESOURCE_TYPE_CONNECTION, _method_str(method), user, key=details.conn_id if details else None
        )

    def is_authorized_variable(
        self,
        *,
        method: ResourceMethod,
        user: User,
        details: VariableDetails | None = None,
    ) -> bool:
        return self._authorize(
            RESOURCE_TYPE_VARIABLE, _method_str(method), user, key=details.key if details else None
        )

    def is_authorized_pool(
        self,
        *,
        method: ResourceMethod,
        user: User,
        details: PoolDetails | None = None,
    ) -> bool:
        return self._authorize(
            RESOURCE_TYPE_POOL, _method_str(method), user, key=details.name if details else None
        )

    def is_authorized_asset(
        self,
        *,
        method: ResourceMethod,
        user: User,
        details: AssetDetails | None = None,
    ) -> bool:
        return self._authorize(
            RESOURCE_TYPE_ASSET, _method_str(method), user, key=details.id if details else None
        )

    def is_authorized_asset_alias(
        self,
        *,
        method: ResourceMethod,
        user: User,
        details: AssetAliasDetails | None = None,
    ) -> bool:
        return self._authorize(
            RESOURCE_TYPE_ASSET_ALIAS, _method_str(method), user, key=details.id if details else None
        )

    def is_authorized_configuration(
        self,
        *,
        method: ResourceMethod,
        user: User,
        details: ConfigurationDetails | None = None,
    ) -> bool:
        return self._authorize(
            RESOURCE_TYPE_CONFIG, _method_str(method), user, key=details.section if details else None
        )

    def is_authorized_view(self, *, access_view: AccessView, user: User) -> bool:
        # A view is read-only by definition, so the method is always GET. The
        # AccessView value is the resource KEY (view=JOBS), not an access
        # entity -- AccessMapper rejects an entity on `view`. This is the path
        # /api/v2/importErrors and /api/v2/jobs arrive on.
        return self._authorize(
            RESOURCE_TYPE_VIEW, "GET", user, key=getattr(access_view, "value", str(access_view))
        )

    def is_authorized_custom_view(self, *, method: ResourceMethod, resource_name: str, user: User) -> bool:
        # `method` here may be an arbitrary plugin-defined action such as
        # "can_do" rather than a CRUD verb. AccessMapper maps only GET/POST/
        # PUT/DELETE and reports anything else as unmapped, which denies.
        return self._authorize(RESOURCE_TYPE_CUSTOM_VIEW, _method_str(method), user, key=resource_name)


def _method_str(method: object) -> str:
    value = getattr(method, "value", method)
    return str(value)
