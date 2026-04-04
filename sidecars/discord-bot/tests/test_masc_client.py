"""Tests for the Discord Channel Gate client."""

from __future__ import annotations

from collections.abc import Iterator

import httpx
import logging
import pytest

from src import config as config_module
from src.config import BotConfig
from src.gate_client import GateClient
from src.masc_client import GateResponse, MascGateClient


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
async def test_send_message_uses_retry_count_after_first_attempt() -> None:
    attempts = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal attempts
        attempts += 1
        return httpx.Response(503, json={"ok": False, "error": "down"})

    client = make_client(httpx.MockTransport(handler))
    client._max_retries = 2  # pyright: ignore[reportPrivateUsage]

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
    assert attempts == 3

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


def test_legacy_env_aliases_still_work(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GATE_API_TOKEN", raising=False)
    monkeypatch.delenv("GATE_BASE_URL", raising=False)
    monkeypatch.setenv("DISCORD_BOT_TOKEN", "test-token")
    monkeypatch.setenv("MASC_API_TOKEN", "legacy-api-token")
    monkeypatch.setenv("MASC_MCP_URL", "http://legacy.example")
    config_module.reset_config_cache()

    cfg = BotConfig()  # type: ignore[call-arg]

    assert cfg.gate_api_token == "legacy-api-token"
    assert cfg.gate_base_url == "http://legacy.example"
    assert cfg.masc_api_token == "legacy-api-token"
    assert cfg.masc_mcp_url == "http://legacy.example"


def test_legacy_constructor_aliases_still_work() -> None:
    cfg = BotConfig(
        discord_bot_token="test-token",
        masc_api_token="legacy-api-token",
        masc_mcp_url="http://legacy.example",
    )

    assert cfg.gate_api_token == "legacy-api-token"
    assert cfg.gate_base_url == "http://legacy.example"
    assert cfg.masc_api_token == "legacy-api-token"
    assert cfg.masc_mcp_url == "http://legacy.example"


def test_legacy_import_shim_reexports_gate_client_surface() -> None:
    assert MascGateClient is GateClient
    response = GateResponse.from_error("timeout")
    assert response.ok is False
    assert response.error == "timeout"


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
