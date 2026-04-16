"""Shared bindings-store helpers for Channel Gate sidecars.

Slack, iMessage, and Telegram sidecars all need to load a simple
`{channel_id: keeper_name}` JSON file with 1-tier legacy fallback, and
Slack + Telegram also need to persist the same shape atomically. This
module collapses the duplicated 38-line `_load_bindings` /
`_save_bindings` blocks into a pair of pure functions that take the
paths as arguments — no base class, no mixin, no state.

Discord's sidecar uses a richer `BindingStore` class with atomic writes
and audit coupling; it stays separate and is not affected by this
module.

Read priority in `load_bindings`:
  1. `default_path` (if the file exists)
  2. `legacy_path` (if provided, the file exists, and default is absent)
  3. empty dict

Writes in `save_bindings` always land at the caller's `path`, so the
one-shot migration introduced in #7477/#7478/#7479 remains transparent
— next save after a legacy load hits the new default and the legacy
file becomes dormant.
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
