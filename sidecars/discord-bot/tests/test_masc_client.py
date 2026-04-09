"""Tests for the Discord Channel Gate client."""

from __future__ import annotations

import json
import logging
from collections.abc import Iterator

import httpx
import pytest

from src import config as config_module
from src.config import BotConfig
from src.gate_client import GateClient


@pytest.fixture(autouse=True)
def reset_config(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    monkeypatch.setenv("DISCORD_BOT_TOKEN", "test-token")
    monkeypatch.setenv("GATE_API_TOKEN", "test-api-token")
    monkeypatch.setenv("GATE_BASE_URL", "http://localhost:8935")
    config_module.reset_config_cache()
    yield
    config_module.reset_config_cache()


def make_client(handler: httpx.MockTransport) -> GateClient:
    client = GateClient()
    client._client = httpx.AsyncClient(transport=handler, headers=client._headers)  # pyright: ignore[reportPrivateUsage]
    client._max_retries = 1  # pyright: ignore[reportPrivateUsage]
    client._breaker_failure_threshold = 2  # pyright: ignore[reportPrivateUsage]
    return client


@pytest.mark.asyncio
async def test_breaker_opens_after_repeated_server_failures() -> None:
    transport = httpx.MockTransport(
        lambda request: httpx.Response(503, json={"ok": False, "error": "down"})
    )
    client = make_client(transport)

    first = await client.send_message(
        keeper_name="luna",
        content="hello",
        channel_user_id="u1",
        channel_user_name="user",
        channel_room_id="room",
        message_id="m1",
    )
    second = await client.send_message(
        keeper_name="luna",
        content="hello again",
        channel_user_id="u1",
        channel_user_name="user",
        channel_room_id="room",
        message_id="m2",
    )
    third = await client.send_message(
        keeper_name="luna",
        content="still there?",
        channel_user_id="u1",
        channel_user_name="user",
        channel_room_id="room",
        message_id="m3",
    )

    assert first.ok is False
    assert second.ok is False
    assert client.breaker_snapshot().open is True
    assert "circuit open" in third.error

    await client.aclose()


@pytest.mark.asyncio
async def test_list_keepers_uses_cached_names_when_breaker_is_open() -> None:
    transport = httpx.MockTransport(
        lambda request: httpx.Response(
            200,
            json={
                "count": 2,
                "keepers": [{"name": "luna"}, {"name": "sangsu"}],
            },
        )
    )
    client = make_client(transport)

    keepers = await client.list_keepers(force=True)
    assert keepers == ["luna", "sangsu"]

    client._breaker_open_until = client._now() + 30  # pyright: ignore[reportPrivateUsage]
    cached = await client.list_keepers()
    assert cached == ["luna", "sangsu"]

    await client.aclose()


@pytest.mark.asyncio
async def test_send_message_does_not_retry_non_replay_safe_post() -> None:
    attempts = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal attempts
        attempts += 1
        return httpx.Response(503, json={"ok": False, "error": "down"})

    client = make_client(httpx.MockTransport(handler))
    response = await client.send_message(
        keeper_name="luna",
        content="hello",
        channel_user_id="u1",
        channel_user_name="user",
        channel_room_id="room",
        message_id="m4",
    )

    assert response.ok is False
    assert response.error == "gate returned 503"
    assert attempts == 1

    await client.aclose()


@pytest.mark.asyncio
async def test_stream_message_sends_discord_context_payload() -> None:
    seen_payload: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal seen_payload
        seen_payload = json.loads(request.content.decode("utf-8"))
        return httpx.Response(
            200,
            headers={"content-type": "text/event-stream"},
            content=b'data: {"type":"TEXT_MESSAGE_CONTENT","delta":"pong"}\n\n',
        )

    client = make_client(httpx.MockTransport(handler))
    deltas = [
        delta
        async for delta in client.stream_message(
            keeper_name="luna",
            content="hello",
            channel_user_id="u1",
            channel_user_name="alice",
            channel_room_id="room-7",
        )
    ]

    assert deltas == ["pong"]
    assert seen_payload == {
        "name": "luna",
        "message": "hello",
        "channel": "discord",
        "channel_user_id": "u1",
        "channel_user_name": "alice",
        "channel_room_id": "room-7",
    }

    await client.aclose()


@pytest.mark.asyncio
async def test_loopback_client_uses_origin_fallback_when_token_missing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    seen_headers: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen_headers.update({key.lower(): value for key, value in request.headers.items()})
        return httpx.Response(
            200,
            json={"ok": True, "keeper_name": "luna", "reply": "pong"},
        )

    monkeypatch.setenv("GATE_API_TOKEN", "")
    monkeypatch.setenv("GATE_BASE_URL", "http://127.0.0.1:8935")
    config_module.reset_config_cache()
    client = make_client(httpx.MockTransport(handler))

    response = await client.send_message(
        keeper_name="luna",
        content="hello",
        channel_user_id="u1",
        channel_user_name="user",
        channel_room_id="room",
        message_id="origin-fallback",
    )

    assert response.ok is True
    assert "authorization" not in seen_headers
    assert seen_headers["origin"] == "http://127.0.0.1:8935"
    assert seen_headers["x-gate-agent"] == "discord-gate-bot"

    await client.aclose()


@pytest.mark.asyncio
async def test_client_uses_bearer_auth_when_token_configured() -> None:
    seen_headers: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen_headers.update({key.lower(): value for key, value in request.headers.items()})
        return httpx.Response(
            200,
            json={"ok": True, "keeper_name": "luna", "reply": "pong"},
        )

    client = make_client(httpx.MockTransport(handler))

    response = await client.send_message(
        keeper_name="luna",
        content="hello",
        channel_user_id="u1",
        channel_user_name="user",
        channel_room_id="room",
        message_id="bearer-auth",
    )

    assert response.ok is True
    assert seen_headers["authorization"] == "Bearer test-api-token"
    assert seen_headers["x-gate-agent"] == "discord-gate-bot"
    assert "origin" not in seen_headers

    await client.aclose()


def test_config_allows_zero_disable_values(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GATE_MAX_RETRIES", raising=False)
    monkeypatch.delenv("STATUS_CACHE_TTL_SEC", raising=False)
    monkeypatch.delenv("KEEPER_CACHE_TTL_SEC", raising=False)
    monkeypatch.delenv("GATE_BREAKER_FAILURE_THRESHOLD", raising=False)
    monkeypatch.delenv("GATE_BREAKER_RESET_SEC", raising=False)

    cfg = BotConfig(
        discord_bot_token="test-token",
        gate_api_token="test-api-token",
        gate_max_retries=0,
        status_cache_ttl_sec=0,
        keeper_cache_ttl_sec=0,
        gate_breaker_failure_threshold=0,
        gate_breaker_reset_sec=0,
    )

    assert cfg.gate_max_retries == 0
    assert cfg.status_cache_ttl_sec == 0
    assert cfg.keeper_cache_ttl_sec == 0
    assert cfg.gate_breaker_failure_threshold == 0
    assert cfg.gate_breaker_reset_sec == 0


def test_config_allows_blank_token_for_loopback_url() -> None:
    cfg = BotConfig(
        discord_bot_token="test-token",
        gate_api_token="",
        gate_base_url="http://127.0.0.1:8935",
    )

    assert cfg.gate_api_token == ""
    assert cfg.gate_base_url_is_loopback() is True
    assert cfg.gate_origin() == "http://127.0.0.1:8935"


def test_config_rejects_blank_token_for_non_loopback_url() -> None:
    with pytest.raises(ValueError, match="GATE_API_TOKEN"):
        BotConfig(
            discord_bot_token="test-token",
            gate_api_token="",
            gate_base_url="https://gate.example.com",
        )


def test_transport_failure_log_mentions_disabled_breaker(
    caplog: pytest.LogCaptureFixture,
) -> None:
    client = make_client(httpx.MockTransport(lambda request: httpx.Response(200, json={})))
    client._breaker_failure_threshold = 0  # pyright: ignore[reportPrivateUsage]
    client._breaker_reset_sec = 0  # pyright: ignore[reportPrivateUsage]

    with caplog.at_level(logging.WARNING):
        client._note_transport_failure("gate timeout")  # pyright: ignore[reportPrivateUsage]

    assert "breaker disabled" in caplog.text
    assert "1/0" not in caplog.text
