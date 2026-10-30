"""Tests for CLI connector bot logic."""

from __future__ import annotations

from src.bot import _response_text, CLIGateClient, GateResponse


class TestResponseText:
    def test_prefers_structured_plain_text(self) -> None:
        response = GateResponse(
            ok=True,
            keeper_name="sangsu",
            reply="fallback",
            model_used="",
            duration_ms=0,
            tokens_used=0,
            error="",
            structured={
                "blocks": [
                    {"t": "p", "html": "hello &lt;cli&gt;"},
                    {"t": "image", "src": "https://example.com/a.png"},
                ]
            },
        )

        assert _response_text(response) == "hello <cli>\n\nImage: https://example.com/a.png"


class TestCLIGateClient:
    def test_constructs_with_gate_url(self) -> None:
        client = CLIGateClient("http://example.com:9000")
        assert client._message_url == "http://example.com:9000/api/v1/gate/message"
        assert client._agent_name == "cli-connector"

    def test_uses_origin_header(self) -> None:
        client = CLIGateClient("http://localhost:8935")
        assert client._headers["Origin"] == "http://localhost:8935"
        assert "Authorization" not in client._headers
