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

import pytest

from odp_airflow_ranger_auth_manager.client import AgentInfo, AuthorizeCheck, RangerAuthzClient
from odp_airflow_ranger_auth_manager.config import RangerClientConfig
from odp_airflow_ranger_auth_manager.exceptions import RangerAuthzHandshakeError
from odp_airflow_ranger_auth_manager.request_context import RequestContext
from fake_agent import TOKEN, FakeAgent


def _client(agent: FakeAgent, **kwargs) -> RangerAuthzClient:
    cfg = RangerClientConfig(
        agent_url=agent.url,
        token=kwargs.get("token", TOKEN),
        connect_timeout=kwargs.get("connect_timeout", 0.2),
        read_timeout=kwargs.get("read_timeout", 2.0),
    )
    return RangerAuthzClient(cfg)


@pytest.fixture
def agent():
    fake = FakeAgent().start()
    try:
        yield fake
    finally:
        fake.stop()


def test_handshake_accepts_matching_agent(agent):
    info = _client(agent).handshake("3.2.2")
    assert isinstance(info, AgentInfo)
    assert info.contract_version == "v1"
    assert "authorize" in info.capabilities


def test_handshake_refuses_contract_mismatch(agent):
    agent.info_body["contract_version"] = "v2"
    with pytest.raises(RangerAuthzHandshakeError, match="contract_version"):
        _client(agent).handshake("3.2.2")


def test_handshake_refuses_missing_authorize_capability(agent):
    agent.info_body["capabilities"] = ["filter"]
    with pytest.raises(RangerAuthzHandshakeError, match="authorize"):
        _client(agent).handshake("3.2.2")


def test_handshake_refuses_unsupported_airflow(agent):
    with pytest.raises(RangerAuthzHandshakeError, match="outside agent supported_airflow"):
        _client(agent).handshake("3.1.0")


def test_handshake_refuses_unauthorized(agent):
    with pytest.raises(RangerAuthzHandshakeError):
        _client(agent, token="b" * 32).handshake("3.2.2")


def test_authorize_allow_and_sends_airflow_vocabulary(agent):
    client = _client(agent)
    ctx = RequestContext(client_ip="10.4.2.19", request_uri="/api/v2/dags/etl_sales/dagRuns")
    checks = [
        AuthorizeCheck(
            id="0",
            resource_type="dag",
            method="POST",
            access_entity="RUN",
            key="etl_sales",
        )
    ]
    decisions = client.authorize("alice@CORP.EXAMPLE", ctx, checks)
    assert decisions[0].allowed is True
    assert decisions[0].policy_id == 47
    body = agent.last_authorize
    assert body["user"] == "alice@CORP.EXAMPLE"
    assert "groups" not in body
    assert body["context"]["client_ip"] == "10.4.2.19"
    assert body["context"]["request_uri"] == "/api/v2/dags/etl_sales/dagRuns"
    assert body["checks"] == [
        {
            "id": "0",
            "resource_type": "dag",
            "method": "POST",
            "access_entity": "RUN",
            "key": "etl_sales",
        }
    ]
    assert agent.last_headers["authorization"] == f"Bearer {TOKEN}"


def test_authorize_fail_closed_on_401(agent):
    agent.authorize_status = 401
    agent.authorize_body = {"error": "unauthorized"}
    decisions = _client(agent).authorize(
        "alice",
        RequestContext(client_ip="1.1.1.1", request_uri="/"),
        [AuthorizeCheck(id="0", resource_type="dag", method="GET", key="etl_sales")],
    )
    assert decisions[0].allowed is False


def test_authorize_fail_closed_on_503(agent):
    agent.authorize_status = 503
    agent.authorize_body = {"ready": False, "reason": "policies not loaded"}
    decisions = _client(agent).authorize(
        "alice",
        RequestContext(client_ip="1.1.1.1", request_uri="/"),
        [AuthorizeCheck(id="0", resource_type="dag", method="GET")],
    )
    assert decisions[0].allowed is False


def test_authorize_fail_closed_when_decision_ids_are_reordered(agent):
    agent.authorize_body = {
        "policy_version": 1,
        "decisions": [
            {"id": "1", "allowed": True, "policy_id": 2},
            {"id": "0", "allowed": False, "reason": "no_matching_policy"},
        ],
    }
    decisions = _client(agent).authorize(
        "alice",
        RequestContext(client_ip="1.1.1.1", request_uri="/"),
        [
            AuthorizeCheck(id="0", resource_type="dag", method="GET", key="a"),
            AuthorizeCheck(id="1", resource_type="dag", method="GET", key="b"),
        ],
    )
    assert all(d.allowed is False for d in decisions)


def test_authorize_fail_closed_on_malformed_decisions(agent):
    agent.authorize_body = {"policy_version": 1, "decisions": []}
    decisions = _client(agent).authorize(
        "alice",
        RequestContext(client_ip="1.1.1.1", request_uri="/"),
        [AuthorizeCheck(id="0", resource_type="dag", method="GET", key="x")],
    )
    assert decisions[0].allowed is False


def test_authorize_fail_closed_on_timeout(agent):
    agent.sleep_s = 0.4
    decisions = _client(agent, read_timeout=0.05).authorize(
        "alice",
        RequestContext(client_ip="1.1.1.1", request_uri="/"),
        [AuthorizeCheck(id="0", resource_type="dag", method="GET", key="x")],
    )
    assert decisions[0].allowed is False


def test_authorize_fail_closed_when_agent_down():
    client = RangerAuthzClient(
        RangerClientConfig(agent_url="http://127.0.0.1:1", token=TOKEN, connect_timeout=0.05, read_timeout=0.05)
    )
    decisions = client.authorize(
        "alice",
        RequestContext(client_ip="1.1.1.1", request_uri="/"),
        [AuthorizeCheck(id="0", resource_type="dag", method="GET", key="x")],
    )
    assert decisions[0].allowed is False
