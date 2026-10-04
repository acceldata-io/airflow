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


def test_handshake_refuses_missing_filter_capability(agent):
    # An agent predating /v1/filter must be rejected at startup, not on the
    # first Dag list load.
    agent.info_body["capabilities"] = ["authorize"]
    with pytest.raises(RangerAuthzHandshakeError, match="filter"):
        _client(agent).handshake("3.2.2")


def test_handshake_reports_every_missing_capability(agent):
    agent.info_body["capabilities"] = []
    with pytest.raises(RangerAuthzHandshakeError) as excinfo:
        _client(agent).handshake("3.2.2")
    assert "authorize" in str(excinfo.value)
    assert "filter" in str(excinfo.value)


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
        RangerClientConfig(
            agent_url="http://127.0.0.1:1", token=TOKEN, connect_timeout=0.05, read_timeout=0.05
        )
    )
    decisions = client.authorize(
        "alice",
        RequestContext(client_ip="1.1.1.1", request_uri="/"),
        [AuthorizeCheck(id="0", resource_type="dag", method="GET", key="x")],
    )
    assert decisions[0].allowed is False


# --- /v1/filter ----------------------------------------------------------


def _ctx() -> RequestContext:
    return RequestContext(client_ip="10.4.2.19", request_uri="/api/v2/dags")


def test_filter_returns_only_permitted_keys(agent):
    agent.filter_allowed = {"etl_0001", "etl_0002"}
    allowed = _client(agent).filter_keys(
        "spark", _ctx(), "dag", "GET", ["etl_0001", "finance_0001", "etl_0002", "mktg_0001"]
    )
    assert allowed == frozenset({"etl_0001", "etl_0002"})

    sent = agent.filter_calls[0]
    assert sent["resource_type"] == "dag"
    assert sent["method"] == "GET"
    assert sent["user"] == "spark"
    assert sent["context"]["client_ip"] == "10.4.2.19"
    assert "access_entity" not in sent


def test_filter_passes_access_entity_when_given(agent):
    _client(agent).filter_keys("spark", _ctx(), "dag", "GET", ["etl_0001"], access_entity="TASK_LOGS")
    assert agent.filter_calls[0]["access_entity"] == "TASK_LOGS"


def test_filter_deduplicates_and_drops_blanks(agent):
    allowed = _client(agent).filter_keys(
        "spark", _ctx(), "dag", "GET", ["etl_0001", "etl_0001", "", "etl_0002"]
    )
    assert allowed == frozenset({"etl_0001", "etl_0002"})
    assert agent.filter_calls[0]["keys"] == ["etl_0001", "etl_0002"]


def test_filter_returns_empty_without_calling_the_agent(agent):
    assert _client(agent).filter_keys("spark", _ctx(), "dag", "GET", []) == frozenset()
    assert agent.filter_calls == []


def test_filter_chunks_beyond_the_contract_cap(agent):
    keys = [f"etl_{i:05d}" for i in range(6000)]
    agent.filter_allowed = {"etl_00001", "etl_05999"}

    allowed = _client(agent).filter_keys("spark", _ctx(), "dag", "GET", keys)

    assert allowed == frozenset({"etl_00001", "etl_05999"})
    assert len(agent.filter_calls) == 2, "6000 keys must split at the 5000-key cap"
    assert len(agent.filter_calls[0]["keys"]) == 5000
    assert len(agent.filter_calls[1]["keys"]) == 1000
    # Nothing dropped between the chunks.
    sent = agent.filter_calls[0]["keys"] + agent.filter_calls[1]["keys"]
    assert sent == keys


@pytest.mark.parametrize("status", [401, 422, 500, 503])
def test_filter_fails_closed_on_non_200(agent, status):
    agent.filter_status = status
    agent.filter_body = {"error": "nope"}
    assert _client(agent).filter_keys("spark", _ctx(), "dag", "GET", ["etl_0001"]) == frozenset()


def test_filter_fails_closed_on_transport_error(agent):
    agent.stop()  # nothing listening
    assert _client(agent).filter_keys("spark", _ctx(), "dag", "GET", ["etl_0001"]) == frozenset()


def test_filter_fails_closed_on_timeout(agent):
    agent.sleep_s = 0.5
    client = _client(agent, read_timeout=0.05)
    assert client.filter_keys("spark", _ctx(), "dag", "GET", ["etl_0001"]) == frozenset()


@pytest.mark.parametrize(
    "body",
    [
        {"policy_version": 1},  # allowed_keys missing
        {"allowed_keys": "etl_0001"},  # not a list
        {"allowed_keys": [{"dag": "etl_0001"}]},  # wrong element shape
    ],
)
def test_filter_fails_closed_on_malformed_response(agent, body):
    agent.filter_body = body
    assert _client(agent).filter_keys("spark", _ctx(), "dag", "GET", ["etl_0001"]) == frozenset()


def test_filter_rejects_keys_that_were_not_requested(agent):
    # A broken or impersonating agent must not be able to widen the result.
    agent.filter_body = {"allowed_keys": ["etl_0001", "finance_0001"]}
    assert _client(agent).filter_keys("spark", _ctx(), "dag", "GET", ["etl_0001"]) == frozenset()


def test_filter_failure_in_one_chunk_denies_the_whole_call(agent):
    keys = [f"etl_{i:05d}" for i in range(6000)]
    agent.filter_status = 500
    assert _client(agent).filter_keys("spark", _ctx(), "dag", "GET", keys) == frozenset()
