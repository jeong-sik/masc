"""Tests for CLI connector bot logic."""

from __future__ import annotations

import re

from src.bot import _strip_state, CLIGateClient


class TestStripState:
    def test_removes_state_block(self) -> None:
        assert _strip_state("Hi [STATE]data[/STATE] there") == "Hi  there"

    def test_removes_unclosed_block(self) -> None:
        assert _strip_state("Hi [STATE]data without end") == "Hi"

    def test_preserves_plain_text(self) -> None:
        assert _strip_state("no state here") == "no state here"

    def test_handles_empty(self) -> None:
        assert _strip_state("") == ""


class TestCLIGateClient:
    def test_constructs_with_gate_url(self) -> None:
        client = CLIGateClient("http://example.com:9000")
        assert client._message_url == "http://example.com:9000/api/v1/gate/message"
        assert client._agent_name == "cli-connector"

    def test_uses_origin_header(self) -> None:
        client = CLIGateClient("http://localhost:8935")
        assert client._headers["Origin"] == "http://localhost:8935"
        assert "Authorization" not in client._headers
