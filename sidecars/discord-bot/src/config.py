"""Configuration for Discord Gate Bot.

Loads and validates all required environment variables.
Fails fast at startup if any required config is missing.
"""

from __future__ import annotations

import ipaddress
import json
import os
from pathlib import Path
from typing import Final, cast
from urllib.parse import urlparse

from pydantic import AliasChoices, Field, field_validator, model_validator
from pydantic_settings import (
    BaseSettings,
    PydanticBaseSettingsSource,
    SettingsConfigDict,
    TomlConfigSettingsSource,
)

DEFAULT_BINDING_STORE_PATH: Final[str] = ".gate/runtime/discord/bindings.json"
DEFAULT_BINDING_AUDIT_PATH: Final[str] = ".gate/runtime/discord/binding_audit.jsonl"
DEFAULT_STATUS_PATH: Final[str] = ".gate/runtime/discord/status.json"
DEFAULT_NAMES_PATH: Final[str] = ".gate/runtime/discord/names.json"

# Legacy layout from the pre-v0.9.0 release (OCaml side migrated in
# #7467/#7468 B3a/B3b). On startup the bot now migrates these files into the
# new runtime layout when the operator still uses the default target paths.
# The even older `sidecars/discord-bot/.gate/discord_*` cwd-relative layout is
# no longer auto-discovered; deployments still on it must set explicit
# DISCORD_*_PATH env vars.
LEGACY_BINDING_STORE_PATH: Final[str] = ".masc/connectors/discord/bindings.json"
LEGACY_BINDING_AUDIT_PATH: Final[str] = ".masc/connectors/discord/binding_audit.jsonl"
LEGACY_STATUS_PATH: Final[str] = ".masc/connectors/discord/status.json"
LEGACY_NAMES_PATH: Final[str] = ".masc/connectors/discord/names.json"


def _runtime_toml_path() -> Path:
    raw = os.getenv("MASC_BASE_PATH", "").strip()
    root = Path(raw).expanduser() if raw else Path.cwd()
    return root / ".gate/runtime/discord/config.toml"


def _is_loopback_host(raw_host: str | None) -> bool:
    if raw_host is None:
        return False
    host = raw_host.strip().lower()
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


