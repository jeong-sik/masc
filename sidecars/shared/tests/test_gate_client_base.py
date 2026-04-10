"""Tests for GateClientBase circuit breaker and HTTP transport."""

from __future__ import annotations

import time
from unittest.mock import AsyncMock, patch

import pytest

from gate_shared import BreakerSnapshot, GateClientBase, GateResponse


def _make_client(**kwargs: object) -> GateClientBase:
    defaults = {
        "agent_name": "test-bot",
        "gate_base_url": "http://localhost:8935",
        "gate_api_token": "",
        "gate_origin": "http://localhost:8935",
        "timeout_sec": 5.0,
        "breaker_failure_threshold": 3,
        "breaker_reset_sec": 10,
    }
    defaults.update(kwargs)
    return GateClientBase(**defaults)  # type: ignore[arg-type]


class TestURLConstruction:
    def test_builds_api_urls(self) -> None:
        c = _make_client(gate_base_url="http://example.com:9000/")
        assert c._message_url == "http://example.com:9000/api/v1/gate/message"
        assert c._health_url == "http://example.com:9000/api/v1/gate/health"
        assert c._keepers_url == "http://example.com:9000/api/v1/gate/keepers"

    def test_strips_trailing_slash(self) -> None:
        c = _make_client(gate_base_url="http://localhost:8935///")
        assert c._message_url == "http://localhost:8935/api/v1/gate/message"


class TestHeaders:
    def test_bearer_token_when_provided(self) -> None:
        c = _make_client(gate_api_token="secret123")
        assert c._headers["Authorization"] == "Bearer secret123"
        assert "Origin" not in c._headers

    def test_origin_fallback_when_no_token(self) -> None:
        c = _make_client(gate_api_token="", gate_origin="http://localhost:8935")
        assert "Authorization" not in c._headers
        assert c._headers["Origin"] == "http://localhost:8935"

    def test_agent_name_header(self) -> None:
        c = _make_client(agent_name="my-bot")
        assert c._headers["X-Gate-Agent"] == "my-bot"


class TestCircuitBreaker:
    def test_starts_closed(self) -> None:
        c = _make_client()
        assert not c._breaker_is_open()

    def test_opens_after_threshold_failures(self) -> None:
        c = _make_client(breaker_failure_threshold=2)
        c._note_transport_failure("fail 1")
        assert not c._breaker_is_open()
        c._note_transport_failure("fail 2")
        assert c._breaker_is_open()

    def test_resets_on_success(self) -> None:
        c = _make_client(breaker_failure_threshold=2)
        c._note_transport_failure("fail 1")
        c._note_transport_failure("fail 2")
        assert c._breaker_is_open()
        c._note_success()
        assert not c._breaker_is_open()
        assert c._consecutive_failures == 0

    def test_snapshot(self) -> None:
        c = _make_client(breaker_failure_threshold=2)
        snap = c.breaker_snapshot()
        assert snap.open is False
        assert snap.consecutive_failures == 0
        assert snap.last_failure == ""

        c._note_transport_failure("timeout")
        c._note_transport_failure("timeout again")
        snap = c.breaker_snapshot()
        assert snap.open is True
        assert snap.consecutive_failures == 2
        assert snap.last_failure == "timeout again"

    def test_disabled_breaker(self) -> None:
        c = _make_client(breaker_failure_threshold=0)
        assert not c._breaker_enabled()
        c._note_transport_failure("fail")
        c._note_transport_failure("fail")
        c._note_transport_failure("fail")
        assert not c._breaker_is_open()


class TestCacheFreshness:
    def test_fresh_cache(self) -> None:
        c = _make_client()
        cache = (time.monotonic(), {"data": "test"})
        assert c._cache_fresh(cache, ttl=60)

    def test_stale_cache(self) -> None:
        c = _make_client()
        cache = (time.monotonic() - 100, {"data": "test"})
        assert not c._cache_fresh(cache, ttl=60)

    def test_none_cache(self) -> None:
        c = _make_client()
        assert not c._cache_fresh(None, ttl=60)


class TestSendMessage:
    @pytest.mark.asyncio
    async def test_returns_error_when_breaker_open(self) -> None:
        c = _make_client(breaker_failure_threshold=1)
        c._note_transport_failure("forced open")
        resp = await c.send_message(
            keeper_name="test",
            content="hello",
            context={"channel": "test"},
            idempotency_key="key-1",
        )
        assert not resp.ok
        assert "circuit open" in resp.error
