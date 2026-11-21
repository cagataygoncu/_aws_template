"""The config object as shipped: a broken services/*.json fails the build."""

import json
from pathlib import Path

import pytest

from src import config


def env_file_value(name, path="container_config.env"):
    for line in Path(path).read_text().splitlines():
        if line.startswith(f"{name}="):
            return line.split("=", 1)[1].strip()
    return ""


def test_shipped_config_resolves(monkeypatch):
    """The block container_config.env picks resolves from the shipped object."""
    monkeypatch.delenv("CONFIG_KEY", raising=False)
    monkeypatch.delenv("CONFIG_BLOCK", raising=False)
    cfg = config.load_config(local=True)  # both read from container_config.env
    assert cfg.settings, "the block resolved to no settings"


def test_block_wins_over_profile():
    data = {"profiles": {"p": {"A": 1, "B": 1}}, "blk": {"PROFILE": "p", "B": 2}}
    assert config.resolve_block(data, "blk") == {"A": 1, "B": 2, "PROFILE": "p"}


def test_missing_block_and_profile_fail():
    with pytest.raises(ValueError, match="no block"):
        config.resolve_block({}, "blk")
    with pytest.raises(ValueError, match="names profile"):
        config.resolve_block({"blk": {"PROFILE": "nope"}}, "blk")


def test_unknown_credential_fails():
    with pytest.raises(ValueError, match="X_CREDENTIAL=cred_9"):
        config.check_credentials({"X_CREDENTIAL": "cred_9"}, {"cred_1": {}})


def test_shipped_object_is_json():
    key = env_file_value("CONFIG_KEY")
    json.loads(Path("services", Path(key).name).read_text())
