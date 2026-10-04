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

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from typing import Any


TOKEN = "a" * 32

INFO_OK = {
    "agent_version": "1.0.0",
    "contract_version": "v1",
    "ranger_service": "odp_airflow",
    "service_def_version": 3,
    "supported_airflow": ">=3.2,<3.3",
    "capabilities": ["authorize"],
    "user_store_version": 9,
}


class FakeAgent:
    def __init__(self, token: str = TOKEN):
        self.token = token
        self.authorize_status = 200
        self.authorize_body: dict[str, Any] | None = None
        self.info_status = 200
        self.info_body: dict[str, Any] = dict(INFO_OK)
        self.sleep_s = 0.0
        self.last_authorize: dict[str, Any] | None = None
        self.last_headers: dict[str, str] | None = None
        handler = self._handler()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self) -> str:
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}"

    def start(self) -> FakeAgent:
        self.thread.start()
        return self

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def _handler(self):
        agent = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                return

            def do_GET(self):
                if self.path != "/v1/info":
                    self._send(404, {"error": "not_found"})
                    return
                if not self._authorized():
                    self._send(401, {"error": "unauthorized"})
                    return
                self._send(agent.info_status, agent.info_body)

            def do_POST(self):
                if self.path != "/v1/authorize":
                    self._send(404, {"error": "not_found"})
                    return
                if not self._authorized():
                    self._send(401, {"error": "unauthorized"})
                    return
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length) if length else b"{}"
                agent.last_authorize = json.loads(raw.decode("utf-8"))
                if agent.sleep_s:
                    import time

                    time.sleep(agent.sleep_s)
                body = agent.authorize_body
                if body is None:
                    checks = agent.last_authorize.get("checks") or []
                    body = {
                        "policy_version": 1,
                        "decisions": [
                            {"id": check["id"], "allowed": True, "policy_id": 47} for check in checks
                        ],
                    }
                self._send(agent.authorize_status, body)

            def _authorized(self) -> bool:
                agent.last_headers = {k.lower(): v for k, v in self.headers.items()}
                return self.headers.get("Authorization") == f"Bearer {agent.token}"

            def _send(self, status: int, body: dict[str, Any]):
                data = json.dumps(body).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        return Handler
