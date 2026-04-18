"""Helpers for migrating legacy Discord runtime files into the base-path layout."""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Iterable


def _cleanup_stop_before(legacy_path: Path) -> Path:
    for parent in legacy_path.parents:
        if parent.name == ".masc":
            return parent
    return legacy_path.parent


def _prune_empty_legacy_dirs(start_dir: Path, *, stop_before: Path) -> None:
    current = start_dir
    while current != stop_before and current.exists():
        try:
            current.rmdir()
        except OSError:
            break
        current = current.parent


def migrate_legacy_file(
    *,
    label: str,
    legacy_path: Path,
    target_path: Path,
    logger: logging.Logger | None = None,
) -> bool:
    if legacy_path == target_path or not legacy_path.exists() or target_path.exists():
        return False

    target_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.replace(legacy_path, target_path)
    except OSError as exc:
        if logger is not None:
            logger.warning(
                "Failed to migrate Discord %s from %s to %s: %s",
                label,
                legacy_path,
                target_path,
                exc,
            )
        return False

    _prune_empty_legacy_dirs(
        legacy_path.parent, stop_before=_cleanup_stop_before(legacy_path)
    )
    if logger is not None:
        logger.info(
            "Migrated Discord %s from %s to %s",
            label,
            legacy_path,
            target_path,
        )
    return True


def migrate_legacy_runtime_files(
    migrations: Iterable[tuple[str, Path, Path]],
    *,
    logger: logging.Logger | None = None,
) -> list[Path]:
    moved: list[Path] = []
    for label, legacy_path, target_path in migrations:
        if migrate_legacy_file(
            label=label,
            legacy_path=legacy_path,
            target_path=target_path,
            logger=logger,
        ):
            moved.append(target_path)
    return moved
