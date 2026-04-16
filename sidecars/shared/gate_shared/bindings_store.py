"""Shared bindings-store helpers for Channel Gate sidecars.

Load and persist ``{channel_id: keeper_name}`` JSON with 1-tier legacy
fallback.  Discord's richer ``BindingStore`` class (audit coupling +
mtime tracking) is intentionally separate.
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path


def load_bindings(
    default_path: str | Path,
    *,
    legacy_path: str | Path | None = None,
    logger: logging.Logger | None = None,
) -> dict[str, str]:
    """Load channel-to-keeper bindings from disk with optional legacy fallback.

    Returns an empty dict if neither file exists, if the file is not a
    JSON object, or on parse/IO errors. Non-string values are silently
    dropped to preserve the `str -> str` contract.
    """
    log = logger or logging.getLogger(__name__)
    path = Path(default_path)
    source = "default"
    if not path.exists():
        if legacy_path is None:
            return {}
        legacy = Path(legacy_path)
        if legacy.exists():
            path = legacy
            source = "legacy"
        else:
            return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        log.warning("Failed to load bindings from %s: %s", path, exc)
        return {}
    if not isinstance(data, dict):
        return {}
    bindings = {
        str(k): str(v) for k, v in data.items() if isinstance(v, str)
    }
    if source == "legacy":
        log.info(
            "Loaded %d binding(s) from legacy store %s; next write goes to %s",
            len(bindings),
            path,
            default_path,
        )
    else:
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
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(f".{target.name}.tmp")
    try:
        tmp.write_text(json.dumps(bindings, indent=2), encoding="utf-8")
        os.replace(tmp, target)
    except OSError as exc:
        log.error("Failed to save bindings to %s: %s", target, exc)
        tmp.unlink(missing_ok=True)
