"""The service's configuration: one secret, one config object, one block.

container_config.env names all three:

    AWS_SECRET_NAME   the Secrets Manager secret - credentials and API keys only:
                      {"credentials": {"<id>": {"username": ..., "password": ...}},
                       "api_keys": {"<id>": "<key>"}}
    CONFIG_BUCKET     the config object in S3: every other setting, as JSON
    CONFIG_KEY
    CONFIG_BLOCK      the block of the config object this deployment runs

A block may name a PROFILE from the object's "profiles"; the block's own keys
win over its profile's. A setting ending in _CREDENTIAL holds a credential id,
looked up in the secret - so the same user name can sit under two ids with a
different password each.

With MODE=local nothing is read from AWS: the config object is the local copy,
services/<basename of CONFIG_KEY>, and there are no credentials or API keys. A
local run needs no environment set up: CONFIG_KEY and CONFIG_BLOCK it does not
have are read from container_config.env, the file ECS loads when deployed.

Read once, at startup: get_config() caches it, so a change takes a restart.
"""

import json
import os
from dataclasses import dataclass, field
from functools import cache
from pathlib import Path

import boto3
from gig_utils_security.secrets import get_secret_value

CREDENTIAL_SUFFIX = "_CREDENTIAL"
ENV_FILE = "container_config.env"


@dataclass(frozen=True)
class Config:
    block: str
    settings: dict
    credentials: dict = field(default_factory=dict)
    api_keys: dict = field(default_factory=dict)


def resolve_block(data, block_name):
    """The block's settings, on top of its PROFILE's."""
    if block_name not in data:
        raise ValueError(f"the config object has no block {block_name!r}")
    block = data[block_name]
    if not isinstance(block, dict):
        raise TypeError(f"block {block_name!r} is not a JSON object")
    profile_name = block.get("PROFILE")
    if not profile_name:
        return dict(block)
    profiles = data.get("profiles", {})
    if profile_name not in profiles:
        raise ValueError(f"block {block_name!r} names profile {profile_name!r}, which the config object does not have")
    profile = profiles[profile_name]
    if not isinstance(profile, dict):
        raise TypeError(f"profile {profile_name!r} is not a JSON object")
    return {**profile, **block}


def check_credentials(settings, credentials):
    """Every *_CREDENTIAL setting names a credential the secret holds."""
    missing = [
        f"{key}={value}"
        for key, value in settings.items()
        if key.endswith(CREDENTIAL_SUFFIX) and value not in credentials
    ]
    if missing:
        raise ValueError(f"credential ids not in the secret: {', '.join(missing)}")


def setting(name, local):
    """An environment variable; for a local run, else container_config.env's."""
    value = os.getenv(name, "")
    if value or not local or not Path(ENV_FILE).exists():
        return value
    for line in Path(ENV_FILE).read_text().splitlines():
        if line.startswith(f"{name}="):
            return line.split("=", 1)[1].strip()
    return ""


def read_config_object(local):
    key = setting("CONFIG_KEY", local)
    if local:
        if not key:
            raise ValueError("CONFIG_KEY is not set")
        return Path("services", Path(key).name).read_text()
    bucket = os.getenv("CONFIG_BUCKET", "")
    if not bucket or not key:
        raise ValueError("CONFIG_BUCKET and CONFIG_KEY must both be set")
    body = boto3.client("s3").get_object(Bucket=bucket, Key=key)["Body"]
    return body.read().decode()


def read_secret():
    name = os.getenv("AWS_SECRET_NAME", "")
    if not name:
        return {}
    return json.loads(get_secret_value(name))


def load_config(local):
    block_name = setting("CONFIG_BLOCK", local)
    if not block_name:
        raise ValueError("CONFIG_BLOCK is not set")
    settings = resolve_block(json.loads(read_config_object(local)), block_name)
    if local:
        return Config(block=block_name, settings=settings)
    secret = read_secret()
    credentials = secret.get("credentials", {})
    check_credentials(settings, credentials)
    return Config(block_name, settings, credentials, secret.get("api_keys", {}))


@cache
def get_config(local):
    return load_config(local)


def credential(config, setting):
    """The {"username", "password"} a *_CREDENTIAL setting names."""
    return config.credentials[config.settings[setting]]
