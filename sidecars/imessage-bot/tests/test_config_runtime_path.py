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
