"""Audit path resolver for the RFC-0203 traffic audit.

Kept in a dedicated module so unit tests can monkeypatch the
environment lookup without importing the rest of the sidecar.

Path resolution mirrors OCaml
``Channel_gate_discord_names.configured_write_path``:
- env ``MASC_DISCORD_TRAFFIC_AUDIT_PATH`` if set and non-empty wins
- else default ``.gate/runtime/discord/traffic_audit.jsonl``

WORKAROUND: relative default. Reason: cross-language consumers
(this Python sidecar + OCaml gate) both resolve relative to their
own CWD, which is the masc-mcp repo root in normal deployment. Once
the sidecar is deleted at RFC §Phase 3, the relative default lives
only in OCaml.
"""

from __future__ import annotations

import os
from pathlib import Path

DEFAULT_AUDIT_PATH = ".gate/runtime/discord/traffic_audit.jsonl"
AUDIT_PATH_ENV = "MASC_DISCORD_TRAFFIC_AUDIT_PATH"


def resolve_audit_path() -> Path:
    raw = os.environ.get(AUDIT_PATH_ENV)
    if raw is not None:
        stripped = raw.strip()
        if stripped != "":
            return Path(stripped)
    return Path(DEFAULT_AUDIT_PATH)
