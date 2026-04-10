"""HTTP client for the Channel Gate API.

Adapted from discord-bot/src/gate_client.py for iMessage connector.
The gate API is connector-agnostic; only the context payload differs.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from typing import Any, cast

import httpx

from .config import get_config

logger = logging.getLogger(__name__)

CONNECTOR_AGENT_NAME = "imessage-gate-bot"


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
    structured: dict[str, Any] | None

    @staticmethod
    def from_json(data: dict[str, Any]) -> GateResponse:
        raw_stats = data.get("turn_stats")
        stats = cast(dict[str, Any], raw_stats) if isinstance(raw_stats, dict) else {}
        raw_structured = data.get("structured")
        structured = cast(dict[str, Any], raw_structured) if isinstance(raw_structured, dict) else None
        return GateResponse(
            ok=bool(data.get("ok", False)),
            keeper_name=str(data.get("keeper_name", "")),
            reply=str(data.get("reply", "")),
            model_used=str(stats.get("model_used", "")),
            duration_ms=int(stats.get("duration_ms", 0)),
            tokens_used=int(stats.get("tokens_used", 0)),
            error=str(data.get("error", "")),
            structured=structured,
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
            structured=None,
        )


class GateClient:
    """HTTP client for the Channel Gate API."""

    def __init__(self) -> None:
        cfg = get_config()
        base = cfg.gate_base_url.rstrip("/")
        self._url = cfg.gate_message_url()
        self._health_url = cfg.gate_health_url()
        self._keepers_url = f"{base}/api/v1/gate/keepers"
        self._timeout = cfg.gate_timeout_sec
        self._breaker_failure_threshold = cfg.gate_breaker_failure_threshold
        self._breaker_reset_sec = cfg.gate_breaker_reset_sec
        self._consecutive_failures = 0
        self._breaker_open_until = 0.0
        self._last_failure = ""
        self._headers = self._build_headers(cfg)
        self._client: httpx.AsyncClient | None = None

    def _build_headers(self, cfg: Any) -> dict[str, str]:
        headers: dict[str, str] = {
            "Content-Type": "application/json",
            "X-Gate-Agent": CONNECTOR_AGENT_NAME,
        }
        if cfg.gate_api_token:
            headers["Authorization"] = f"Bearer {cfg.gate_api_token}"
        else:
            headers["Origin"] = cfg.gate_origin()
        return headers

    def _now(self) -> float:
        return time.monotonic()

    def _breaker_is_open(self) -> bool:
        return self._breaker_open_until > self._now()

    def _note_success(self) -> None:
        self._consecutive_failures = 0
        self._breaker_open_until = 0.0

    def _note_failure(self, reason: str) -> None:
        self._consecutive_failures += 1
        self._last_failure = reason
        if (
            self._breaker_failure_threshold > 0
            and self._consecutive_failures >= self._breaker_failure_threshold
        ):
            self._breaker_open_until = self._now() + self._breaker_reset_sec
        logger.warning("Gate failure %d: %s", self._consecutive_failures, reason)

    def _get_client(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(timeout=self._timeout, headers=self._headers)
        return self._client

    async def aclose(self) -> None:
        if self._client is not None and not self._client.is_closed:
            await self._client.aclose()
            self._client = None

    def _imessage_context(
        self,
        *,
        sender: str,
        chat_id: str,
    ) -> dict[str, str]:
        return {
            "channel": "imessage",
            "channel_user_id": sender,
            "channel_user_name": sender,
            "channel_room_id": chat_id,
        }

    async def send_message(
        self,
        *,
        keeper_name: str,
        content: str,
        sender: str,
        chat_id: str,
        message_rowid: int,
    ) -> GateResponse:
        """Send a message to a keeper via the gate."""
        if self._breaker_is_open():
            remaining = max(1, int(round(self._breaker_open_until - self._now())))
            return GateResponse.from_error(f"circuit open for {remaining}s")

        payload = {
            **self._imessage_context(sender=sender, chat_id=chat_id),
            "keeper_name": keeper_name,
            "content": content,
            "idempotency_key": f"imessage-msg-{message_rowid}",
        }

        client = self._get_client()
        try:
            resp = await client.post(self._url, json=payload)
            if resp.status_code == 409:
                self._note_success()
                return GateResponse.from_error("duplicate message")

            if resp.status_code >= 500:
                self._note_failure(f"gate returned {resp.status_code}")
                return GateResponse.from_error(f"gate returned {resp.status_code}")

            raw_data = resp.json()
            if not isinstance(raw_data, dict):
                self._note_success()
                return GateResponse.from_error("gate returned invalid json")

            self._note_success()
            return GateResponse.from_json(cast(dict[str, Any], raw_data))

        except httpx.TimeoutException:
            self._note_failure(f"timeout after {self._timeout}s")
            return GateResponse.from_error(f"timeout after {self._timeout}s")
        except httpx.HTTPError as e:
            self._note_failure(f"http error: {e}")
            return GateResponse.from_error(f"http error: {e}")

    async def health_check(self) -> bool:
        if self._breaker_is_open():
            return False
        client = self._get_client()
        try:
            resp = await client.get(self._health_url)
            return resp.status_code < 400
        except Exception:
            return False

    async def list_keepers(self) -> list[str]:
        client = self._get_client()
        try:
            resp = await client.get(self._keepers_url, params={"limit": "200"})
            if resp.status_code >= 400:
                return []
            data = resp.json()
            rows = data.get("keepers", [])
            names: list[str] = []
            for item in rows if isinstance(rows, list) else []:
                if isinstance(item, dict):
                    name = item.get("name")
                    if isinstance(name, str) and name.strip():
                        names.append(name.strip())
                elif isinstance(item, str) and item.strip():
                    names.append(item.strip())
            return names
        except Exception:
            return []
