"""Shared runtime status writer for Channel Gate sidecars."""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class ConnectorRuntimeStatus:
    """One connector runtime snapshot for dashboard consumption."""

    updated_at: str
    connected: bool
    gate_base_url: str
    gate_healthy: bool | None
    gate_health_checked_at: str
    last_message_at: str
    messages_processed: int
    messages_failed: int
    pid: int
    binding_source: str = "persisted"
    runtime_bindings_count: int = 0
    poll_interval_sec: float = 10.0
    default_keeper: str = ""


def resolve_runtime_path(path: str | Path) -> Path:
    target = Path(path).expanduser()
    if target.is_absolute():
        return target
    raw_base = os.getenv("MASC_BASE_PATH", "").strip()
    if raw_base:
        return Path(raw_base).expanduser() / target
    return target


class StatusStore:
    """Persist connector runtime snapshots atomically."""

    def __init__(self, path: str | Path) -> None:
        self.path = resolve_runtime_path(path)

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
