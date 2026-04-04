"""Tests for durable binding audit logging."""

from __future__ import annotations

import json
from pathlib import Path

from src.audit_store import BindingAuditEvent, BindingAuditStore


def test_audit_store_appends_jsonl_events(tmp_path: Path) -> None:
    path = tmp_path / "audit.jsonl"
    store = BindingAuditStore(path)

    store.append(
        BindingAuditEvent(
            timestamp="2026-04-04T12:00:00Z",
            action="bind",
            guild_id="g1",
            channel_id="c1",
            keeper_name="luna",
            actor_id="u1",
            actor_name="alice",
            previous_keeper="",
        )
    )
    store.append(
        BindingAuditEvent(
            timestamp="2026-04-04T12:01:00Z",
            action="unbind",
            guild_id="g1",
            channel_id="c1",
            keeper_name="luna",
            actor_id="u2",
            actor_name="bob",
            previous_keeper="luna",
        )
    )

    rows = [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    assert rows == [
        {
            "action": "bind",
            "actor_id": "u1",
            "actor_name": "alice",
            "channel_id": "c1",
            "guild_id": "g1",
            "keeper_name": "luna",
            "previous_keeper": "",
            "timestamp": "2026-04-04T12:00:00Z",
        },
        {
            "action": "unbind",
            "actor_id": "u2",
            "actor_name": "bob",
            "channel_id": "c1",
            "guild_id": "g1",
            "keeper_name": "luna",
            "previous_keeper": "luna",
            "timestamp": "2026-04-04T12:01:00Z",
        },
    ]


def test_audit_store_reads_recent_tail(tmp_path: Path) -> None:
    path = tmp_path / "audit.jsonl"
    store = BindingAuditStore(path)

    for idx in range(5):
        store.append(
            BindingAuditEvent(
                timestamp=f"2026-04-04T12:0{idx}:00Z",
                action="bind",
                guild_id="g1",
                channel_id=f"c{idx}",
                keeper_name="luna",
                actor_id=f"u{idx}",
                actor_name=f"user{idx}",
                previous_keeper="",
            )
        )

    recent = store.read_recent(limit=2)
    assert [event.channel_id for event in recent] == ["c3", "c4"]


def test_audit_store_skips_invalid_lines(tmp_path: Path) -> None:
    path = tmp_path / "audit.jsonl"
    path.write_text('{"timestamp":"2026-04-04T12:00:00Z","action":"bind"}\nnot-json\n', encoding="utf-8")
    store = BindingAuditStore(path)

    recent = store.read_recent(limit=5)
    assert len(recent) == 1
    assert recent[0].action == "bind"
