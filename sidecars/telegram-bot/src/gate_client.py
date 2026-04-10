"""Telegram-specific Gate client.

Thin adapter over the shared GateClientBase. Only adds
Telegram-specific channel context. SSE streaming is delegated
to the base class.
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

from gate_shared import GateClientBase, GateResponse  # noqa: E402

from .config import get_config  # noqa: E402

# Re-export for convenience
__all__ = ["GateClient", "GateResponse"]

logger = logging.getLogger(__name__)


class GateClient(GateClientBase):
    """Telegram-specific gate client."""

    def __init__(self) -> None:
        cfg = get_config()
        super().__init__(
            agent_name="telegram-gate-bot",
            gate_base_url=cfg.gate_base_url,
            gate_api_token=cfg.gate_api_token,
            gate_origin=cfg.gate_origin(),
            timeout_sec=cfg.gate_timeout_sec,
            breaker_failure_threshold=cfg.gate_breaker_failure_threshold,
            breaker_reset_sec=cfg.gate_breaker_reset_sec,
            status_cache_ttl_sec=cfg.status_cache_ttl_sec,
            keeper_cache_ttl_sec=cfg.keeper_cache_ttl_sec,
        )

    def _telegram_context(
        self, *, user_id: int, username: str, chat_id: int
    ) -> dict[str, str]:
        return {
            "channel": "telegram",
            "channel_user_id": str(user_id),
            "channel_user_name": username,
            "channel_room_id": str(chat_id),
        }

    async def send_telegram_message(
        self,
        *,
        keeper_name: str,
        content: str,
        user_id: int,
        username: str,
        chat_id: int,
        message_id: int,
    ) -> GateResponse:
        """Send a message to a keeper with Telegram context."""
        context = self._telegram_context(
            user_id=user_id, username=username, chat_id=chat_id
        )
        return await self.send_message(
            keeper_name=keeper_name,
            content=content,
            context=context,
            idempotency_key=f"telegram-msg-{chat_id}-{message_id}",
        )

    async def stream_message(
        self,
        *,
        keeper_name: str,
        content: str,
        user_id: int,
        username: str,
        chat_id: int,
    ) -> AsyncIterator[str]:
        """Stream a message to a keeper via SSE, yielding text deltas."""
        context = self._telegram_context(
            user_id=user_id, username=username, chat_id=chat_id
        )
        async for delta in self.stream_keeper(
            keeper_name=keeper_name,
            message=content,
            context=context,
        ):
            yield delta
