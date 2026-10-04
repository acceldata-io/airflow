#
# Copyright 2026 Acceldata Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#

"""End-user request context for the agent audit record.

``is_authorized_dag`` is not given the HTTP request. A FastAPI root middleware
(plugin entry point) stores it in a contextvar for the API path. Flask's
request is the fallback for FAB views running under WSGIMiddleware, where the
contextvar may not follow the worker thread.
"""

from __future__ import annotations

import ipaddress
import logging
from contextvars import ContextVar
from dataclasses import dataclass
from typing import Any, Iterable

from odp_airflow_ranger_auth_manager.constants import CONF_SECTION, CONF_TRUSTED_PROXIES

log = logging.getLogger(__name__)

_logged_fallback = False


@dataclass(frozen=True)
class RequestContext:
    client_ip: str
    request_uri: str
    request_id: str | None = None

    def to_payload(self) -> dict[str, str]:
        payload = {"client_ip": self.client_ip, "request_uri": self.request_uri}
        if self.request_id:
            payload["request_id"] = self.request_id
        return payload


_request_context: ContextVar[RequestContext | None] = ContextVar(
    "ranger_authz_request_context", default=None
)


def set_request_context(context: RequestContext):
    """Bind context for the current task. Returns a token for ``reset_request_context``."""
    return _request_context.set(context)


def reset_request_context(token) -> None:
    _request_context.reset(token)


def context_from_asgi_scope(
    scope: dict[str, Any],
    trusted_proxies: Iterable[str] | None = None,
) -> RequestContext:
    headers = {
        key.decode("latin-1").lower(): value.decode("latin-1")
        for key, value in scope.get("headers", [])
    }
    client = scope.get("client")
    peer = client[0] if client else ""
    client_ip = _client_ip(peer, headers.get("x-forwarded-for"), trusted_proxies)
    path = scope.get("path") or "/"
    request_id = headers.get("x-request-id") or None
    return RequestContext(
        client_ip=client_ip,
        request_uri=path,
        request_id=request_id,
    )


def _from_flask() -> RequestContext | None:
    try:
        from flask import has_request_context, request
    except Exception:
        return None
    if not has_request_context():
        return None
    client_ip = _client_ip(
        request.remote_addr or "",
        request.headers.get("X-Forwarded-For"),
        None,
    )
    request_id = request.headers.get("X-Request-Id") or request.headers.get("X-Request-ID")
    return RequestContext(
        client_ip=client_ip,
        request_uri=request.path or "/",
        request_id=request_id or None,
    )


def _load_trusted_proxies() -> tuple[str, ...]:
    try:
        from airflow.configuration import conf

        raw = conf.get(CONF_SECTION, CONF_TRUSTED_PROXIES, fallback="") or ""
    except Exception:
        return ()
    return tuple(part.strip() for part in raw.split(",") if part.strip())


def _peer_is_trusted(peer: str, trusted: Iterable[str]) -> bool:
    if not peer:
        return False
    try:
        addr = ipaddress.ip_address(peer)
    except ValueError:
        return peer in set(trusted)
    for item in trusted:
        try:
            if "/" in item:
                if addr in ipaddress.ip_network(item, strict=False):
                    return True
            elif addr == ipaddress.ip_address(item):
                return True
        except ValueError:
            if peer == item:
                return True
    return False


def _client_ip(
    peer: str,
    forwarded: str | None,
    trusted_proxies: Iterable[str] | None,
) -> str:
    trusted = tuple(trusted_proxies) if trusted_proxies is not None else _load_trusted_proxies()
    if forwarded and _peer_is_trusted(peer, trusted):
        hop = forwarded.split(",")[0].strip()
        if hop:
            return hop
    return peer or "0.0.0.0"


def current_request_context() -> RequestContext:
    bound = _request_context.get()
    if bound is not None:
        return bound
    flask_ctx = _from_flask()
    if flask_ctx is not None:
        return flask_ctx
    global _logged_fallback
    if not _logged_fallback:
        log.warning(
            "ranger authz request context missing; falling back to client_ip=0.0.0.0 request_uri=/"
        )
        _logged_fallback = True
    return RequestContext(client_ip="0.0.0.0", request_uri="/")


class RequestContextMiddleware:
    """ASGI middleware that records client IP and path for the agent audit record."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return
        token = set_request_context(context_from_asgi_scope(scope))
        try:
            await self.app(scope, receive, send)
        finally:
            reset_request_context(token)
