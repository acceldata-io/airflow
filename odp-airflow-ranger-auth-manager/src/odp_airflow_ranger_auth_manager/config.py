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

import os
import stat
from dataclasses import dataclass
from pathlib import Path

from odp_airflow_ranger_auth_manager.constants import (
    CONF_AGENT_URL,
    CONF_CONNECT_TIMEOUT,
    CONF_READ_TIMEOUT,
    CONF_SECTION,
    CONF_TOKEN_FILE,
    DEFAULT_AGENT_URL,
    DEFAULT_CONNECT_TIMEOUT,
    DEFAULT_READ_TIMEOUT,
    DEFAULT_TOKEN_FILE,
    MIN_TOKEN_BYTES,
)
from odp_airflow_ranger_auth_manager.exceptions import RangerAuthzConfigError


def load_token(token_file: str | os.PathLike[str]) -> str:
    """Read the shared secret. Matches the agent's SharedSecret.fromFile checks."""
    path = Path(token_file)
    if not path.is_file():
        raise RangerAuthzConfigError(f"token file missing or not a file: {path}")
    mode = path.stat().st_mode
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        raise RangerAuthzConfigError(f"token file {path} must be mode 0400 (no group/other bits)")
    token = path.read_text(encoding="utf-8").strip()
    if not token:
        raise RangerAuthzConfigError(f"token file is empty: {path}")
    if len(token.encode("utf-8")) < MIN_TOKEN_BYTES:
        raise RangerAuthzConfigError(
            f"shared secret is {len(token.encode('utf-8'))} bytes; need at least {MIN_TOKEN_BYTES}"
        )
    return token


@dataclass(frozen=True)
class RangerClientConfig:
    agent_url: str
    token: str
    connect_timeout: float = DEFAULT_CONNECT_TIMEOUT
    read_timeout: float = DEFAULT_READ_TIMEOUT

    def __post_init__(self) -> None:
        url = self.agent_url.rstrip("/")
        object.__setattr__(self, "agent_url", url)
        if not url:
            raise RangerAuthzConfigError("agent_url must not be empty")
        if self.connect_timeout <= 0 or self.read_timeout <= 0:
            raise RangerAuthzConfigError("timeouts must be positive")
        if len(self.token.encode("utf-8")) < MIN_TOKEN_BYTES:
            raise RangerAuthzConfigError(
                f"shared secret is {len(self.token.encode('utf-8'))} bytes; need at least {MIN_TOKEN_BYTES}"
            )

    @classmethod
    def from_airflow_conf(cls) -> RangerClientConfig:
        from airflow.configuration import conf

        url = conf.get(CONF_SECTION, CONF_AGENT_URL, fallback=DEFAULT_AGENT_URL)
        token_file = conf.get(CONF_SECTION, CONF_TOKEN_FILE, fallback=DEFAULT_TOKEN_FILE)
        connect = conf.getfloat(CONF_SECTION, CONF_CONNECT_TIMEOUT, fallback=DEFAULT_CONNECT_TIMEOUT)
        read = conf.getfloat(CONF_SECTION, CONF_READ_TIMEOUT, fallback=DEFAULT_READ_TIMEOUT)
        return cls(
            agent_url=url,
            token=load_token(token_file),
            connect_timeout=connect,
            read_timeout=read,
        )
