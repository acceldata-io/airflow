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

import pytest

from odp_airflow_ranger_auth_manager.config import RangerClientConfig, load_token
from odp_airflow_ranger_auth_manager.exceptions import RangerAuthzConfigError


def _write_token(path, content: str, mode: int = 0o400) -> str:
    path.write_text(content, encoding="utf-8")
    os.chmod(path, mode)
    return str(path)


def test_load_token_reads_0400_file(tmp_path):
    path = _write_token(tmp_path / "token", "a" * 32)
    assert load_token(path) == "a" * 32


def test_load_token_rejects_group_readable(tmp_path):
    path = _write_token(tmp_path / "token", "a" * 32, mode=stat.S_IRUSR | stat.S_IRGRP)
    with pytest.raises(RangerAuthzConfigError, match="0400"):
        load_token(path)


def test_load_token_rejects_short_secret(tmp_path):
    path = _write_token(tmp_path / "token", "too-short")
    with pytest.raises(RangerAuthzConfigError, match="32"):
        load_token(path)


def test_load_token_rejects_missing(tmp_path):
    with pytest.raises(RangerAuthzConfigError, match="missing"):
        load_token(tmp_path / "nope")


def test_config_strips_trailing_slash():
    cfg = RangerClientConfig(agent_url="http://127.0.0.1:9183/", token="a" * 32)
    assert cfg.agent_url == "http://127.0.0.1:9183"
