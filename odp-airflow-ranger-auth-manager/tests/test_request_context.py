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

from odp_airflow_ranger_auth_manager.request_context import (
    RequestContext,
    context_from_asgi_scope,
    current_request_context,
    reset_request_context,
    set_request_context,
)


def test_context_uses_x_forwarded_for_only_from_trusted_proxy():
    scope = {
        "type": "http",
        "path": "/api/v2/dags/etl_sales",
        "client": ("10.0.0.1", 443),
        "headers": [
            (b"x-forwarded-for", b"10.4.2.19, 10.0.0.1"),
            (b"x-request-id", b"abc"),
        ],
    }
    trusted = context_from_asgi_scope(scope, trusted_proxies=("10.0.0.1",))
    assert trusted.client_ip == "10.4.2.19"
    assert trusted.request_uri == "/api/v2/dags/etl_sales"
    assert trusted.request_id == "abc"

    spoofed = context_from_asgi_scope(scope, trusted_proxies=())
    assert spoofed.client_ip == "10.0.0.1"


def test_context_falls_back_to_peer():
    ctx = context_from_asgi_scope(
        {
            "type": "http",
            "path": "/api/v2/dags",
            "client": ("127.0.0.1", 12345),
            "headers": [],
        }
    )
    assert ctx.client_ip == "127.0.0.1"
    assert ctx.request_uri == "/api/v2/dags"


def test_current_request_context_uses_contextvar():
    token = set_request_context(RequestContext(client_ip="8.8.8.8", request_uri="/ui"))
    try:
        assert current_request_context().client_ip == "8.8.8.8"
        assert current_request_context().request_uri == "/ui"
    finally:
        reset_request_context(token)


def test_fallback_when_unbound():
    ctx = current_request_context()
    assert ctx.client_ip == "0.0.0.0"
    assert ctx.request_uri == "/"


def test_middleware_resolves_trusted_proxies_once_not_per_request():
    """The list cannot change while the process runs, so reading it per
    request put an Airflow config lookup on the hot path of every
    api-server request."""
    import asyncio

    import odp_airflow_ranger_auth_manager.request_context as rc

    calls = {"n": 0}
    original = rc._load_trusted_proxies

    def counting():
        calls["n"] += 1
        return ("10.0.0.1",)

    rc._load_trusted_proxies = counting
    try:
        mw = rc.RequestContextMiddleware(_noop_app)
        assert calls["n"] == 1, "constructing the middleware should resolve the list once"
        for _ in range(5):
            asyncio.run(
                mw(
                    {"type": "http", "path": "/api/v2/dags", "headers": [], "client": ("10.0.0.1", 1)},
                    None,
                    None,
                )
            )
        assert calls["n"] == 1, f"expected 1 config read for 5 requests, got {calls['n']}"
    finally:
        rc._load_trusted_proxies = original


def test_middleware_still_honours_trusted_proxies_after_caching():
    import asyncio

    import odp_airflow_ranger_auth_manager.request_context as rc

    seen = {}

    async def capture(scope, receive, send):
        seen["ctx"] = rc.current_request_context()

    scope = {
        "type": "http",
        "path": "/api/v2/dags",
        "headers": [(b"x-forwarded-for", b"203.0.113.9")],
        "client": ("10.0.0.1", 1),
    }
    # peer IS a trusted proxy -> believe the forwarded header
    asyncio.run(rc.RequestContextMiddleware(capture, trusted_proxies=["10.0.0.1"])(scope, None, None))
    assert seen["ctx"].client_ip == "203.0.113.9"

    # peer is NOT trusted -> record the peer, never the claim
    asyncio.run(rc.RequestContextMiddleware(capture, trusted_proxies=["192.0.2.1"])(scope, None, None))
    assert seen["ctx"].client_ip == "10.0.0.1"


async def _noop_app(scope, receive, send):
    return None
