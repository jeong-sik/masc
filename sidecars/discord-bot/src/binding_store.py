"""Persistent Discord channel binding store.

Stores the effective channel -> keeper map on local disk so operator changes
survive bot restarts.
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import cast

logger = logging.getLogger(__name__)


def _normalize_bindings(raw: object) -> dict[str, str]:
    if not isinstance(raw, dict):
        raise ValueError("binding store must be a JSON object")

    typed_raw = cast(dict[object, object], raw)
    bindings: dict[str, str] = {}
    for raw_channel_id, raw_keeper in typed_raw.items():
        channel_id = str(raw_channel_id).strip()
        keeper_name = str(raw_keeper).strip()
        if not channel_id or not keeper_name:
            continue
        bindings[channel_id] = keeper_name
    return bindings


class BindingStore:
    """Load and save the durable Discord binding map."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def modified_time_ns(self) -> int | None:
        try:
            return self.path.stat().st_mtime_ns
        except FileNotFoundError:
            return None

    def load(self) -> dict[str, str] | None:
        """Return persisted bindings, or None when no valid store exists."""
        if not self.path.exists():
            return None

        try:
            raw: object = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            logger.warning("Failed to read binding store %s: %s", self.path, exc)
            return None

        try:
            return _normalize_bindings(raw)
        except ValueError as exc:
            logger.warning("Invalid binding store %s: %s", self.path, exc)
            return None

    def save(self, bindings: dict[str, str]) -> None:
        """Persist bindings atomically using replace-on-write."""
        normalized = _normalize_bindings(bindings)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = self.path.with_name(f".{self.path.name}.tmp")
        payload = json.dumps(normalized, indent=2, sort_keys=True)

        try:
            tmp_path.write_text(f"{payload}\n", encoding="utf-8")
            os.replace(tmp_path, self.path)
        except OSError:
            try:
                tmp_path.unlink(missing_ok=True)
            except OSError:
                pass
            raise
