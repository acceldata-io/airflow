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

import importlib
import sys
from types import ModuleType


def _stub_airflow_plugins_manager() -> None:
    """plugin.py subclasses AirflowPlugin, so the module must exist to import
    it at all. Everything else about Airflow is irrelevant here."""
    try:
        from airflow.plugins_manager import AirflowPlugin  # noqa: F401

        return
    except ImportError:
        pass

    for name in ("airflow", "airflow.plugins_manager"):
        if name not in sys.modules:
            mod = ModuleType(name)
            sys.modules[name] = mod
            parent, _, attr = name.rpartition(".")
            if parent:
                setattr(sys.modules[parent], attr, mod)

    class AirflowPlugin:
        name = ""

    sys.modules["airflow.plugins_manager"].AirflowPlugin = AirflowPlugin


_stub_airflow_plugins_manager()

import odp_airflow_ranger_auth_manager.plugin as plugin_mod  # noqa: E402


def _reload_with_auth_manager(value):
    """Reimport the plugin module with [core] auth_manager set to `value`.

    fastapi_root_middlewares is decided in the class body, so the decision
    is made at import -- which is exactly when Airflow's plugins_manager
    loads it.
    """
    conf_mod = ModuleType("airflow.configuration")

    class _Conf:
        @staticmethod
        def get(section, key, fallback=""):
            if (section, key) == ("core", "auth_manager"):
                if value is RuntimeError:
                    raise RuntimeError("config unavailable")
                return value
            return fallback

    conf_mod.conf = _Conf()
    saved = sys.modules.get("airflow.configuration")
    sys.modules["airflow.configuration"] = conf_mod
    try:
        return importlib.reload(plugin_mod)
    finally:
        if saved is None:
            sys.modules.pop("airflow.configuration", None)
        else:
            sys.modules["airflow.configuration"] = saved


def test_middleware_registers_when_ranger_is_the_auth_manager():
    m = _reload_with_auth_manager("odp_airflow_ranger_auth_manager.ranger_auth_manager.RangerAuthManager")
    assert len(m.RangerAuthzPlugin.fastapi_root_middlewares) == 1


def test_middleware_stays_out_of_airflow_when_ranger_is_not_enabled():
    """The wheel ships inside the ODP Airflow venv whether or not Ranger is
    enabled, and an entry point registers on install. Without this gate
    every ODP Airflow would run our middleware on every request."""
    m = _reload_with_auth_manager("airflow.providers.fab.auth_manager.fab_auth_manager.FabAuthManager")
    assert m.RangerAuthzPlugin.fastapi_root_middlewares == []


def test_unset_auth_manager_does_not_register():
    m = _reload_with_auth_manager("")
    assert m.RangerAuthzPlugin.fastapi_root_middlewares == []


def test_registers_when_the_config_cannot_be_read():
    """Fail towards registering: a redundant middleware costs one ASGI
    frame, a missing one silently drops the client IP from every audit
    record."""
    m = _reload_with_auth_manager(RuntimeError)
    assert len(m.RangerAuthzPlugin.fastapi_root_middlewares) == 1
