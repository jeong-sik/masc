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
    cfg = BotConfig(
        discord_bot_token="test-token",
        gate_api_token="test-api-token",
        discord_binding_store_path="state/discord.json",
        discord_binding_audit_path="audit/discord.jsonl",
        discord_status_path="status/discord.json",
    )

    original_cwd = Path.cwd()
    try:
        os.chdir(tmp_path)
        assert cfg.binding_store_path() == tmp_path / "state" / "discord.json"
        assert cfg.binding_audit_path() == tmp_path / "audit" / "discord.jsonl"
        assert cfg.status_path() == tmp_path / "status" / "discord.json"
    finally:
        os.chdir(original_cwd)
