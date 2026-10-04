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

import sys
from dataclasses import dataclass
from enum import Enum
from types import ModuleType
from unittest.mock import MagicMock

from fake_agent import TOKEN, FakeAgent

from odp_airflow_ranger_auth_manager.client import AuthorizeCheck, Decision, RangerAuthzClient
from odp_airflow_ranger_auth_manager.config import RangerClientConfig
from odp_airflow_ranger_auth_manager.request_context import (
    RequestContext,
    reset_request_context,
    set_request_context,
)


def _ensure_airflow_stubs() -> None:
    try:
        from airflow.providers.fab.auth_manager.fab_auth_manager import FabAuthManager  # noqa: F401
        from airflow.api_fastapi.auth.managers.models.resource_details import (  # noqa: F401
            DagAccessEntity,
            DagDetails,
        )
        return
    except ImportError:
        pass

    def ensure(name: str) -> ModuleType:
        mod = sys.modules.get(name)
        if mod is None:
            mod = ModuleType(name)
            sys.modules[name] = mod
            parent, _, attr = name.rpartition(".")
            if parent:
                setattr(ensure(parent), attr, mod)
        return mod

    class DagAccessEntity(Enum):
        AUDIT_LOG = "AUDIT_LOG"
        CODE = "CODE"
        DEPENDENCIES = "DEPENDENCIES"
        HITL_DETAIL = "HITL_DETAIL"
        RUN = "RUN"
        TASK = "TASK"
        TASK_INSTANCE = "TASK_INSTANCE"
        TASK_LOGS = "TASK_LOGS"
        VERSION = "VERSION"
        WARNING = "WARNING"
        XCOM = "XCOM"

    @dataclass
    class DagDetails:
        id: str | None = None
        team_name: str | None = None

    details = ensure("airflow.api_fastapi.auth.managers.models.resource_details")
    details.DagAccessEntity = DagAccessEntity
    details.DagDetails = DagDetails

    class FabAuthManager:
        def __init__(self):
            pass

        def init(self) -> None:
            pass

        def is_authorized_connection(self, **kwargs):
            return False

        def is_authorized_variable(self, **kwargs):
            return False

        def is_authorized_pool(self, **kwargs):
            return False

        def is_authorized_configuration(self, **kwargs):
            return False

        def is_authorized_dag(self, **kwargs):
            return False

    airflow_mod = ensure("airflow")
    if not getattr(airflow_mod, "__version__", None):
        airflow_mod.__version__ = "3.2.2"

    fab = ensure("airflow.providers.fab.auth_manager.fab_auth_manager")
    fab.FabAuthManager = FabAuthManager


_ensure_airflow_stubs()

from airflow.api_fastapi.auth.managers.models.resource_details import DagAccessEntity, DagDetails
from airflow.providers.fab.auth_manager.fab_auth_manager import FabAuthManager

from odp_airflow_ranger_auth_manager.ranger_auth_manager import RangerAuthManager


class _User:
    def get_name(self) -> str:
        return "alice@CORP.EXAMPLE"


def test_does_not_override_non_dag_methods():
    assert RangerAuthManager.is_authorized_connection is FabAuthManager.is_authorized_connection
    assert RangerAuthManager.is_authorized_variable is FabAuthManager.is_authorized_variable
    assert RangerAuthManager.is_authorized_pool is FabAuthManager.is_authorized_pool
    assert RangerAuthManager.is_authorized_configuration is FabAuthManager.is_authorized_configuration
    assert RangerAuthManager.is_authorized_dag is not FabAuthManager.is_authorized_dag


def test_is_authorized_dag_allow():
    agent = FakeAgent().start()
    try:
        client = RangerAuthzClient(RangerClientConfig(agent_url=agent.url, token=TOKEN))
        manager = RangerAuthManager(client=client)
        token = set_request_context(
            RequestContext(client_ip="10.4.2.19", request_uri="/api/v2/dags/etl_sales/dagRuns")
        )
        try:
            allowed = manager.is_authorized_dag(
                method="POST",
                user=_User(),
                access_entity=DagAccessEntity.RUN,
                details=DagDetails(id="etl_sales"),
            )
        finally:
            reset_request_context(token)
        assert allowed is True
        body = agent.last_authorize
        assert body["user"] == "alice@CORP.EXAMPLE"
        assert body["checks"][0]["resource_type"] == "dag"
        assert body["checks"][0]["method"] == "POST"
        assert body["checks"][0]["access_entity"] == "RUN"
        assert body["checks"][0]["key"] == "etl_sales"
        assert "groups" not in body
    finally:
        agent.stop()


def test_is_authorized_dag_deny():
    agent = FakeAgent().start()
    try:
        agent.authorize_body = {
            "policy_version": 1,
            "decisions": [{"id": "0", "allowed": False, "reason": "explicit_deny", "policy_id": 9}],
        }
        client = RangerAuthzClient(RangerClientConfig(agent_url=agent.url, token=TOKEN))
        manager = RangerAuthManager(client=client)
        allowed = manager.is_authorized_dag(
            method="GET",
            user=_User(),
            details=DagDetails(id="secret_dag"),
        )
        assert allowed is False
    finally:
        agent.stop()


def test_is_authorized_dag_omits_key_for_any():
    captured = {}

    class RecordingClient:
        def authorize(self, user, context, checks):
            captured["user"] = user
            captured["checks"] = checks
            return [Decision(id=checks[0].id, allowed=True, policy_id=1)]

    manager = RangerAuthManager(client=RecordingClient())
    assert manager.is_authorized_dag(method="GET", user=_User()) is True
    check = captured["checks"][0]
    assert isinstance(check, AuthorizeCheck)
    assert check.resource_type == "dag"
    assert check.method == "GET"
    assert check.key is None
    assert check.access_entity is None
    assert "key" not in check.to_payload()


def test_is_authorized_dag_fail_closed_when_client_raises():
    client = MagicMock()
    client.authorize.side_effect = RuntimeError("boom")
    manager = RangerAuthManager(client=client)
    assert manager.is_authorized_dag(method="GET", user=_User(), details=DagDetails(id="x")) is False


def test_is_authorized_dag_fail_closed_before_init():
    manager = RangerAuthManager()
    assert manager.is_authorized_dag(method="GET", user=_User()) is False


def test_init_handshakes_with_running_airflow_version(monkeypatch):
    fake_client = MagicMock()

    monkeypatch.setattr(
        "odp_airflow_ranger_auth_manager.ranger_auth_manager.RangerClientConfig.from_airflow_conf",
        staticmethod(lambda: RangerClientConfig(agent_url="http://127.0.0.1:9183", token=TOKEN)),
    )
    monkeypatch.setattr(
        "odp_airflow_ranger_auth_manager.ranger_auth_manager.RangerAuthzClient",
        lambda config: fake_client,
    )
    monkeypatch.setattr("airflow.__version__", "3.2.2", raising=False)

    manager = RangerAuthManager()
    manager.init()
    fake_client.handshake.assert_called_once_with("3.2.2")
    assert manager._client is fake_client
