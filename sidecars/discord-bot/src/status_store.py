"""Durable runtime status store for the Discord connector."""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True, slots=True)
class ConnectorRuntimeStatus:
    """One connector runtime snapshot for dashboard consumption."""

    updated_at: str
    connected: bool
    bot_user_name: str
    bot_user_id: str
    guild_count: int
    gate_base_url: str
    gate_healthy: bool | None
    gate_health_checked_at: str
    last_ready_at: str
    binding_source: str
    runtime_bindings_count: int
    binding_store_path: str
    audit_store_path: str
    pid: int

    @staticmethod
    def from_json(data: dict[str, Any]) -> ConnectorRuntimeStatus:
        raw_gate_healthy = data.get("gate_healthy")
        gate_healthy = raw_gate_healthy if isinstance(raw_gate_healthy, bool) else None
        return ConnectorRuntimeStatus(
            updated_at=str(data.get("updated_at", "")),
            connected=bool(data.get("connected", False)),
            bot_user_name=str(data.get("bot_user_name", "")),
            bot_user_id=str(data.get("bot_user_id", "")),
            guild_count=int(data.get("guild_count", 0)),
            gate_base_url=str(data.get("gate_base_url", "")),
            gate_healthy=gate_healthy,
            gate_health_checked_at=str(data.get("gate_health_checked_at", "")),
            last_ready_at=str(data.get("last_ready_at", "")),
            binding_source=str(data.get("binding_source", "")),
            runtime_bindings_count=int(data.get("runtime_bindings_count", 0)),
            binding_store_path=str(data.get("binding_store_path", "")),
            audit_store_path=str(data.get("audit_store_path", "")),
            pid=int(data.get("pid", 0)),
        )


class StatusStore:
    """Persist connector runtime snapshots atomically."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def write(self, status: ConnectorRuntimeStatus) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = self.path.with_name(f".{self.path.name}.tmp")
        payload = json.dumps(asdict(status), indent=2, sort_keys=True)
        try:
            tmp_path.write_text(f"{payload}\n", encoding="utf-8")
            os.replace(tmp_path, self.path)
        except OSError:
            try:
                tmp_path.unlink(missing_ok=True)
            except OSError:
                pass
            raise
