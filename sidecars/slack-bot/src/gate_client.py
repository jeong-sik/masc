"""Slack-specific Gate client.

Thin adapter over the shared GateClientBase.
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

__all__ = ["GateClient", "GateResponse"]

logger = logging.getLogger(__name__)


class GateClient(GateClientBase):
    """Slack-specific gate client."""

    def __init__(self) -> None:
        cfg = get_config()
        super().__init__(
            agent_name="slack-gate-bot",
            gate_base_url=cfg.gate_base_url,
            gate_api_token=cfg.gate_api_token,
            gate_origin=cfg.gate_origin(),
            timeout_sec=cfg.gate_timeout_sec,
            breaker_failure_threshold=cfg.gate_breaker_failure_threshold,
            breaker_reset_sec=cfg.gate_breaker_reset_sec,
            status_cache_ttl_sec=cfg.status_cache_ttl_sec,
            keeper_cache_ttl_sec=cfg.keeper_cache_ttl_sec,
        )

    def _slack_context(
        self, *, user_id: str, username: str, channel_id: str
    ) -> dict[str, str]:
        return {
            "channel": "slack",
            "channel_user_id": user_id,
            "channel_user_name": username,
            "channel_room_id": channel_id,
        }

    async def send_slack_message(
        self,
        *,
        keeper_name: str,
        content: str,
        user_id: str,
        username: str,
        channel_id: str,
        message_ts: str,
    ) -> GateResponse:
        """Send a message to a keeper with Slack context."""
        context = self._slack_context(
            user_id=user_id, username=username, channel_id=channel_id
        )
        return await self.send_message(
            keeper_name=keeper_name,
            content=content,
            context=context,
            idempotency_key=f"slack-msg-{channel_id}-{message_ts}",
        )

    async def stream_message(
        self,
        *,
        keeper_name: str,
        content: str,
        user_id: str,
        username: str,
        channel_id: str,
    ) -> AsyncIterator[str]:
        """Stream a message to a keeper via SSE, yielding text deltas."""
        context = self._slack_context(
            user_id=user_id, username=username, channel_id=channel_id
        )
        async for delta in self.stream_keeper(
            keeper_name=keeper_name,
            message=content,
            context=context,
        ):
            yield delta
