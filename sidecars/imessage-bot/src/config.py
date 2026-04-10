"""Configuration for iMessage Gate Bot.

Loads and validates all required environment variables.
Fails fast at startup if any required config is missing.
"""

from __future__ import annotations

import ipaddress
import os
from pathlib import Path
from typing import Final
from urllib.parse import urlparse

from pydantic import AliasChoices, Field, field_validator
from pydantic_settings import BaseSettings

DEFAULT_STATE_DIR: Final[str] = ".masc/connectors/imessage"
DEFAULT_BINDING_STORE_PATH: Final[str] = ".masc/connectors/imessage/bindings.json"
DEFAULT_BINDING_AUDIT_PATH: Final[str] = ".masc/connectors/imessage/binding_audit.jsonl"
DEFAULT_STATUS_PATH: Final[str] = ".masc/connectors/imessage/status.json"
DEFAULT_CURSOR_PATH: Final[str] = ".masc/connectors/imessage/cursor.json"
CHAT_DB_PATH: Final[str] = os.path.expanduser("~/Library/Messages/chat.db")


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
    """Bot configuration from environment variables."""

    model_config = {"env_prefix": "", "case_sensitive": True, "env_file": ".env"}

    # Gate connection
    gate_base_url: str = Field(
        default="http://127.0.0.1:8935",
        validation_alias=AliasChoices("MASC_GATE_URL", "gate_base_url"),
    )
    gate_api_token: str = Field(
        default="",
        validation_alias=AliasChoices("MASC_GATE_API_TOKEN", "gate_api_token"),
    )

    # Polling
    poll_interval_sec: float = Field(
        default=2.0,
        validation_alias=AliasChoices("IMESSAGE_POLL_INTERVAL", "poll_interval_sec"),
        description="Seconds between chat.db polls for new messages.",
    )

    # Gate HTTP
    gate_timeout_sec: float = Field(default=30.0)
    gate_max_retries: int = Field(default=1)
    gate_breaker_failure_threshold: int = Field(default=5)
    gate_breaker_reset_sec: int = Field(default=60)

    # Cache
    status_cache_ttl_sec: int = Field(default=10)
    keeper_cache_ttl_sec: int = Field(default=30)

    # State paths
    state_dir: str = Field(default=DEFAULT_STATE_DIR)
    binding_store_path: str = Field(default=DEFAULT_BINDING_STORE_PATH)
    binding_audit_path: str = Field(default=DEFAULT_BINDING_AUDIT_PATH)
    status_path: str = Field(default=DEFAULT_STATUS_PATH)
    cursor_path: str = Field(default=DEFAULT_CURSOR_PATH)

    # chat.db
    chat_db_path: str = Field(default=CHAT_DB_PATH)

    @field_validator("gate_base_url")
    @classmethod
    def validate_gate_url(cls, v: str) -> str:
        parsed = urlparse(v)
        if parsed.scheme not in ("http", "https"):
            raise ValueError(f"gate_base_url must be http(s), got {parsed.scheme}")
        if not parsed.hostname:
            raise ValueError("gate_base_url must have a hostname")
        return v.rstrip("/")

    @field_validator("poll_interval_sec")
    @classmethod
    def validate_poll_interval(cls, v: float) -> float:
        if v < 0.5:
            raise ValueError("poll_interval_sec must be >= 0.5")
        return v

    def gate_message_url(self) -> str:
        return f"{self.gate_base_url}/api/v1/gate/message"

    def gate_health_url(self) -> str:
        return f"{self.gate_base_url}/api/v1/gate/health"

    def gate_origin(self) -> str:
        parsed = urlparse(self.gate_base_url)
        return f"{parsed.scheme}://{parsed.netloc}"

    def is_loopback(self) -> bool:
        parsed = urlparse(self.gate_base_url)
        return _is_loopback_host(parsed.hostname)


_config: BotConfig | None = None


def get_config() -> BotConfig:
    global _config
    if _config is None:
        _config = BotConfig()
    return _config
