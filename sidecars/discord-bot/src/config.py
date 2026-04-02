"""Configuration for MASC Discord Bot.

Loads and validates all required environment variables.
Fails fast at startup if any required config is missing.
"""

from __future__ import annotations

import json
from typing import Final

from pydantic import field_validator
from pydantic_settings import BaseSettings


class BotConfig(BaseSettings):
    """Bot configuration from environment variables."""

    model_config = {"env_prefix": "", "case_sensitive": True}

    # Required
    discord_bot_token: str
    masc_mcp_url: str = "http://localhost:8935"
    masc_api_token: str

    # Channel-to-keeper mapping: {"channel_id": "keeper_name"}
    discord_keeper_map: str = "{}"

    # Optional
    discord_admin_role_id: str = ""

    # Timeouts
    gate_timeout_sec: int = 120
    gate_max_retries: int = 2

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
            raise ValueError("MASC_API_TOKEN is required")
        return v.strip()

    def keeper_map(self) -> dict[str, str]:
        """Parse DISCORD_KEEPER_MAP JSON into dict."""
        try:
            raw: object = json.loads(self.discord_keeper_map)
            if not isinstance(raw, dict):
                return {}
            return {str(k): str(v) for k, v in raw.items()}
        except json.JSONDecodeError:
            return {}

    def gate_message_url(self) -> str:
        base = self.masc_mcp_url.rstrip("/")
        return f"{base}/api/v1/gate/message"

    def gate_health_url(self) -> str:
        base = self.masc_mcp_url.rstrip("/")
        return f"{base}/api/v1/gate/health"


# Singleton - created at import time, fails fast on missing config.
_config: BotConfig | None = None

DISCORD_MESSAGE_LIMIT: Final[int] = 2000
DISCORD_EMBED_LIMIT: Final[int] = 4096


def get_config() -> BotConfig:
    """Get or create the singleton config."""
    global _config  # noqa: PLW0603
    if _config is None:
        _config = BotConfig()  # type: ignore[call-arg]
    return _config
