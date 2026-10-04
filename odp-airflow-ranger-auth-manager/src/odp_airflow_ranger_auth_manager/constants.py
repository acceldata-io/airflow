#
# Copyright 2026 Acceldata Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#

"""Config keys and contract constants. Keep in lockstep with the agent api-v1.md."""

from __future__ import annotations

CONF_SECTION = "ranger"
CONF_AGENT_URL = "agent_url"
CONF_TOKEN_FILE = "token_file"
CONF_CONNECT_TIMEOUT = "connect_timeout"
CONF_READ_TIMEOUT = "read_timeout"
CONF_TRUSTED_PROXIES = "trusted_proxies"

DEFAULT_AGENT_URL = "http://127.0.0.1:9183"
DEFAULT_TOKEN_FILE = "/etc/airflow/ranger-authz-agent.token"
DEFAULT_CONNECT_TIMEOUT = 0.2
DEFAULT_READ_TIMEOUT = 2.0

CONTRACT_VERSION = "v1"
REQUIRED_CAPABILITY = "authorize"
MIN_TOKEN_BYTES = 32

# Keys per /v1/filter call. The agent rejects more with a 400, so the client
# splits anything larger -- get_authorized_dag_ids can carry a whole deployment.
MAX_FILTER_KEYS = 5000

# Resource types the agent understands. Named here so the authorization methods
# cannot drift from the agent's vocabulary one hardcoded string at a time.
RESOURCE_TYPE_DAG = "dag"
RESOURCE_TYPE_CONNECTION = "connection"
RESOURCE_TYPE_VARIABLE = "variable"
RESOURCE_TYPE_POOL = "pool"
RESOURCE_TYPE_ASSET = "asset"
RESOURCE_TYPE_ASSET_ALIAS = "asset_alias"
RESOURCE_TYPE_CONFIG = "config"
RESOURCE_TYPE_VIEW = "view"
RESOURCE_TYPE_CUSTOM_VIEW = "custom_view"
