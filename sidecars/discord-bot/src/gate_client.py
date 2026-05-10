"""Discord-specific Gate client.

Thin adapter over the shared GateClientBase. Adds Discord-specific
channel context and delegates SSE streaming to the base class.

All communication with the gate goes through this module.
The gate is the only interface; no direct keeper access.
"""

from __future__ import annotations

import logging
import sys
from collections.abc import AsyncIterator
from pathlib import Path

# Add shared module to path
_shared_root = Path(__file__).resolve().parent.parent.parent / "shared"
if str(_shared_root) not in sys.path:
    sys.path.insert(0, str(_shared_root))

from gate_shared import BreakerSnapshot, GateClientBase, GateResponse  # noqa: E402

from .config import get_config  # noqa: E402

# Re-export for backward compatibility
__all__ = ["BreakerSnapshot", "GateClient", "GateResponse"]

logger = logging.getLogger(__name__)

CONNECTOR_AGENT_NAME = "discord-gate-bot"


class GateClient(GateClientBase):
    """Discord-specific gate client.

    Uses a shared httpx.AsyncClient for connection pooling.
    Call ``aclose()`` on shutdown to release the underlying pool.
    """

    def __init__(self) -> None:
        cfg = get_config()
        super().__init__(
            agent_name=CONNECTOR_AGENT_NAME,
            gate_base_url=cfg.gate_base_url,
            gate_api_token=cfg.gate_api_token,
            gate_origin=cfg.gate_origin(),
            timeout_sec=cfg.gate_timeout_sec,
            breaker_failure_threshold=cfg.gate_breaker_failure_threshold,
            breaker_reset_sec=cfg.gate_breaker_reset_sec,
            status_cache_ttl_sec=cfg.status_cache_ttl_sec,
            keeper_cache_ttl_sec=cfg.keeper_cache_ttl_sec,
        )

    def _discord_context(
        self,
        *,
        channel_user_id: str,
        channel_user_name: str,
        channel_room_id: str,
    ) -> dict[str, str]:
        return {
            "channel": "discord",
            "channel_user_id": channel_user_id,
            "channel_user_name": channel_user_name,
            "channel_room_id": channel_room_id,
        }

    async def send_message(  # type: ignore[override]
        self,
        *,
        keeper_name: str,
        content: str,
        channel_user_id: str,
        channel_user_name: str,
        channel_room_id: str,
        message_id: str,
        idempotency_key: str | None = None,
    ) -> GateResponse:
        """Send a message to a keeper via the gate with Discord context."""
        context = self._discord_context(
            channel_user_id=channel_user_id,
            channel_user_name=channel_user_name,
            channel_room_id=channel_room_id,
        )
        return await super().send_message(
            keeper_name=keeper_name,
            content=content,
            context=context,
            idempotency_key=idempotency_key or f"discord-msg-{message_id}",
        )

    async def stream_message(
        self,
        *,
        keeper_name: str,
        content: str,
        channel_user_id: str,
        channel_user_name: str,
        channel_room_id: str,
    ) -> AsyncIterator[str]:
        """Stream a message to a keeper via SSE, yielding text deltas."""
        context = self._discord_context(
            channel_user_id=channel_user_id,
            channel_user_name=channel_user_name,
            channel_room_id=channel_room_id,
        )
        async for delta in self.stream_keeper(
            keeper_name=keeper_name,
            message=content,
            context=context,
        ):
            yield delta
