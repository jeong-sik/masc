"""Durable runtime status store for the iMessage connector."""

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
    cursor_rowid: int
    chat_db_path: str
    poll_interval_sec: float
    pid: int
    reply_mode: str = ""
    self_chat_guid: str = ""


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
