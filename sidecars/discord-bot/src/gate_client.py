"""HTTP client for the Channel Gate API.

All communication with the gate goes through this module.
The gate is the only interface; no direct keeper access.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from collections.abc import AsyncIterator
from typing import Any, cast

import json as json_mod

import httpx
import httpx_sse

from .config import get_config

logger = logging.getLogger(__name__)

CONNECTOR_AGENT_NAME = "discord-gate-bot"


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
        raw_stats = data.get("turn_stats")
        stats = cast(dict[str, Any], raw_stats) if isinstance(raw_stats, dict) else {}
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


@dataclass(frozen=True, slots=True)
class BreakerSnapshot:
    """Current transport breaker state."""

    open: bool
    remaining_sec: int
    consecutive_failures: int
    last_failure: str


class GateClient:
    """HTTP client for the Channel Gate API.

    Uses a shared httpx.AsyncClient for connection pooling.
    Call ``aclose()`` on shutdown to release the underlying pool.
    """

    def __init__(self) -> None:
        cfg = get_config()
        base = cfg.gate_base_url.rstrip("/")
        self._url = cfg.gate_message_url()
        self._health_url = cfg.gate_health_url()
        self._status_url = f"{base}/api/v1/gate/status"
        self._keepers_url = f"{base}/api/v1/gate/keepers"
        self._keeper_status_url = f"{base}/api/v1/gate/keeper-status"
        self._stream_url = f"{base}/api/v1/keepers/chat/stream"
        self._timeout = cfg.gate_timeout_sec
        self._max_retries = cfg.gate_max_retries
        self._status_cache_ttl = cfg.status_cache_ttl_sec
        self._keeper_cache_ttl = cfg.keeper_cache_ttl_sec
        self._breaker_failure_threshold = cfg.gate_breaker_failure_threshold
        self._breaker_reset_sec = cfg.gate_breaker_reset_sec
        self._headers = self._build_headers(cfg)
        self._client: httpx.AsyncClient | None = None
        self._consecutive_failures = 0
        self._breaker_open_until = 0.0
        self._last_failure = ""
        self._status_cache: tuple[float, dict[str, Any]] | None = None
        self._keeper_names_cache: tuple[float, list[str]] | None = None
        self._keeper_status_cache: dict[str, tuple[float, dict[str, Any]]] = {}

    def _build_headers(self, cfg: Any) -> dict[str, str]:
        headers = {
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

    def _breaker_enabled(self) -> bool:
        return self._breaker_failure_threshold > 0 and self._breaker_reset_sec > 0

    def _max_attempts(self) -> int:
        return 1 + max(0, self._max_retries)

    def _breaker_error(self) -> str:
        remaining = max(1, int(round(self._breaker_open_until - self._now())))
        if self._last_failure:
            return (
                f"connector circuit open for {remaining}s after transport failures: "
                f"{self._last_failure}"
            )
        return f"connector circuit open for {remaining}s after transport failures"

    def _note_success(self) -> None:
        self._consecutive_failures = 0
        self._breaker_open_until = 0.0
        self._last_failure = ""

    def _note_transport_failure(self, reason: str) -> None:
        self._consecutive_failures += 1
        self._last_failure = reason
        breaker_enabled = self._breaker_enabled()
        if breaker_enabled and self._consecutive_failures >= self._breaker_failure_threshold:
            self._breaker_open_until = self._now() + self._breaker_reset_sec
        if breaker_enabled:
            msg = "Gate transport failure %d/%d: %s"
            args = (
                self._consecutive_failures,
                self._breaker_failure_threshold,
                reason,
            )
        else:
            msg = "Gate transport failure %d (breaker disabled): %s"
            args = (
                self._consecutive_failures,
                reason,
            )
        logger.warning(msg, *args)

    def breaker_snapshot(self) -> BreakerSnapshot:
        remaining = max(0, int(round(self._breaker_open_until - self._now())))
        return BreakerSnapshot(
            open=self._breaker_is_open(),
            remaining_sec=remaining,
            consecutive_failures=self._consecutive_failures,
            last_failure=self._last_failure,
        )

    def _cache_fresh(self, cache: tuple[float, Any] | None, ttl: int) -> bool:
        return cache is not None and (self._now() - cache[0]) < ttl

    def _get_client(self) -> httpx.AsyncClient:
        """Return the shared client, lazily creating it on first use."""
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                timeout=self._timeout,
                headers=self._headers,
            )
        return self._client

    async def aclose(self) -> None:
        """Close the underlying HTTP client and release connections."""
        if self._client is not None and not self._client.is_closed:
            await self._client.aclose()
            self._client = None

    async def _request_json(
        self,
        method: str,
        url: str,
        *,
        json_body: dict[str, Any] | None = None,
        params: dict[str, str] | None = None,
        allow_breaker_cache: tuple[float, dict[str, Any]] | None = None,
    ) -> dict[str, Any] | None:
        if self._breaker_is_open():
            if allow_breaker_cache is not None and self._cache_fresh(
                allow_breaker_cache,
                self._status_cache_ttl,
            ):
                return allow_breaker_cache[1]
            logger.warning("Gate request short-circuited: %s", self._breaker_error())
            return None

        client = self._get_client()
        try:
            response = await client.request(method, url, json=json_body, params=params)
            if response.status_code >= 500:
                self._note_transport_failure(f"gate returned {response.status_code}")
                return None
            if response.status_code >= 400:
                logger.info("Gate returned %d for %s %s", response.status_code, method, url)
                self._note_success()
                return None
            raw_data = response.json()
            if not isinstance(raw_data, dict):
                logger.warning("Gate returned non-object JSON from %s %s", method, url)
                self._note_success()
                return None
            data = cast(dict[str, Any], raw_data)
            self._note_success()
            return data
        except httpx.TimeoutException:
            self._note_transport_failure(f"gate timeout after {self._timeout}s")
            return None
        except httpx.HTTPError as e:
            self._note_transport_failure(f"gate http error: {e}")
            return None
        except Exception as e:  # pragma: no cover - defensive logging
            self._note_transport_failure(f"gate error: {e}")
            return None

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
        """Send a message to a keeper via the gate."""
        if self._breaker_is_open():
            return GateResponse.from_error(self._breaker_error())

        payload = {
            "channel": "discord",
            "channel_user_id": channel_user_id,
            "channel_user_name": channel_user_name,
            "channel_room_id": channel_room_id,
            "keeper_name": keeper_name,
            "content": content,
            "idempotency_key": f"discord-msg-{message_id}",
        }

        client = self._get_client()
        try:
            # POST /gate/message is currently not replay-safe across 5xx/timeouts.
            # Retrying with the same idempotency key only converts the first
            # transport error into a noisy duplicate response for slash commands.
            resp = await client.post(self._url, json=payload)
            if resp.status_code == 409:
                self._note_success()
                logger.info("Duplicate message (idempotency): %s", message_id)
                return GateResponse.from_error("duplicate message")

            if resp.status_code >= 500:
                self._note_transport_failure(f"gate returned {resp.status_code}")
                return GateResponse.from_error(f"gate returned {resp.status_code}")

            raw_data = resp.json()
            if not isinstance(raw_data, dict):
                self._note_success()
                return GateResponse.from_error("gate returned invalid json")
            data = cast(dict[str, Any], raw_data)

            self._note_success()
            return GateResponse.from_json(data)

        except httpx.TimeoutException:
            self._note_transport_failure(f"gate timeout after {self._timeout}s")
            return GateResponse.from_error(f"gate timeout after {self._timeout}s")
        except httpx.HTTPError as e:
            self._note_transport_failure(f"gate http error: {e}")
            return GateResponse.from_error(f"gate http error: {e}")
        except Exception as e:  # pragma: no cover - defensive logging
            self._note_transport_failure(f"gate error: {e}")
            return GateResponse.from_error(f"gate error: {e}")

    async def health_check(self) -> bool:
        """Check if the gate is reachable."""
        cached: dict[str, Any] | None = None
        if self._status_cache is not None and self._cache_fresh(
            self._status_cache,
            self._status_cache_ttl,
        ):
            cached = self._status_cache[1]
        if cached is not None:
            return True
        if self._breaker_is_open():
            return False
        data = await self._request_json("GET", self._health_url)
        return data is not None

    async def gate_status(self, *, force: bool = False) -> dict[str, Any] | None:
        """Fetch the enriched connector status snapshot."""
        if not force and self._cache_fresh(self._status_cache, self._status_cache_ttl):
            assert self._status_cache is not None
            return self._status_cache[1]
        data = await self._request_json(
            "GET",
            self._status_url,
            allow_breaker_cache=self._status_cache,
        )
        if data is None:
            if self._cache_fresh(self._status_cache, self._status_cache_ttl):
                assert self._status_cache is not None
                return self._status_cache[1]
            return None
        self._status_cache = (self._now(), data)
        return data

    async def list_keepers(self, *, force: bool = False) -> list[str]:
        """Return keeper names for autocomplete and binding validation."""
        if not force and self._cache_fresh(self._keeper_names_cache, self._keeper_cache_ttl):
            assert self._keeper_names_cache is not None
            return self._keeper_names_cache[1]

        data = await self._request_json(
            "GET",
            self._keepers_url,
            params={"limit": "200", "detailed": "true"},
        )
        if data is None:
            if self._cache_fresh(self._keeper_names_cache, self._keeper_cache_ttl):
                assert self._keeper_names_cache is not None
                return self._keeper_names_cache[1]
            return []

        rows = data.get("keepers", [])
        names: list[str] = []
        if isinstance(rows, list):
            for item in cast(list[object], rows):
                if isinstance(item, dict):
                    row = cast(dict[str, Any], item)
                    name = row.get("name")
                    if isinstance(name, str) and name.strip():
                        names.append(name.strip())
                elif isinstance(item, str) and item.strip():
                    names.append(item.strip())
        self._keeper_names_cache = (self._now(), names)
        return names

    async def stream_message(
        self,
        *,
        keeper_name: str,
        content: str,
    ) -> AsyncIterator[str]:
        """Stream a message to a keeper via SSE, yielding text deltas.

        Uses POST /api/v1/keepers/chat/stream which returns AG-UI SSE events.
        Only TEXT_MESSAGE_CONTENT deltas are yielded as strings.
        Falls back to send_message on transport error (caller gets nothing streamed).
        """
        if self._breaker_is_open():
            return

        payload = {"name": keeper_name, "message": content}
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
                    event_type = event.get("type", "")
                    if event_type == "TEXT_MESSAGE_CONTENT":
                        delta = event.get("delta", "")
                        if delta:
                            yield delta
                    elif event_type == "RUN_ERROR":
                        custom = event.get("customValue", {})
                        err = custom.get("message", "") if isinstance(custom, dict) else ""
                        logger.warning("Keeper stream error: %s", err)
                        return
        except httpx.TimeoutException:
            self._note_transport_failure(f"stream timeout after 300s")
        except httpx.HTTPError as e:
            self._note_transport_failure(f"stream http error: {e}")
        except Exception as e:  # pragma: no cover
            self._note_transport_failure(f"stream error: {e}")

    async def keeper_status(
        self,
        keeper_name: str,
        *,
        force: bool = False,
    ) -> dict[str, Any] | None:
        """Fetch status for a single keeper."""
        normalized = keeper_name.strip()
        if not normalized:
            return None

        cached = self._keeper_status_cache.get(normalized)
        if not force and self._cache_fresh(cached, self._keeper_cache_ttl):
            assert cached is not None
            return cached[1]

        data = await self._request_json(
            "GET",
            self._keeper_status_url,
            params={"name": normalized},
        )
        if data is None:
            if self._cache_fresh(cached, self._keeper_cache_ttl):
                assert cached is not None
                return cached[1]
            return None
        self._keeper_status_cache[normalized] = (self._now(), data)
        return data
