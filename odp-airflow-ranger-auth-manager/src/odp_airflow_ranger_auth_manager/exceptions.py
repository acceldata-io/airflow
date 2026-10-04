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


class RangerAuthzError(Exception):
    """Base error for the Ranger authz client."""


class RangerAuthzConfigError(RangerAuthzError):
    """Invalid client configuration (token file, timeouts, URL)."""


class RangerAuthzHandshakeError(RangerAuthzError):
    """Startup handshake with the agent failed. Airflow must not serve traffic."""
