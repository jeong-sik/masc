"""Tests for shared connector runtime status persistence."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from gate_shared.bindings_store import load_bindings, save_bindings
from gate_shared.status_store import ConnectorRuntimeStatus, StatusStore


def test_status_store_writes_runtime_snapshot(tmp_path: Path) -> None:
    path = tmp_path / "status.json"
    store = StatusStore(path)

    store.write(
        ConnectorRuntimeStatus(
            updated_at="2026-06-06T00:00:00Z",
            connected=True,
            gate_base_url="http://127.0.0.1:8935",
            gate_healthy=True,
            gate_health_checked_at="2026-06-06T00:00:01Z",
            last_message_at="2026-06-06T00:00:02Z",
            messages_processed=3,
            messages_failed=1,
            pid=4242,
            runtime_bindings_count=2,
            default_keeper="sangsu",
        )
    )

    payload = json.loads(path.read_text(encoding="utf-8"))
    assert payload["connected"] is True
    assert payload["gate_healthy"] is True
    assert payload["messages_processed"] == 3
    assert payload["messages_failed"] == 1
    assert payload["runtime_bindings_count"] == 2
    assert payload["binding_source"] == "persisted"
    assert payload["default_keeper"] == "sangsu"


def test_status_store_resolves_relative_path_against_base_path(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("MASC_BASE_PATH", str(tmp_path))
    store = StatusStore(".gate/runtime/slack/status.json")

    store.write(
        ConnectorRuntimeStatus(
            updated_at="2026-06-06T00:00:00Z",
            connected=True,
            gate_base_url="http://127.0.0.1:8935",
            gate_healthy=None,
            gate_health_checked_at="",
            last_message_at="",
            messages_processed=0,
            messages_failed=0,
            pid=4242,
        )
    )

    assert (tmp_path / ".gate/runtime/slack/status.json").exists()


def test_bindings_store_resolves_relative_path_against_base_path(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("MASC_BASE_PATH", str(tmp_path))
    path = ".gate/runtime/slack/bindings.json"

    save_bindings(path, {"C123": "luna"})

    assert (tmp_path / ".gate/runtime/slack/bindings.json").exists()
    assert load_bindings(path) == {"C123": "luna"}
