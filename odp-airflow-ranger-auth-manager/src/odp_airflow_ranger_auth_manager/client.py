#
# Copyright 2026 Acceldata Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#

"""Thin HTTP client for the colocated Ranger authz agent.

Speaks Airflow vocabulary only. Fail-closed: every non-200, timeout, connection
error and parse failure is a deny. No retries.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Any

import urllib3
from packaging.specifiers import InvalidSpecifier, SpecifierSet
from packaging.version import InvalidVersion, Version
from urllib3.exceptions import HTTPError as Urllib3HTTPError
from urllib3.util.timeout import Timeout

from odp_airflow_ranger_auth_manager.config import RangerClientConfig
from odp_airflow_ranger_auth_manager.constants import CONTRACT_VERSION, REQUIRED_CAPABILITY
from odp_airflow_ranger_auth_manager.exceptions import RangerAuthzHandshakeError
from odp_airflow_ranger_auth_manager.request_context import RequestContext

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class AuthorizeCheck:
    id: str
    resource_type: str
    method: str
    access_entity: str | None = None
    key: str | None = None

    def to_payload(self) -> dict[str, str]:
        payload = {
            "id": self.id,
            "resource_type": self.resource_type,
            "method": self.method,
        }
        if self.access_entity:
            payload["access_entity"] = self.access_entity
        if self.key:
            payload["key"] = self.key
        return payload


@dataclass(frozen=True)
class Decision:
    id: str
    allowed: bool
    policy_id: int | None = None
    reason: str | None = None


@dataclass(frozen=True)
class AgentInfo:
    agent_version: str
    contract_version: str
    ranger_service: str
    supported_airflow: str
    capabilities: tuple[str, ...]
    service_def_version: int | None = None
    user_store_version: int | None = None


class RangerAuthzClient:
    def __init__(self, config: RangerClientConfig, http=None):
        self._config = config
        self._http = http or urllib3.PoolManager(
            retries=False,
            timeout=Timeout(connect=config.connect_timeout, read=config.read_timeout),
        )

    def handshake(self, airflow_version: str) -> AgentInfo:
        """GET /v1/info. Raises on mismatch so the api-server refuses to start."""
        status, body = self._request("GET", "/v1/info")
        if status != 200 or not isinstance(body, dict):
            raise RangerAuthzHandshakeError(f"/v1/info returned {status}, expected 200")
        info = _parse_info(body)
        if info.contract_version != CONTRACT_VERSION:
            raise RangerAuthzHandshakeError(
                f"contract_version {info.contract_version!r} is not {CONTRACT_VERSION!r}"
            )
        if REQUIRED_CAPABILITY not in info.capabilities:
            raise RangerAuthzHandshakeError(
                f"agent capabilities {list(info.capabilities)} do not include {REQUIRED_CAPABILITY!r}"
            )
        if not _airflow_supported(info.supported_airflow, airflow_version):
            raise RangerAuthzHandshakeError(
                f"Airflow {airflow_version} is outside agent supported_airflow {info.supported_airflow!r}"
            )
        log.info(
            "ranger authz handshake ok: agent_version=%s contract=%s service=%s",
            info.agent_version,
            info.contract_version,
            info.ranger_service,
        )
        return info

    def authorize(
        self,
        user: str,
        context: RequestContext,
        checks: list[AuthorizeCheck],
    ) -> list[Decision]:
        if not checks:
            return []
        payload = {
            "user": user,
            "context": context.to_payload(),
            "checks": [check.to_payload() for check in checks],
        }
        try:
            status, body = self._request("POST", "/v1/authorize", payload)
        except Exception:
            log.warning("ranger authorize transport error; denying", exc_info=True)
            return _deny_all(checks, "transport_error")
        if status != 200 or not isinstance(body, dict):
            log.warning("ranger authorize returned %s; denying", status)
            return _deny_all(checks, "non_200")
        decisions = _parse_decisions(body, checks)
        if decisions is None:
            log.warning("ranger authorize response malformed; denying")
            return _deny_all(checks, "malformed_response")
        return decisions

    def _request(self, method: str, path: str, json_body: dict[str, Any] | None = None) -> tuple[int, Any]:
        headers = {
            "Authorization": f"Bearer {self._config.token}",
            "Accept": "application/json",
        }
        body = None
        if json_body is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(json_body).encode("utf-8")
        try:
            resp = self._http.request(
                method,
                f"{self._config.agent_url}{path}",
                body=body,
                headers=headers,
                timeout=Timeout(
                    connect=self._config.connect_timeout,
                    read=self._config.read_timeout,
                ),
            )
        except Urllib3HTTPError as exc:
            raise RangerAuthzHandshakeError(f"{method} {path} failed: {exc}") from exc
        parsed: Any = None
        if resp.data:
            try:
                parsed = json.loads(resp.data.decode("utf-8"))
            except json.JSONDecodeError:
                parsed = None
        return int(resp.status), parsed


def _parse_info(body: dict[str, Any]) -> AgentInfo:
    capabilities = body.get("capabilities") or []
    if not isinstance(capabilities, list):
        capabilities = []
    return AgentInfo(
        agent_version=str(body.get("agent_version") or ""),
        contract_version=str(body.get("contract_version") or ""),
        ranger_service=str(body.get("ranger_service") or ""),
        supported_airflow=str(body.get("supported_airflow") or ""),
        capabilities=tuple(str(item) for item in capabilities),
        service_def_version=_optional_int(body.get("service_def_version")),
        user_store_version=_optional_int(body.get("user_store_version")),
    )


def _airflow_supported(supported: str, airflow_version: str) -> bool:
    try:
        spec = SpecifierSet(supported)
        version = Version(airflow_version)
    except (InvalidSpecifier, InvalidVersion, TypeError):
        return False
    return version in spec


def _optional_int(value: Any) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _parse_decisions(body: dict[str, Any], checks: list[AuthorizeCheck]) -> list[Decision] | None:
    raw = body.get("decisions")
    if not isinstance(raw, list) or len(raw) != len(checks):
        return None
    ordered = []
    for check, item in zip(checks, raw):
        if not isinstance(item, dict) or "allowed" not in item:
            return None
        if str(item.get("id", "")) != check.id:
            return None
        ordered.append(
            Decision(
                id=check.id,
                allowed=bool(item["allowed"]),
                policy_id=_optional_int(item.get("policy_id")),
                reason=str(item["reason"]) if item.get("reason") is not None else None,
            )
        )
    return ordered


def _deny_all(checks: list[AuthorizeCheck], reason: str) -> list[Decision]:
    return [Decision(id=check.id, allowed=False, reason=reason) for check in checks]
