"""Tests for Discord runtime status persistence."""

from __future__ import annotations

import json
from pathlib import Path

from src.status_store import (
    ConnectorRuntimeStatus,
    NamesSnapshot,
    NamesStore,
    StatusStore,
)


def test_status_store_writes_connector_runtime_snapshot(tmp_path: Path) -> None:
    path = tmp_path / "state" / "discord_status.json"
    store = StatusStore(path)

    store.write(
        ConnectorRuntimeStatus(
            updated_at="2026-04-08T13:00:00Z",
            connected=True,
            bot_user_name="sangsu",
            bot_user_id="1489985300729172039",
            guild_count=3,
            gate_base_url="http://localhost:8935",
            gate_healthy=True,
            gate_health_checked_at="2026-04-08T13:00:00Z",
            last_ready_at="2026-04-08T12:59:55Z",
            binding_source="persisted",
            runtime_bindings_count=2,
            binding_store_path="/tmp/discord_bindings.json",
            audit_store_path="/tmp/discord_binding_audit.jsonl",
            pid=4242,
        )
    )

    assert json.loads(path.read_text(encoding="utf-8")) == {
        "audit_store_path": "/tmp/discord_binding_audit.jsonl",
        "binding_source": "persisted",
        "binding_store_path": "/tmp/discord_bindings.json",
        "bot_user_id": "1489985300729172039",
        "bot_user_name": "sangsu",
        "connected": True,
        "gate_base_url": "http://localhost:8935",
        "gate_health_checked_at": "2026-04-08T13:00:00Z",
        "gate_healthy": True,
        "guild_count": 3,
        "last_ready_at": "2026-04-08T12:59:55Z",
        "pid": 4242,
        "runtime_bindings_count": 2,
        "updated_at": "2026-04-08T13:00:00Z",
    }


def test_names_store_writes_humanization_snapshot(tmp_path: Path) -> None:
    path = tmp_path / "state" / "discord_names.json"
    store = NamesStore(path)

    store.write(
        NamesSnapshot(
            updated_at="2026-04-15T00:00:00Z",
            guild_names={"123": "sangsu-lab"},
            channel_names={"456": "#general", "457": "#dev"},
            channel_to_guild={"456": "123", "457": "123"},
        )
    )

    assert json.loads(path.read_text(encoding="utf-8")) == {
        "updated_at": "2026-04-15T00:00:00Z",
        "guild_names": {"123": "sangsu-lab"},
        "channel_names": {"456": "#general", "457": "#dev"},
        "channel_to_guild": {"456": "123", "457": "123"},
    }


def test_names_store_empty_snapshot_is_valid(tmp_path: Path) -> None:
    path = tmp_path / "discord_names.json"
    store = NamesStore(path)

    store.write(NamesSnapshot(updated_at="2026-04-15T00:00:00Z"))

    data = json.loads(path.read_text(encoding="utf-8"))
    assert data["guild_names"] == {}
    assert data["channel_names"] == {}
    assert data["channel_to_guild"] == {}
