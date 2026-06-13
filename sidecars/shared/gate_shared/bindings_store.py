"""Shared bindings-store helpers for Channel Gate sidecars.

Load and persist ``{channel_id: keeper_name}`` JSON. Discord's richer
``BindingStore`` class (audit coupling + mtime tracking) is intentionally
separate.
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path


def resolve_runtime_path(path: str | Path) -> Path:
    target = Path(path).expanduser()
    if target.is_absolute():
        return target
    raw_base = os.getenv("MASC_BASE_PATH", "").strip()
    if raw_base:
        return Path(raw_base).expanduser() / target
    return target


def load_bindings(
    default_path: str | Path,
    *,
    logger: logging.Logger | None = None,
) -> dict[str, str]:
    """Load channel-to-keeper bindings from disk.

    Returns an empty dict if the file does not exist, if the file is not a JSON
    object, or on parse/IO errors. Non-string values are silently dropped to
    preserve the `str -> str` contract.
    """
    log = logger or logging.getLogger(__name__)
    path = resolve_runtime_path(default_path)
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        log.warning("Failed to load bindings from %s: %s", path, exc)
        return {}
    if not isinstance(data, dict):
        return {}
    bindings = {str(k): str(v) for k, v in data.items() if isinstance(v, str)}
    log.info("Loaded %d binding(s)", len(bindings))
    return bindings


def save_bindings(
    path: str | Path,
    bindings: dict[str, str],
    *,
    logger: logging.Logger | None = None,
) -> None:
    """Persist bindings atomically via a hidden tempfile + os.replace."""
    log = logger or logging.getLogger(__name__)
    target = resolve_runtime_path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(f".{target.name}.tmp")
    try:
        tmp.write_text(json.dumps(bindings, indent=2), encoding="utf-8")
        os.replace(tmp, target)
    except OSError as exc:
        log.error("Failed to save bindings to %s: %s", target, exc)
        tmp.unlink(missing_ok=True)