class BotConfig(BaseSettings):
    """Bot configuration.  Priority: env > runtime TOML > field defaults."""

    model_config = SettingsConfigDict(
        env_prefix="",
        case_sensitive=True,
        env_file=".env",
        extra="ignore",
    )

    @classmethod
    def settings_customise_sources(
        cls,
        settings_cls: type[BaseSettings],
        init_settings: PydanticBaseSettingsSource,
        env_settings: PydanticBaseSettingsSource,
        dotenv_settings: PydanticBaseSettingsSource,
        file_secret_settings: PydanticBaseSettingsSource,
    ) -> tuple[PydanticBaseSettingsSource, ...]:
        toml_source = TomlConfigSettingsSource(
            settings_cls, toml_file=_runtime_toml_path()
        )
        return (
            init_settings,
            env_settings,
            dotenv_settings,
            toml_source,
            file_secret_settings,
        )

    # Required
    discord_bot_token: str = Field(
        validation_alias=AliasChoices("DISCORD_BOT_TOKEN", "discord_bot_token")
    )
    gate_base_url: str = Field(
        default="http://localhost:8935",
        validation_alias=AliasChoices("GATE_BASE_URL", "gate_base_url"),
    )
    gate_api_token: str = Field(
        default="",
        validation_alias=AliasChoices("GATE_API_TOKEN", "gate_api_token"),
    )

    # Channel-to-keeper mapping: {"channel_id": "keeper_name"}
    discord_keeper_map: str = Field(
        default="{}",
        validation_alias=AliasChoices("DISCORD_KEEPER_MAP", "discord_keeper_map"),
    )
    discord_binding_store_path: str = Field(
        default=DEFAULT_BINDING_STORE_PATH,
        validation_alias=AliasChoices(
            "DISCORD_BINDING_STORE_PATH",
            "discord_binding_store_path",
        ),
    )
    discord_binding_audit_path: str = Field(
        default=DEFAULT_BINDING_AUDIT_PATH,
        validation_alias=AliasChoices(
            "DISCORD_BINDING_AUDIT_PATH",
            "discord_binding_audit_path",
        ),
    )
    discord_status_path: str = Field(
        default=DEFAULT_STATUS_PATH,
        validation_alias=AliasChoices(
            "DISCORD_STATUS_PATH",
            "discord_status_path",
        ),
    )
    discord_names_path: str = Field(
        default=DEFAULT_NAMES_PATH,
        validation_alias=AliasChoices(
            "DISCORD_NAMES_PATH",
            "discord_names_path",
        ),
    )

    # Optional
    discord_admin_role_id: str = Field(
        default="",
        validation_alias=AliasChoices(
            "DISCORD_ADMIN_ROLE_ID",
            "discord_admin_role_id",
        ),
    )

    # Reaction trigger + busy-batch (Discord UX: emoji reaction 으로 keeper 호출,
    # 응답 진행 중이면 추가 trigger hold + gap 메시지 batched fetch).
    discord_reaction_trigger_emoji: str = Field(
        default="",
        validation_alias=AliasChoices(
            "DISCORD_REACTION_TRIGGER_EMOJI",
            "discord_reaction_trigger_emoji",
        ),
    )
    discord_busy_debounce_sec: int = Field(
        default=0,
        validation_alias=AliasChoices(
            "DISCORD_BUSY_DEBOUNCE_SEC",
            "discord_busy_debounce_sec",
        ),
    )
    discord_batch_max_messages: int = Field(
        default=50,
        validation_alias=AliasChoices(
            "DISCORD_BATCH_MAX_MESSAGES",
            "discord_batch_max_messages",
        ),
    )
    discord_batch_gap_window_sec: int = Field(
        default=1800,
        validation_alias=AliasChoices(
            "DISCORD_BATCH_GAP_WINDOW_SEC",
            "discord_batch_gap_window_sec",
        ),
    )

    # Timeouts
    gate_timeout_sec: int = Field(
        default=120,
        validation_alias=AliasChoices("GATE_TIMEOUT_SEC", "gate_timeout_sec"),
    )
    # Retries after the first attempt; 0 disables retries.
    gate_max_retries: int = Field(
        default=2,
        validation_alias=AliasChoices("GATE_MAX_RETRIES", "gate_max_retries"),
    )
    status_cache_ttl_sec: int = Field(
        default=15,
        validation_alias=AliasChoices("STATUS_CACHE_TTL_SEC", "status_cache_ttl_sec"),
    )
    keeper_cache_ttl_sec: int = Field(
        default=30,
        validation_alias=AliasChoices("KEEPER_CACHE_TTL_SEC", "keeper_cache_ttl_sec"),
    )
    gate_breaker_failure_threshold: int = Field(
        default=3,
        validation_alias=AliasChoices(
            "GATE_BREAKER_FAILURE_THRESHOLD",
            "gate_breaker_failure_threshold",
        ),
    )
    gate_breaker_reset_sec: int = Field(
        default=30,
        validation_alias=AliasChoices(
            "GATE_BREAKER_RESET_SEC", "gate_breaker_reset_sec"
        ),
    )
    status_heartbeat_sec: int = Field(
        default=10,
        validation_alias=AliasChoices("STATUS_HEARTBEAT_SEC", "status_heartbeat_sec"),
    )

    # Reaction trigger + busy-batch (Discord UX: emoji reaction 으로 keeper 호출,
    # 응답 진행 중이면 추가 trigger hold + gap 메시지 batched fetch).
    discord_reaction_trigger_emoji: str = Field(
        default="",
        validation_alias=AliasChoices(
            "DISCORD_REACTION_TRIGGER_EMOJI",
            "discord_reaction_trigger_emoji",
        ),
    )
    discord_busy_debounce_sec: int = Field(
        default=0,
        validation_alias=AliasChoices(
            "DISCORD_BUSY_DEBOUNCE_SEC",
            "discord_busy_debounce_sec",
        ),
    )
    discord_batch_max_messages: int = Field(
        default=50,
        validation_alias=AliasChoices(
            "DISCORD_BATCH_MAX_MESSAGES",
            "discord_batch_max_messages",
        ),
    )
    discord_batch_gap_window_sec: int = Field(
        default=1800,
        validation_alias=AliasChoices(
            "DISCORD_BATCH_GAP_WINDOW_SEC",
            "discord_batch_gap_window_sec",
        ),
    )

    @field_validator("discord_bot_token")
    @classmethod
    def token_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("DISCORD_BOT_TOKEN is required")
        return v.strip()

    @field_validator("gate_api_token")
    @classmethod
    def normalize_api_token(cls, v: str) -> str:
        return v.strip()

    @model_validator(mode="after")
    def validate_gate_auth_mode(self) -> BotConfig:
        if self.gate_api_token or self.gate_base_url_is_loopback():
            return self
        raise ValueError(
            "GATE_API_TOKEN is required unless gate URL points at a loopback host"
        )

    @field_validator("discord_keeper_map")
    @classmethod
    def validate_keeper_map_json(cls, v: str) -> str:
        """Validate that DISCORD_KEEPER_MAP is valid JSON at startup."""
        if not v.strip():
            return "{}"
        try:
            parsed: object = json.loads(v)
            if not isinstance(parsed, dict):
                raise ValueError(
                    f"DISCORD_KEEPER_MAP must be a JSON object, got {type(parsed).__name__}"
                )
        except json.JSONDecodeError as e:
            raise ValueError(f"DISCORD_KEEPER_MAP is not valid JSON: {e}") from e
        return v

    @field_validator(
        "discord_binding_store_path",
        "discord_binding_audit_path",
        "discord_status_path",
        "discord_names_path",
    )
    @classmethod
    def validate_non_empty_path(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("binding persistence paths must not be empty")
        return v.strip()

    @field_validator("gate_timeout_sec")
    @classmethod
    def validate_positive_timeout(cls, v: int) -> int:
        if v <= 0:
            raise ValueError("gate_timeout_sec must be positive")
        return v

    @field_validator(
        "gate_max_retries",
        "status_cache_ttl_sec",
        "keeper_cache_ttl_sec",
        "gate_breaker_failure_threshold",
        "gate_breaker_reset_sec",
        "status_heartbeat_sec",
        "discord_busy_debounce_sec",
        "discord_batch_max_messages",
        "discord_batch_gap_window_sec",
    )
    @classmethod
    def validate_non_negative_ints(cls, v: int) -> int:
        if v < 0:
            raise ValueError("connector timing values must be non-negative")
        return v

    def keeper_map(self) -> dict[str, str]:
        """Parse DISCORD_KEEPER_MAP JSON into dict.

        Safe to call without try/except because validate_keeper_map_json
        guarantees valid JSON at startup.
        """
        raw: object = json.loads(self.discord_keeper_map)
        if not isinstance(raw, dict):
            return {}
        typed_raw = cast(dict[object, object], raw)
        return {str(key): str(value) for key, value in typed_raw.items()}

    def base_path_root(self) -> Path | None:
        raw = os.getenv("MASC_BASE_PATH", "").strip()
        if not raw:
            return None
        return Path(raw).expanduser()

    def _resolve_storage_path(self, raw_path: str) -> Path:
        path = Path(raw_path).expanduser()
        if path.is_absolute():
            return path
        base_root = self.base_path_root()
        if base_root is not None:
            return base_root / path
        return Path.cwd() / path

    def binding_store_path(self) -> Path:
        """Return the durable binding store path.

        Relative paths resolve from MASC_BASE_PATH when set; otherwise they
        fall back to the current working directory for local sidecar-only runs.
        """
        return self._resolve_storage_path(self.discord_binding_store_path)

    def binding_audit_path(self) -> Path:
        return self._resolve_storage_path(self.discord_binding_audit_path)

    def status_path(self) -> Path:
        return self._resolve_storage_path(self.discord_status_path)

    def names_path(self) -> Path:
        return self._resolve_storage_path(self.discord_names_path)

    def _matches_default_storage_path(self, raw_path: str, default_path: str) -> bool:
        return self._resolve_storage_path(raw_path) == self._resolve_storage_path(
            default_path
        )

    # Legacy paths now resolve under the same base as the new defaults
    # (MASC_BASE_PATH or cwd), not under sidecars/discord-bot/, because the
    # pre-v0.9.0 layout was already MASC_BASE_PATH-relative.
    def legacy_binding_store_path(self) -> Path:
        return self._resolve_storage_path(LEGACY_BINDING_STORE_PATH)

    def legacy_binding_audit_path(self) -> Path:
        return self._resolve_storage_path(LEGACY_BINDING_AUDIT_PATH)

    def legacy_status_path(self) -> Path:
        return self._resolve_storage_path(LEGACY_STATUS_PATH)

    def legacy_names_path(self) -> Path:
        return self._resolve_storage_path(LEGACY_NAMES_PATH)

    def legacy_runtime_migrations(self) -> list[tuple[str, Path, Path]]:
        migrations: list[tuple[str, Path, Path]] = []
        candidates = [
            (
                "binding store",
                self.discord_binding_store_path,
                DEFAULT_BINDING_STORE_PATH,
                self.legacy_binding_store_path(),
                self.binding_store_path(),
            ),
            (
                "binding audit",
                self.discord_binding_audit_path,
                DEFAULT_BINDING_AUDIT_PATH,
                self.legacy_binding_audit_path(),
                self.binding_audit_path(),
            ),
            (
                "status",
                self.discord_status_path,
                DEFAULT_STATUS_PATH,
                self.legacy_status_path(),
                self.status_path(),
            ),
            (
                "names",
                self.discord_names_path,
                DEFAULT_NAMES_PATH,
                self.legacy_names_path(),
                self.names_path(),
            ),
        ]
        for label, raw_path, default_path, legacy_path, target_path in candidates:
            if (
                self._matches_default_storage_path(raw_path, default_path)
                and legacy_path != target_path
            ):
                migrations.append((label, legacy_path, target_path))
        return migrations

    def gate_message_url(self) -> str:
        base = self.gate_base_url.rstrip("/")
        return f"{base}/api/v1/gate/message"

    def gate_health_url(self) -> str:
        base = self.gate_base_url.rstrip("/")
        return f"{base}/api/v1/gate/health"

    def gate_base_url_is_loopback(self) -> bool:
        parsed = urlparse(self.gate_base_url)
        return _is_loopback_host(parsed.hostname)

    def gate_origin(self) -> str:
        parsed = urlparse(self.gate_base_url)
        if parsed.scheme and parsed.netloc:
            return f"{parsed.scheme}://{parsed.netloc}"
        return self.gate_base_url.rstrip("/")


# Lazy singleton - instantiated on first get_config() call.
_config: BotConfig | None = None

DISCORD_MESSAGE_LIMIT: Final[int] = 2000
DISCORD_EMBED_LIMIT: Final[int] = 4096


def get_config() -> BotConfig:
    """Get or create the singleton config."""
    global _config  # noqa: PLW0603
    if _config is None:
        _config = BotConfig()  # type: ignore[call-arg]
    return _config


def reset_config_cache() -> None:
    """Clear the cached settings object. Used by tests."""
    global _config  # noqa: PLW0603
    _config = None
