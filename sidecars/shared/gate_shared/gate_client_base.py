"""Base Channel Gate client with circuit breaker and HTTP transport.

Connector-specific clients subclass this and provide their
``_channel_context()`` method.
"""

from __future__ import annotations

import json as json_mod
import logging
import time
from collections.abc import AsyncIterator
from dataclasses import dataclass
from typing import Any, cast

import httpx

try:
    import httpx_sse as _httpx_sse
except ImportError:
    _httpx_sse = None

from .gate_response import GateResponse

logger = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class BreakerSnapshot:
    """Current transport breaker state."""

    open: bool
    remaining_sec: int
    consecutive_failures: int
    last_failure: str


class GateClientBase:
    """HTTP client for the Channel Gate API with circuit breaker.

    Subclass and implement ``_channel_context()`` for each connector.
    """

    def __init__(
        self,
        *,
        agent_name: str,
        gate_base_url: str,
        gate_api_token: str,
        gate_origin: str,
        timeout_sec: float = 30.0,
        breaker_failure_threshold: int = 3,
        breaker_reset_sec: int = 30,
        status_cache_ttl_sec: int = 15,
        keeper_cache_ttl_sec: int = 30,
    ) -> None:
        base = gate_base_url.rstrip("/")
        self._agent_name = agent_name
        self._message_url = f"{base}/api/v1/gate/message"
        self._health_url = f"{base}/api/v1/gate/health"
        self._status_url = f"{base}/api/v1/gate/status"
        self._keepers_url = f"{base}/api/v1/gate/keepers"
        self._keeper_status_url = f"{base}/api/v1/gate/keeper-status"
        self._stream_url = f"{base}/api/v1/keepers/chat/stream"
        self._timeout = timeout_sec
        self._breaker_failure_threshold = breaker_failure_threshold
        self._breaker_reset_sec = breaker_reset_sec
        self._status_cache_ttl = status_cache_ttl_sec
        self._keeper_cache_ttl = keeper_cache_ttl_sec

        self._headers = self._build_headers(gate_api_token, gate_origin)
        self._client: httpx.AsyncClient | None = None
        self._consecutive_failures = 0
        self._breaker_open_until = 0.0
        self._last_failure = ""
        self._status_cache: tuple[float, dict[str, Any]] | None = None
        self._keeper_names_cache: tuple[float, list[str]] | None = None
        self._keeper_status_cache: dict[str, tuple[float, dict[str, Any]]] = {}

    def _build_headers(self, token: str, origin: str) -> dict[str, str]:
        headers: dict[str, str] = {
            "Content-Type": "application/json",
            "X-Gate-Agent": self._agent_name,
        }
        if token:
            headers["Authorization"] = f"Bearer {token}"
        else:
            headers["Origin"] = origin
        return headers

    # ── Time / Circuit Breaker ─────────────────────────────

    def _now(self) -> float:
        return time.monotonic()

    def _breaker_is_open(self) -> bool:
        return self._breaker_open_until > self._now()

    def _breaker_enabled(self) -> bool:
        return self._breaker_failure_threshold > 0 and self._breaker_reset_sec > 0

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
        if self._breaker_enabled() and self._consecutive_failures >= self._breaker_failure_threshold:
            self._breaker_open_until = self._now() + self._breaker_reset_sec
        logger.warning(
            "Gate transport failure %d/%d: %s",
            self._consecutive_failures,
            self._breaker_failure_threshold,
            reason,
        )

    def breaker_snapshot(self) -> BreakerSnapshot:
        remaining = max(0, int(round(self._breaker_open_until - self._now())))
        return BreakerSnapshot(
            open=self._breaker_is_open(),
            remaining_sec=remaining,
            consecutive_failures=self._consecutive_failures,
            last_failure=self._last_failure,
        )

    # ── HTTP Client ────────────────────────────────────────

    def _get_client(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                timeout=self._timeout,
                headers=self._headers,
            )
        return self._client

    async def aclose(self) -> None:
        if self._client is not None and not self._client.is_closed:
            await self._client.aclose()
            self._client = None

    def _cache_fresh(self, cache: tuple[float, Any] | None, ttl: int | float) -> bool:
        return cache is not None and (self._now() - cache[0]) < ttl

    # ── Generic JSON Request ───────────────────────────────

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
                allow_breaker_cache, self._status_cache_ttl
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
            self._note_success()
            return cast(dict[str, Any], raw_data)
        except httpx.TimeoutException:
            self._note_transport_failure(f"gate timeout after {self._timeout}s")
            return None
        except httpx.HTTPError as e:
            self._note_transport_failure(f"gate http error: {e}")
            return None
        except Exception as e:
            self._note_transport_failure(f"gate error: {e}")
            return None

    # ── Gate API Methods ───────────────────────────────────

    async def send_message(
        self,
        *,
        keeper_name: str,
        content: str,
        context: dict[str, str],
        idempotency_key: str,
    ) -> GateResponse:
        """Send a message to a keeper via the gate.

        Args:
            keeper_name: Target keeper.
            content: Message text.
            context: Channel-specific context (channel, channel_user_id, etc.)
            idempotency_key: Unique key to prevent duplicate processing.
        """
        if self._breaker_is_open():
            return GateResponse.from_error(self._breaker_error())

        payload = {
            **context,
            "keeper_name": keeper_name,
            "content": content,
            "idempotency_key": idempotency_key,
        }

        client = self._get_client()
        try:
            resp = await client.post(self._message_url, json=payload)
            if resp.status_code == 409:
                self._note_success()
                return GateResponse.from_error("duplicate message")
            if resp.status_code >= 500:
                self._note_transport_failure(f"gate returned {resp.status_code}")
                return GateResponse.from_error(f"gate returned {resp.status_code}")

            raw_data = resp.json()
            if not isinstance(raw_data, dict):
                self._note_success()
                return GateResponse.from_error("gate returned invalid json")

            self._note_success()
            return GateResponse.from_json(cast(dict[str, Any], raw_data))
        except httpx.TimeoutException:
            self._note_transport_failure(f"gate timeout after {self._timeout}s")
            return GateResponse.from_error(f"gate timeout after {self._timeout}s")
        except httpx.HTTPError as e:
            self._note_transport_failure(f"gate http error: {e}")
            return GateResponse.from_error(f"gate http error: {e}")
        except Exception as e:
            self._note_transport_failure(f"gate error: {e}")
            return GateResponse.from_error(f"gate error: {e}")

    async def health_check(self) -> bool:
        """Check if the gate is reachable."""
        if self._status_cache is not None and self._cache_fresh(
            self._status_cache, self._status_cache_ttl
        ):
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

    # ── SSE Streaming ──────────────────────────────────────

    async def stream_keeper(
        self,
        *,
        keeper_name: str,
        message: str,
        context: dict[str, str],
    ) -> AsyncIterator[str]:
        """Stream a message to a keeper via SSE, yielding text deltas.

        Uses POST /api/v1/keepers/chat/stream which returns AG-UI SSE events.
        Only TEXT_MESSAGE_CONTENT deltas are yielded as strings.
        Requires httpx-sse; yields nothing if the library is not installed.
        Transport failures are recorded and raised to the caller.
        """
        if _httpx_sse is None:
            logger.warning("httpx-sse not installed; streaming unavailable")
            return
        if self._breaker_is_open():
            return

        payload = {
            "name": keeper_name,
            "message": message,
            **context,
        }
        client = self._get_client()

        try:
            async with _httpx_sse.aconnect_sse(
                client,
                "POST",
                self._stream_url,
                json=payload,
                timeout=httpx.Timeout(
                    connect=self._timeout,
                    read=None,
                    write=self._timeout,
                    pool=self._timeout,
                ),
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
        except httpx.TimeoutException as e:
            self._note_transport_failure(f"stream transport timeout: {e}")
            raise
        except httpx.HTTPError as e:
            self._note_transport_failure(f"stream http error: {e}")
            raise
        except Exception as e:  # pragma: no cover
            self._note_transport_failure(f"stream error: {e}")
            raise

    # ── Activity Polling ─────────────────────────────────

    async def poll_activity(
        self,
        *,
        after_seq: int = 0,
        kinds: list[str] | None = None,
        limit: int = 50,
    ) -> list[dict[str, Any]]:
        """Poll recent activity events from the replay API.

        Returns events with seq > after_seq.  Caller tracks the
        high-water seq for incremental polling.
        """
        client = self._get_client()
        base = self._message_url.rsplit("/api/", 1)[0]
        url = f"{base}/api/v1/activity/events"

        params: dict[str, str | int] = {
            "after_seq": after_seq,
            "limit": limit,
        }
        if kinds:
            params["kinds"] = ",".join(kinds)

        try:
            resp = await client.get(
                url,
                params=params,
                timeout=httpx.Timeout(timeout=10.0, connect=5.0),
            )
            if resp.status_code >= 400:
                return []
            data: object = resp.json()
            if isinstance(data, dict):
                events = data.get("events", [])
                if isinstance(events, list):
                    return [cast(dict[str, Any], e) for e in events if isinstance(e, dict)]
        except Exception as e:  # pragma: no cover
            logger.warning("Activity poll error: %s", e)
        return []
