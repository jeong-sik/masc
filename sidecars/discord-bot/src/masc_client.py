"""HTTP client for the MASC Channel Gate API.

All communication with the gate goes through this module.
The gate is the only interface -- no direct keeper access.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any

import httpx

from .config import get_config

logger = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class GateResponse:
    """Parsed response from POST /api/v1/gate/message."""

    ok: bool
    keeper_name: str
    reply: str
    model_used: str
    duration_ms: int
    tokens_used: int
    error: str

    @staticmethod
    def from_json(data: dict[str, Any]) -> GateResponse:
        stats = data.get("turn_stats") or {}
        return GateResponse(
            ok=bool(data.get("ok", False)),
            keeper_name=str(data.get("keeper_name", "")),
            reply=str(data.get("reply", "")),
            model_used=str(stats.get("model_used", "")),
            duration_ms=int(stats.get("duration_ms", 0)),
            tokens_used=int(stats.get("tokens_used", 0)),
            error=str(data.get("error", "")),
        )

    @staticmethod
    def from_error(msg: str) -> GateResponse:
        return GateResponse(
            ok=False,
            keeper_name="",
            reply="",
            model_used="",
            duration_ms=0,
            tokens_used=0,
            error=msg,
        )


class MascGateClient:
    """HTTP client for the Channel Gate API."""

    def __init__(self) -> None:
        cfg = get_config()
        self._url = cfg.gate_message_url()
        self._health_url = cfg.gate_health_url()
        self._timeout = cfg.gate_timeout_sec
        self._max_retries = cfg.gate_max_retries
        self._headers = {
            "Authorization": f"Bearer {cfg.masc_api_token}",
            "Content-Type": "application/json",
        }

    async def send_message(
        self,
        *,
        keeper_name: str,
        content: str,
        channel_user_id: str,
        channel_user_name: str,
        channel_room_id: str,
        message_id: str,
    ) -> GateResponse:
        """Send a message to a keeper via the gate.

        Args:
            keeper_name: Target keeper name.
            content: Message text.
            channel_user_id: Discord user snowflake.
            channel_user_name: Discord display name.
            channel_room_id: Discord channel snowflake.
            message_id: Discord message ID (used as idempotency key).

        Returns:
            GateResponse with keeper's reply or error.
        """
        payload = {
            "channel": "discord",
            "channel_user_id": channel_user_id,
            "channel_user_name": channel_user_name,
            "channel_room_id": channel_room_id,
            "keeper_name": keeper_name,
            "content": content,
            "idempotency_key": f"discord-msg-{message_id}",
        }

        for attempt in range(1, self._max_retries + 1):
            try:
                async with httpx.AsyncClient(timeout=self._timeout) as client:
                    resp = await client.post(
                        self._url,
                        json=payload,
                        headers=self._headers,
                    )

                data: dict[str, Any] = resp.json()

                if resp.status_code == 409:
                    # Duplicate message -- not an error, just skip.
                    logger.info("Duplicate message (idempotency): %s", message_id)
                    return GateResponse.from_error("duplicate message")

                if resp.status_code >= 500 and attempt < self._max_retries:
                    logger.warning(
                        "Gate returned %d, retry %d/%d",
                        resp.status_code,
                        attempt,
                        self._max_retries,
                    )
                    continue

                return GateResponse.from_json(data)

            except httpx.TimeoutException:
                logger.warning(
                    "Gate timeout (%ds), attempt %d/%d",
                    self._timeout,
                    attempt,
                    self._max_retries,
                )
                if attempt >= self._max_retries:
                    return GateResponse.from_error(
                        f"gate timeout after {self._timeout}s"
                    )
            except httpx.HTTPError as e:
                logger.error("Gate HTTP error: %s", e)
                return GateResponse.from_error(f"gate http error: {e}")
            except Exception as e:
                logger.error("Gate unexpected error: %s", e)
                return GateResponse.from_error(f"gate error: {e}")

        return GateResponse.from_error("max retries exceeded")

    async def health_check(self) -> bool:
        """Check if the gate is reachable."""
        try:
            async with httpx.AsyncClient(timeout=5) as client:
                resp = await client.get(self._health_url)
                return resp.status_code == 200
        except Exception:
            return False
