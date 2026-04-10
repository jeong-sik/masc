"""Discord-specific Gate client.

Thin adapter over the shared GateClientBase. Adds Discord-specific
channel context and SSE streaming support.

All communication with the gate goes through this module.
The gate is the only interface; no direct keeper access.
"""

from __future__ import annotations

import json as json_mod
import logging
import sys
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any, cast

import httpx
import httpx_sse

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
    """Discord-specific gate client with SSE streaming support.

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
            idempotency_key=f"discord-msg-{message_id}",
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
        """Stream a message to a keeper via SSE, yielding text deltas.

        Uses POST /api/v1/keepers/chat/stream which returns AG-UI SSE events.
        Only TEXT_MESSAGE_CONTENT deltas are yielded as strings.
        Falls back to send_message on transport error (caller gets nothing streamed).
        """
        if self._breaker_is_open():
            return

        payload = {
            "name": keeper_name,
            "message": content,
            **self._discord_context(
                channel_user_id=channel_user_id,
                channel_user_name=channel_user_name,
                channel_room_id=channel_room_id,
            ),
        }
        client = self._get_client()

        try:
            async with httpx_sse.aconnect_sse(
                client,
                "POST",
                self._stream_url,
                json=payload,
                timeout=httpx.Timeout(timeout=300.0, connect=10.0),
            ) as event_source:
                if event_source.response.status_code >= 400:
                    self._note_transport_failure(
                        f"stream returned {event_source.response.status_code}"
                    )
                    return
                self._note_success()
                async for sse in event_source.aiter_sse():
                    if not sse.data:
                        continue
                    try:
                        event = json_mod.loads(sse.data)
                    except json_mod.JSONDecodeError:
                        continue
                    if not isinstance(event, dict):
                        continue
                    event_data = cast(dict[str, Any], event)
                    event_type = str(event_data.get("type", ""))
                    if event_type == "TEXT_MESSAGE_CONTENT":
                        delta = str(event_data.get("delta", ""))
                        if delta:
                            yield delta
                    elif event_type == "RUN_ERROR":
                        custom_raw = event_data.get("customValue", {})
                        custom = (
                            cast(dict[str, Any], custom_raw)
                            if isinstance(custom_raw, dict)
                            else {}
                        )
                        err = str(custom.get("message", ""))
                        logger.warning("Keeper stream error: %s", err)
                        return
        except httpx.TimeoutException:
            self._note_transport_failure("stream timeout after 300s")
        except httpx.HTTPError as e:
            self._note_transport_failure(f"stream http error: {e}")
        except Exception as e:  # pragma: no cover
            self._note_transport_failure(f"stream error: {e}")
