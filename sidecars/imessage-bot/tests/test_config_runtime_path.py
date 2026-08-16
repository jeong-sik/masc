"""Regression: _runtime_toml_path() must be callable without NameError.

Pre-fix this raised `NameError: name 'Path' is not defined` because the
helper used `Path(...)` while the module forgot to import pathlib.Path.
The error surfaced at every BotConfig() instantiation via
settings_customise_sources -> TomlConfigSettingsSource(toml_file=...).
"""

from __future__ import annotations

from pathlib import Path

from src import config


def test_runtime_toml_path_returns_path_object() -> None:
    result = config._runtime_toml_path()
    assert isinstance(result, Path)
    assert str(result).endswith("/.gate/runtime/imessage/config.toml")


def test_state_paths_anchor_to_base_path(monkeypatch, tmp_path) -> None:
    """The bot must write where the readers look.

    run.sh exports MASC_BASE_PATH and then chdir's into the sidecar directory.
    Left relative, status.json landed under sidecars/imessage-bot/ while the
    server, the gate state and run.sh all read <base>/.gate/runtime/imessage/,
    so the connector reported "connector status file not found" while running.
    """
    monkeypatch.setenv("MASC_BASE_PATH", str(tmp_path))
    # Stand somewhere other than the base path, the way run.sh does.
    cwd = tmp_path / "sidecars" / "imessage-bot"
    cwd.mkdir(parents=True)
    monkeypatch.chdir(cwd)

    cfg = config.BotConfig()

    runtime = tmp_path / ".gate" / "runtime" / "imessage"
    assert Path(cfg.status_path) == runtime / "status.json"
    assert Path(cfg.cursor_path) == runtime / "cursor.json"
    assert Path(cfg.binding_store_path) == runtime / "bindings.json"
    assert Path(cfg.binding_audit_path) == runtime / "binding_audit.jsonl"


def test_absolute_state_paths_are_left_alone(monkeypatch, tmp_path) -> None:
    monkeypatch.setenv("MASC_BASE_PATH", str(tmp_path))
    pinned = tmp_path / "pinned" / "status.json"

    cfg = config.BotConfig(status_path=str(pinned))

    assert Path(cfg.status_path) == pinned
