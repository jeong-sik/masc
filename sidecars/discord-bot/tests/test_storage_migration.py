"""Tests for legacy Discord runtime-file migration helpers."""

from __future__ import annotations

from pathlib import Path

from src.storage_migration import migrate_legacy_file


def test_migrate_legacy_file_moves_runtime_state_and_prunes_empty_dirs(
    tmp_path: Path,
) -> None:
    legacy_path = tmp_path / ".masc" / "connectors" / "discord" / "status.json"
    target_path = tmp_path / ".gate" / "runtime" / "discord" / "status.json"
    legacy_path.parent.mkdir(parents=True)
    legacy_path.write_text('{"connected": true}\n', encoding="utf-8")

    moved = migrate_legacy_file(
        label="status",
        legacy_path=legacy_path,
        target_path=target_path,
    )

    assert moved is True
    assert legacy_path.exists() is False
    assert target_path.read_text(encoding="utf-8") == '{"connected": true}\n'
    assert (tmp_path / ".masc").exists() is True
    assert (tmp_path / ".masc" / "connectors").exists() is False


def test_migrate_legacy_file_skips_when_target_already_exists(tmp_path: Path) -> None:
    legacy_path = tmp_path / ".masc" / "connectors" / "discord" / "bindings.json"
    target_path = tmp_path / ".gate" / "runtime" / "discord" / "bindings.json"
    legacy_path.parent.mkdir(parents=True)
    target_path.parent.mkdir(parents=True)
    legacy_path.write_text('{"123":"legacy"}\n', encoding="utf-8")
    target_path.write_text('{"123":"current"}\n', encoding="utf-8")

    moved = migrate_legacy_file(
        label="binding store",
        legacy_path=legacy_path,
        target_path=target_path,
    )

    assert moved is False
    assert legacy_path.read_text(encoding="utf-8") == '{"123":"legacy"}\n'
    assert target_path.read_text(encoding="utf-8") == '{"123":"current"}\n'
