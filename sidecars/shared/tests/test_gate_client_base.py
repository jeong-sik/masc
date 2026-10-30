"""Tests for GateClientBase HTTP transport."""

from __future__ import annotations

import asyncio
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import cast

import httpx
import pytest

from gate_shared import (
    GateClientBase,
    GateStreamIncomplete,
    GateStreamProtocolError,
    GateStreamRejected,
    GateStreamRunError,
    GateStreamTransportAmbiguous,
    GateStreamUnavailable,
)
from gate_shared import gate_client_base as gate_client_module


@asynccontextmanager
async def _idle_sse_server() -> AsyncIterator[
    tuple[str, asyncio.Queue[None], asyncio.Event]
]:
    accepted: asyncio.Queue[None] = asyncio.Queue()
    release = asyncio.Event()

    async def handle(
        reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        try:
            await reader.readuntil(b"\r\n\r\n")
            writer.write(
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: text/event-stream\r\n"
                b"Connection: close\r\n\r\n"
            )
            await writer.drain()
            accepted.put_nowait(None)
            await release.wait()
            writer.write(
                b'data: {"type":"TEXT_MESSAGE_CONTENT","delta":"ready"}\n\n'
                b'data: {"type":"RUN_FINISHED"}\n\n'
            )
            await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()

    server = await asyncio.start_server(handle, "127.0.0.1", 0)
    socket = server.sockets[0]
    host, port = socket.getsockname()[:2]
    try:
        yield f"http://{host}:{port}/stream", accepted, release
    finally:
        release.set()
        server.close()
        await server.wait_closed()


def _make_client(**kwargs: object) -> GateClientBase:
    defaults = {
        "agent_name": "test-bot",
        "gate_base_url": "http://localhost:8935",
        "gate_api_token": "",
        "gate_origin": "http://localhost:8935",
        "timeout_sec": 5.0,
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
    async def test_transport_failure_does_not_refuse_next_request(self) -> None:
        responses = iter(
            [
                httpx.Response(503),
                httpx.Response(200, json={"ok": True, "reply": "ready"}),
            ]
        )
        request_count = 0

        def respond(request: httpx.Request) -> httpx.Response:
            nonlocal request_count
            request_count += 1
            return next(responses)

        c = _make_client()
        c._client = httpx.AsyncClient(
            transport=httpx.MockTransport(respond),
            headers=c._headers,
        )
        try:
            first = await c.send_message(
                keeper_name="keeper-a",
                content="first",
                context={"channel": "test"},
                idempotency_key="key-1",
            )
            second = await c.send_message(
                keeper_name="keeper-b",
                content="second",
                context={"channel": "test"},
                idempotency_key="key-2",
            )
        finally:
            await c.aclose()

        assert not first.ok
        assert second.ok
        assert second.reply == "ready"
        assert request_count == 2


class TestKeeperStream:
    @pytest.mark.asyncio
    async def test_missing_dependency_is_explicit_before_dispatch(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        c = _make_client()
        monkeypatch.setattr(gate_client_module, "_httpx_sse", None)

        with pytest.raises(GateStreamUnavailable):
            await anext(
                c.stream_keeper(
                    keeper_name="keeper-a",
                    message="continue",
                    context={"channel": "test"},
                )
            )

    @pytest.mark.asyncio
    async def test_unexpected_internal_failure_is_not_transport_ambiguity(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        assert gate_client_module._httpx_sse is not None

        def fail_before_transport(*_args: object, **_kwargs: object) -> object:
            raise ValueError("internal stream invariant failed")

        monkeypatch.setattr(
            gate_client_module._httpx_sse,
            "aconnect_sse",
            fail_before_transport,
        )
        c = _make_client()

        with pytest.raises(ValueError, match="internal stream invariant failed"):
            await anext(
                c.stream_keeper(
                    keeper_name="keeper-a",
                    message="continue",
                    context={"channel": "test"},
                )
            )

    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        ("body", "error_type", "expected_message"),
        [
            (
                b'data: {"type":"RUN_ERROR","message":"boom"}\n\n',
                GateStreamRunError,
                "boom",
            ),
            (
                b'data: {"type":"RUN_ERROR","value":{"message":"legacy"}}\n\n',
                GateStreamProtocolError,
                ("keeper stream RUN_ERROR is missing a non-empty string message"),
            ),
            (b"", GateStreamIncomplete, "keeper stream ended without a terminal event"),
        ],
    )
    async def test_accepted_stream_failure_is_explicit(
        self, body: bytes, error_type: type[Exception], expected_message: str
    ) -> None:
        def respond(request: httpx.Request) -> httpx.Response:
            return httpx.Response(
                200,
                headers={"Content-Type": "text/event-stream"},
                content=body,
            )

        c = _make_client()
        c._client = httpx.AsyncClient(
            transport=httpx.MockTransport(respond),
            headers=c._headers,
        )
        try:
            with pytest.raises(error_type) as raised:
                await anext(
                    c.stream_keeper(
                        keeper_name="keeper-a",
                        message="continue",
                        context={"channel": "test"},
                    )
                )
        finally:
            await c.aclose()

        assert str(raised.value) == expected_message

    @pytest.mark.asyncio
    async def test_http_rejection_is_explicit(self) -> None:
        def respond(request: httpx.Request) -> httpx.Response:
            return httpx.Response(503)

        c = _make_client()
        c._client = httpx.AsyncClient(
            transport=httpx.MockTransport(respond),
            headers=c._headers,
        )
        try:
            with pytest.raises(GateStreamRejected) as raised:
                await anext(
                    c.stream_keeper(
                        keeper_name="keeper-a",
                        message="continue",
                        context={"channel": "test"},
                    )
                )
        finally:
            await c.aclose()

        assert raised.value.status_code == 503

    @pytest.mark.asyncio
    async def test_accepted_idle_stream_has_no_read_deadline(self) -> None:
        c = _make_client(timeout_sec=0.1)
        observed_timeouts: list[dict[str, float | None]] = []

        async def observe_timeout(request: httpx.Request) -> None:
            observed_timeouts.append(
                cast(dict[str, float | None], request.extensions["timeout"])
            )

        async with _idle_sse_server() as (url, accepted, release):
            c._stream_url = url
            c._client = httpx.AsyncClient(
                headers=c._headers,
                event_hooks={"request": [observe_timeout]},
            )

            async def release_after_idle() -> None:
                await accepted.get()
                await asyncio.sleep(0.2)
                release.set()

            release_task = asyncio.create_task(release_after_idle())
            try:
                deltas = [
                    delta
                    async for delta in c.stream_keeper(
                        keeper_name="keeper-a",
                        message="continue",
                        context={"channel": "test"},
                    )
                ]
                await release_task
            finally:
                await c.aclose()

        assert deltas == ["ready"]
        assert len(observed_timeouts) == 1
        assert observed_timeouts[0] == {
            "connect": 0.1,
            "read": None,
            "write": 0.1,
            "pool": 0.1,
        }

    @pytest.mark.asyncio
    async def test_transport_timeout_is_raised_to_caller(self) -> None:
        c = _make_client(timeout_sec=0.1)
        async with _idle_sse_server() as (url, accepted, release):
            c._stream_url = url
            c._client = httpx.AsyncClient(
                headers=c._headers,
                limits=httpx.Limits(max_connections=1),
            )
            first_stream = c.stream_keeper(
                keeper_name="keeper-a",
                message="first",
                context={"channel": "test"},
            )

            async def consume_first_stream() -> list[str]:
                return [delta async for delta in first_stream]

            first_result = asyncio.create_task(consume_first_stream())
            await accepted.get()

            second_stream = c.stream_keeper(
                keeper_name="keeper-b",
                message="second",
                context={"channel": "test"},
            )
            try:
                with pytest.raises(GateStreamTransportAmbiguous) as raised:
                    await anext(second_stream)
                assert isinstance(raised.value.__cause__, httpx.PoolTimeout)
                release.set()
                assert await first_result == ["ready"]
            finally:
                release.set()
                await c.aclose()
