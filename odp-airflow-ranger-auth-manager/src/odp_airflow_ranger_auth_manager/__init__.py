#
# Copyright 2026 Acceldata Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#

"""Ranger authorization manager for Apache Airflow 3.2.x."""

from __future__ import annotations

__all__ = ["RangerAuthManager"]
__version__ = "0.1.0"


def __getattr__(name: str):
    if name == "RangerAuthManager":
        from odp_airflow_ranger_auth_manager.ranger_auth_manager import RangerAuthManager

        return RangerAuthManager
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
