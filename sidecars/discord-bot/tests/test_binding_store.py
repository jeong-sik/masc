"""Tests for durable Discord binding persistence."""

from __future__ import annotations

import json
import os
from pathlib import Path

from src.binding_store import BindingStore
from src.config import BotConfig


def test_binding_store_load_returns_none_when_missing(tmp_path: Path) -> None:
    store = BindingStore(tmp_path / "bindings.json")
    assert store.load() is None
    assert store.modified_time_ns() is None


def test_binding_store_round_trips_saved_bindings(tmp_path: Path) -> None:
    path = tmp_path / "nested" / "bindings.json"
    store = BindingStore(path)

    store.save({"123": "luna", "456": "sangsu"})

    assert store.load() == {"123": "luna", "456": "sangsu"}
    assert json.loads(path.read_text(encoding="utf-8")) == {
        "123": "luna",
        "456": "sangsu",
    }
    assert store.modified_time_ns() is not None


def test_binding_store_ignores_invalid_json(tmp_path: Path) -> None:
    path = tmp_path / "bindings.json"
    path.write_text("{invalid", encoding="utf-8")
    store = BindingStore(path)

    assert store.load() is None


def test_config_resolves_relative_binding_store_path(tmp_path: Path) -> None:
    base_path = tmp_path / "workspace"
    base_path.mkdir()
    cfg = BotConfig(
        discord_bot_token="test-token",
        gate_api_token="test-api-token",
        discord_binding_store_path="state/discord.json",
        discord_binding_audit_path="audit/discord.jsonl",
        discord_status_path="status/discord.json",
    )

    previous_base_path = os.getenv("MASC_BASE_PATH")
    original_cwd = Path.cwd()
    try:
        os.environ["MASC_BASE_PATH"] = str(base_path)
        os.chdir(tmp_path)
        assert cfg.binding_store_path() == base_path / "state" / "discord.json"
        assert cfg.binding_audit_path() == base_path / "audit" / "discord.jsonl"
        assert cfg.status_path() == base_path / "status" / "discord.json"
    finally:
        if previous_base_path is None:
            os.environ.pop("MASC_BASE_PATH", None)
        else:
            os.environ["MASC_BASE_PATH"] = previous_base_path
        os.chdir(original_cwd)


def test_config_falls_back_to_cwd_when_base_path_missing(tmp_path: Path) -> None:
    cfg = BotConfig(
        discord_bot_token="test-token",
        gate_api_token="test-api-token",
        discord_binding_store_path="state/discord.json",
        discord_binding_audit_path="audit/discord.jsonl",
        discord_status_path="status/discord.json",
    )

    previous_base_path = os.getenv("MASC_BASE_PATH")
    original_cwd = Path.cwd()
    try:
        os.environ.pop("MASC_BASE_PATH", None)
        os.chdir(tmp_path)
        assert cfg.binding_store_path() == tmp_path / "state" / "discord.json"
        assert cfg.binding_audit_path() == tmp_path / "audit" / "discord.jsonl"
        assert cfg.status_path() == tmp_path / "status" / "discord.json"
    finally:
        if previous_base_path is not None:
            os.environ["MASC_BASE_PATH"] = previous_base_path
        os.chdir(original_cwd)


def test_config_resolves_legacy_paths_from_base_path(tmp_path: Path) -> None:
    base_path = tmp_path / "workspace"
    base_path.mkdir()
    cfg = BotConfig(
        discord_bot_token="test-token",
        gate_api_token="test-api-token",
    )

    previous_base_path = os.getenv("MASC_BASE_PATH")
    original_cwd = Path.cwd()
    try:
        os.environ["MASC_BASE_PATH"] = str(base_path)
        os.chdir(tmp_path)
        assert cfg.legacy_binding_store_path() == (
            base_path / "sidecars" / "discord-bot" / ".gate" / "discord_bindings.json"
        )
        assert cfg.legacy_binding_audit_path() == (
            base_path / "sidecars" / "discord-bot" / ".gate" / "discord_binding_audit.jsonl"
        )
        assert cfg.legacy_status_path() == (
            base_path / "sidecars" / "discord-bot" / ".gate" / "discord_status.json"
        )
    finally:
        if previous_base_path is None:
            os.environ.pop("MASC_BASE_PATH", None)
        else:
            os.environ["MASC_BASE_PATH"] = previous_base_path
        os.chdir(original_cwd)


def test_config_resolves_legacy_paths_from_cwd_without_base_path(tmp_path: Path) -> None:
    cfg = BotConfig(
        discord_bot_token="test-token",
        gate_api_token="test-api-token",
    )

    previous_base_path = os.getenv("MASC_BASE_PATH")
    original_cwd = Path.cwd()
    try:
        os.environ.pop("MASC_BASE_PATH", None)
        os.chdir(tmp_path)
        assert cfg.legacy_binding_store_path() == tmp_path / ".gate" / "discord_bindings.json"
        assert cfg.legacy_binding_audit_path() == tmp_path / ".gate" / "discord_binding_audit.jsonl"
        assert cfg.legacy_status_path() == tmp_path / ".gate" / "discord_status.json"
    finally:
        if previous_base_path is not None:
            os.environ["MASC_BASE_PATH"] = previous_base_path
        os.chdir(original_cwd)
