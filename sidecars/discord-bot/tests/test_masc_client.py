"""Tests for the Discord Channel Gate client."""

from __future__ import annotations

from collections.abc import Iterator

import httpx
import pytest

from src import config as config_module
from src.masc_client import MascGateClient


@pytest.fixture(autouse=True)
def reset_config(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    monkeypatch.setenv("DISCORD_BOT_TOKEN", "test-token")
    monkeypatch.setenv("MASC_API_TOKEN", "test-api-token")
    monkeypatch.setenv("MASC_MCP_URL", "http://localhost:8935")
    config_module.reset_config_cache()
    yield
    config_module.reset_config_cache()


def make_client(handler: httpx.MockTransport) -> MascGateClient:
    client = MascGateClient()
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
