"""Configuration for MASC Discord Bot.

Loads and validates all required environment variables.
Fails fast at startup if any required config is missing.
"""

from __future__ import annotations

import json
from typing import Final, cast

from pydantic import AliasChoices, Field, field_validator
from pydantic_settings import BaseSettings


class BotConfig(BaseSettings):
    """Bot configuration from environment variables."""

    model_config = {"env_prefix": "", "case_sensitive": True, "env_file": ".env"}

    # Required
    discord_bot_token: str = Field(
        validation_alias=AliasChoices("DISCORD_BOT_TOKEN", "discord_bot_token")
    )
    masc_mcp_url: str = Field(
        default="http://localhost:8935",
        validation_alias=AliasChoices(
            "MASC_MCP_URL",
            "masc_mcp_url",
            "GATE_BASE_URL",
            "gate_base_url",
        ),
    )
    masc_api_token: str = Field(
        validation_alias=AliasChoices(
            "MASC_API_TOKEN",
            "masc_api_token",
            "GATE_API_TOKEN",
            "gate_api_token",
        )
    )

    # Channel-to-keeper mapping: {"channel_id": "keeper_name"}
    discord_keeper_map: str = Field(
        default="{}",
        validation_alias=AliasChoices("DISCORD_KEEPER_MAP", "discord_keeper_map"),
    )

    # Optional
    discord_admin_role_id: str = Field(
        default="",
        validation_alias=AliasChoices(
            "DISCORD_ADMIN_ROLE_ID",
            "discord_admin_role_id",
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
        validation_alias=AliasChoices("GATE_BREAKER_RESET_SEC", "gate_breaker_reset_sec"),
    )

    @field_validator("discord_bot_token")
    @classmethod
    def token_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("DISCORD_BOT_TOKEN is required")
        return v.strip()

    @field_validator("masc_api_token")
    @classmethod
    def api_token_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("GATE_API_TOKEN (or legacy MASC_API_TOKEN) is required")
        return v.strip()

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

    def gate_message_url(self) -> str:
        base = self.masc_mcp_url.rstrip("/")
        return f"{base}/api/v1/gate/message"

    def gate_health_url(self) -> str:
        base = self.masc_mcp_url.rstrip("/")
        return f"{base}/api/v1/gate/health"

    @property
    def gate_base_url(self) -> str:
        return self.masc_mcp_url

    @property
    def gate_api_token(self) -> str:
        return self.masc_api_token


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
