"""Telegram-specific Gate client.

Thin adapter over the shared GateClientBase. Only adds
Telegram-specific channel context.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Add shared module to path
_shared_root = Path(__file__).resolve().parent.parent.parent / "shared"
if str(_shared_root) not in sys.path:
    sys.path.insert(0, str(_shared_root))

from gate_shared import GateClientBase, GateResponse  # noqa: E402

from .config import get_config  # noqa: E402

# Re-export for convenience
__all__ = ["GateClient", "GateResponse"]


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
        context = {
            "channel": "telegram",
            "channel_user_id": str(user_id),
            "channel_user_name": username,
            "channel_room_id": str(chat_id),
        }
        return await self.send_message(
            keeper_name=keeper_name,
            content=content,
            context=context,
            idempotency_key=f"telegram-msg-{chat_id}-{message_id}",
        )
