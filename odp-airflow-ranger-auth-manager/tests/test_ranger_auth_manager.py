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

    # Each details class names its key differently; that mapping is exactly
    # what the auth manager has to get right.
    @dataclass
    class ConnectionDetails:
        conn_id: str | None = None
        team_name: str | None = None

    @dataclass
    class VariableDetails:
        key: str | None = None
        team_name: str | None = None

    @dataclass
    class PoolDetails:
        name: str | None = None
        team_name: str | None = None

    @dataclass
    class AssetDetails:
        id: str | None = None

    @dataclass
    class AssetAliasDetails:
        id: str | None = None

    @dataclass
    class ConfigurationDetails:
        section: str | None = None

    class AccessView(Enum):
        CLUSTER_ACTIVITY = "CLUSTER_ACTIVITY"
        DOCS = "DOCS"
        IMPORT_ERRORS = "IMPORT_ERRORS"
        JOBS = "JOBS"
        PLUGINS = "PLUGINS"
        PROVIDERS = "PROVIDERS"
        TRIGGERS = "TRIGGERS"
        WEBSITE = "WEBSITE"

    details = ensure("airflow.api_fastapi.auth.managers.models.resource_details")
    details.DagAccessEntity = DagAccessEntity
    details.DagDetails = DagDetails
    details.ConnectionDetails = ConnectionDetails
    details.VariableDetails = VariableDetails
    details.PoolDetails = PoolDetails
    details.AssetDetails = AssetDetails
    details.AssetAliasDetails = AssetAliasDetails
    details.ConfigurationDetails = ConfigurationDetails
    details.AccessView = AccessView

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

        def is_authorized_asset(self, **kwargs):
            return False

        def is_authorized_asset_alias(self, **kwargs):
            return False

        def is_authorized_view(self, **kwargs):
            return False

        def is_authorized_custom_view(self, **kwargs):
            return False

    airflow_mod = ensure("airflow")
    if not getattr(airflow_mod, "__version__", None):
        airflow_mod.__version__ = "3.2.2"

    fab = ensure("airflow.providers.fab.auth_manager.fab_auth_manager")
    fab.FabAuthManager = FabAuthManager


_ensure_airflow_stubs()

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
from airflow.providers.fab.auth_manager.fab_auth_manager import FabAuthManager

from odp_airflow_ranger_auth_manager.ranger_auth_manager import RangerAuthManager


class _User:
    def get_name(self) -> str:
        return "alice@CORP.EXAMPLE"


def test_every_resource_type_is_answered_by_ranger():
    """Anything still inherited from FAB is decided by FAB roles and is not audited."""
    for name in (
        "is_authorized_dag",
        "is_authorized_connection",
        "is_authorized_variable",
        "is_authorized_pool",
        "is_authorized_asset",
        "is_authorized_asset_alias",
        "is_authorized_configuration",
        "is_authorized_view",
        "is_authorized_custom_view",
    ):
        assert getattr(RangerAuthManager, name) is not getattr(FabAuthManager, name), name


def _recording_manager(captured, allowed=True):
    class RecordingClient:
        def authorize(self, user, context, checks):
            captured["user"] = user
            captured["checks"] = checks
            return [Decision(id=checks[0].id, allowed=allowed, policy_id=1)]

    return RangerAuthManager(client=RecordingClient())


def test_each_resource_type_sends_its_own_key():
    """Each details class names its key differently.

    A copy-paste slip here would send the wrong field, or None, and silently
    widen the policy match.
    """
    cases = [
        (
            "is_authorized_connection",
            {"details": ConnectionDetails(conn_id="prod_db")},
            "connection",
            "prod_db",
        ),
        ("is_authorized_variable", {"details": VariableDetails(key="api_token")}, "variable", "api_token"),
        ("is_authorized_pool", {"details": PoolDetails(name="default_pool")}, "pool", "default_pool"),
        ("is_authorized_asset", {"details": AssetDetails(id="s3://bucket/x")}, "asset", "s3://bucket/x"),
        ("is_authorized_asset_alias", {"details": AssetAliasDetails(id="alias_1")}, "asset_alias", "alias_1"),
        ("is_authorized_configuration", {"details": ConfigurationDetails(section="core")}, "config", "core"),
    ]
    for method_name, kwargs, resource_type, expected_key in cases:
        captured = {}
        manager = _recording_manager(captured)
        assert getattr(manager, method_name)(method="GET", user=_User(), **kwargs) is True
        check = captured["checks"][0]
        assert check.resource_type == resource_type, method_name
        assert check.key == expected_key, method_name
        assert check.method == "GET", method_name
        assert check.access_entity is None, method_name


def test_view_sends_access_view_as_the_key_not_an_access_entity():
    # AccessMapper rejects an access_entity on `view`, so IMPORT_ERRORS has to
    # arrive as the resource key. This is the /api/v2/importErrors path.
    captured = {}
    manager = _recording_manager(captured)
    assert manager.is_authorized_view(access_view=AccessView.IMPORT_ERRORS, user=_User()) is True
    check = captured["checks"][0]
    assert check.resource_type == "view"
    assert check.key == "IMPORT_ERRORS"
    assert check.access_entity is None
    assert check.method == "GET"


def test_custom_view_sends_resource_name_as_the_key():
    captured = {}
    manager = _recording_manager(captured)
    assert manager.is_authorized_custom_view(method="GET", resource_name="MyPluginView", user=_User()) is True
    check = captured["checks"][0]
    assert check.resource_type == "custom_view"
    assert check.key == "MyPluginView"


def test_non_dag_resources_omit_the_key_when_no_details_given():
    for method_name, resource_type in (
        ("is_authorized_connection", "connection"),
        ("is_authorized_variable", "variable"),
        ("is_authorized_pool", "pool"),
        ("is_authorized_asset", "asset"),
        ("is_authorized_asset_alias", "asset_alias"),
        ("is_authorized_configuration", "config"),
    ):
        captured = {}
        manager = _recording_manager(captured)
        assert getattr(manager, method_name)(method="GET", user=_User()) is True
        check = captured["checks"][0]
        assert check.resource_type == resource_type, method_name
        assert check.key is None, method_name
        assert "key" not in check.to_payload(), method_name


def test_every_resource_type_fails_closed_before_init():
    manager = RangerAuthManager()
    assert manager.is_authorized_connection(method="GET", user=_User()) is False
    assert manager.is_authorized_variable(method="GET", user=_User()) is False
    assert manager.is_authorized_pool(method="GET", user=_User()) is False
    assert manager.is_authorized_asset(method="GET", user=_User()) is False
    assert manager.is_authorized_asset_alias(method="GET", user=_User()) is False
    assert manager.is_authorized_configuration(method="GET", user=_User()) is False
    assert manager.is_authorized_view(access_view=AccessView.JOBS, user=_User()) is False
    assert manager.is_authorized_custom_view(method="GET", resource_name="X", user=_User()) is False


def test_every_resource_type_fails_closed_when_client_raises():
    client = MagicMock()
    client.authorize.side_effect = RuntimeError("boom")
    manager = RangerAuthManager(client=client)
    assert manager.is_authorized_connection(method="GET", user=_User()) is False
    assert manager.is_authorized_variable(method="DELETE", user=_User()) is False
    assert manager.is_authorized_pool(method="POST", user=_User()) is False
    assert manager.is_authorized_view(access_view=AccessView.JOBS, user=_User()) is False


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
