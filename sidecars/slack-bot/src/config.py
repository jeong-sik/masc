"""Configuration for Slack Gate Bot.

Uses Socket Mode (no public endpoint needed).
Requires a Slack App with:
- Bot Token Scopes: chat:write, app_mentions:read, im:history, im:read
- Socket Mode enabled with an App-Level Token
"""

from __future__ import annotations

import ipaddress
from typing import Final
from urllib.parse import urlparse

from pydantic import AliasChoices, Field, field_validator, model_validator
from pydantic_settings import (
    BaseSettings,
    PydanticBaseSettingsSource,
    SettingsConfigDict,
    TomlConfigSettingsSource,
)

DEFAULT_STATE_DIR: Final[str] = ".gate/runtime/slack"
DEFAULT_BINDING_STORE_PATH: Final[str] = ".gate/runtime/slack/bindings.json"
DEFAULT_STATUS_PATH: Final[str] = ".gate/runtime/slack/status.json"

# Legacy read-fallback (pre-v0.9.0 layout). See bot.py _load_bindings —
# loads from here if the new default is absent, then writes to the new
# default on next save.
LEGACY_BINDING_STORE_PATH: Final[str] = ".masc/connectors/slack/bindings.json"


def _runtime_toml_path() -> Path:
    raw = os.getenv("MASC_BASE_PATH", "").strip()
    root = Path(raw).expanduser() if raw else Path.cwd()
    return root / ".gate/runtime/slack/config.toml"


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
        return (init_settings, env_settings, dotenv_settings, toml_source, file_secret_settings)

    # Required: Slack Bot Token (xoxb-...)
    slack_bot_token: str = Field(
        validation_alias=AliasChoices("SLACK_BOT_TOKEN", "slack_bot_token")
    )
    # Required: Slack App-Level Token for Socket Mode (xapp-...)
    slack_app_token: str = Field(
        validation_alias=AliasChoices("SLACK_APP_TOKEN", "slack_app_token")
    )

    # Gate connection
    gate_base_url: str = Field(
        default="http://localhost:8935",
        validation_alias=AliasChoices("GATE_BASE_URL", "gate_base_url"),
    )
    gate_api_token: str = Field(
        default="",
        validation_alias=AliasChoices("GATE_API_TOKEN", "gate_api_token"),
    )

    # Default keeper when no binding exists
    default_keeper: str = Field(
        default="sangsu",
        validation_alias=AliasChoices("SLACK_DEFAULT_KEEPER", "default_keeper"),
    )

    # Timeouts — common Gate knobs reuse GATE_/STATUS_/KEEPER_ names to match
    # the other sidecars (see discord-bot and telegram-bot). Field-name aliases
    # are kept so in-process kwargs still work.
    gate_timeout_sec: float = Field(
        default=120.0,
        validation_alias=AliasChoices("GATE_TIMEOUT_SEC", "gate_timeout_sec"),
    )
    gate_breaker_failure_threshold: int = Field(
        default=3,
        validation_alias=AliasChoices(
            "GATE_BREAKER_FAILURE_THRESHOLD", "gate_breaker_failure_threshold"
        ),
    )
    gate_breaker_reset_sec: int = Field(
        default=30,
        validation_alias=AliasChoices("GATE_BREAKER_RESET_SEC", "gate_breaker_reset_sec"),
    )
    status_cache_ttl_sec: int = Field(
        default=15,
        validation_alias=AliasChoices("STATUS_CACHE_TTL_SEC", "status_cache_ttl_sec"),
    )
    keeper_cache_ttl_sec: int = Field(
        default=30,
        validation_alias=AliasChoices("KEEPER_CACHE_TTL_SEC", "keeper_cache_ttl_sec"),
    )

    # State paths — SLACK_ prefix matches sidecar-local convention; the
    # MASC_SLACK_ alias lets OCaml-side env vars (MASC_SLACK_*_PATH) line up
    # when both halves of the stack are deployed by the same operator.
    binding_store_path: str = Field(
        default=DEFAULT_BINDING_STORE_PATH,
        validation_alias=AliasChoices(
            "SLACK_BINDING_STORE_PATH",
            "MASC_SLACK_BINDING_STORE_PATH",
            "binding_store_path",
        ),
    )
    status_path: str = Field(
        default=DEFAULT_STATUS_PATH,
        validation_alias=AliasChoices(
            "SLACK_STATUS_PATH",
            "MASC_SLACK_STATUS_PATH",
            "status_path",
        ),
    )
    # Legacy read-fallback (pre-v0.9.0 layout). Not env-configurable.
    legacy_binding_store_path: str = Field(default=LEGACY_BINDING_STORE_PATH)

    @field_validator("slack_bot_token")
    @classmethod
    def bot_token_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("SLACK_BOT_TOKEN is required")
        return v.strip()

    @field_validator("slack_app_token")
    @classmethod
    def app_token_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("SLACK_APP_TOKEN is required (Socket Mode)")
        return v.strip()

    @model_validator(mode="after")
    def validate_gate_auth(self) -> BotConfig:
        if self.gate_api_token or self._gate_is_loopback():
            return self
        raise ValueError(
            "GATE_API_TOKEN is required unless gate URL points at a loopback host"
        )

    def _gate_is_loopback(self) -> bool:
        parsed = urlparse(self.gate_base_url)
        return _is_loopback_host(parsed.hostname)

    def gate_origin(self) -> str:
        parsed = urlparse(self.gate_base_url)
        if parsed.scheme and parsed.netloc:
            return f"{parsed.scheme}://{parsed.netloc}"
        return self.gate_base_url.rstrip("/")


_config: BotConfig | None = None

SLACK_MESSAGE_LIMIT: Final[int] = 4000  # Slack blocks text limit


def get_config() -> BotConfig:
    """Get or create the singleton config."""
    global _config  # noqa: PLW0603
    if _config is None:
        _config = BotConfig()  # type: ignore[call-arg]
    return _config
