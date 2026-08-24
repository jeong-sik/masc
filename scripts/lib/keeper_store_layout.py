"""Keeper runtime store layout, read from the OCaml owner.

``Common.keeper_runtime_store`` owns the dirname and placement of every keeper
runtime store. Python consumers used to assemble the same paths from their own
literals, so a rename in ``Common`` left them reading a directory that no
longer exists — and a readiness gate that finds nothing reports the same
"clean" as one that finds nothing wrong (#27583).

Nothing is cached on disk: the manifest binary prints what the compiler owns,
so there is no second copy to drift.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path


MANIFEST_SCHEMA = "masc.keeper_runtime_store_layout.v1"
_MANIFEST_RELATIVE = Path("_build/default/bin/keeper_store_layout_manifest.exe")


class StoreLayoutUnavailable(RuntimeError):
    """The manifest could not be read. Callers must fail, not guess a path."""


def _manifest_executable(repo_root: Path) -> Path:
    override = os.environ.get("KEEPER_STORE_LAYOUT_MANIFEST_EXE")
    if override:
        return Path(override)
    return repo_root / _MANIFEST_RELATIVE


def load_store_layout(repo_root: Path) -> dict[str, str]:
    """Return ``{dirname: placement}`` for every keeper runtime store."""
    exe = _manifest_executable(repo_root)
    if not exe.is_file() or not os.access(exe, os.X_OK):
        raise StoreLayoutUnavailable(
            f"keeper store layout manifest not built: {exe}\n"
            "Run: dune build bin/keeper_store_layout_manifest.exe"
        )
    try:
        raw = subprocess.run(
            [str(exe)], check=True, capture_output=True, text=True, timeout=30
        ).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        raise StoreLayoutUnavailable(f"manifest run failed: {exc}") from exc

    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise StoreLayoutUnavailable(f"manifest is not JSON: {exc}") from exc

    schema = payload.get("schema")
    if schema != MANIFEST_SCHEMA:
        raise StoreLayoutUnavailable(
            f"unexpected manifest schema {schema!r}, expected {MANIFEST_SCHEMA!r}"
        )

    stores = payload.get("stores")
    if not isinstance(stores, list) or not stores:
        raise StoreLayoutUnavailable("manifest carries no stores")

    layout: dict[str, str] = {}
    for entry in stores:
        dirname = entry.get("dirname")
        placement = entry.get("placement")
        if not isinstance(dirname, str) or not isinstance(placement, str):
            raise StoreLayoutUnavailable(f"malformed store entry: {entry!r}")
        layout[dirname] = placement
    return layout


def store_dirname(layout: dict[str, str], dirname: str) -> str:
    """Return ``dirname`` after confirming the OCaml owner still declares it.

    A caller that names a store the owner dropped gets an error here instead of
    a silently empty directory listing.
    """
    if dirname not in layout:
        raise StoreLayoutUnavailable(
            f"{dirname!r} is not a keeper runtime store; owner declares: "
            + ", ".join(sorted(layout))
        )
    return dirname
