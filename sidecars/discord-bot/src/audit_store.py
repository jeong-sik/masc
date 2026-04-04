"""Durable audit trail for Discord binding changes."""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, cast


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


@dataclass(frozen=True, slots=True)
class BindingAuditEvent:
    """One binding mutation performed by an operator."""

    timestamp: str
    action: str
    guild_id: str
    channel_id: str
    keeper_name: str
    actor_id: str
    actor_name: str
    previous_keeper: str

    @staticmethod
    def from_json(data: dict[str, Any]) -> BindingAuditEvent:
        return BindingAuditEvent(
            timestamp=str(data.get("timestamp", "")),
            action=str(data.get("action", "")),
            guild_id=str(data.get("guild_id", "")),
            channel_id=str(data.get("channel_id", "")),
            keeper_name=str(data.get("keeper_name", "")),
            actor_id=str(data.get("actor_id", "")),
            actor_name=str(data.get("actor_name", "")),
            previous_keeper=str(data.get("previous_keeper", "")),
        )


class BindingAuditStore:
    """Append-only JSONL audit store for operator binding changes."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def append(self, event: BindingAuditEvent) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        line = json.dumps(asdict(event), sort_keys=True)
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(f"{line}\n")
            handle.flush()
            os.fsync(handle.fileno())

    def read_recent(self, *, limit: int) -> list[BindingAuditEvent]:
        if limit <= 0 or not self.path.exists():
            return []

        events: list[BindingAuditEvent] = []
        for line in self.path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                raw: object = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(raw, dict):
                continue
            events.append(BindingAuditEvent.from_json(cast(dict[str, Any], raw)))
        if len(events) <= limit:
            return events
        return events[-limit:]
