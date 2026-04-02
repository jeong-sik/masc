"""Tests for Discord message formatting."""

from src.formatters import chunk_text
from src.masc_client import GateResponse


def test_chunk_text_short() -> None:
    result = chunk_text("hello", limit=2000)
    assert result == ["hello"]


def test_chunk_text_splits_on_newline() -> None:
    text = "line1\nline2\nline3"
    result = chunk_text(text, limit=12)
    assert len(result) == 2
    assert result[0] == "line1\nline2\n"
    assert result[1] == "line3"


def test_chunk_text_splits_on_space() -> None:
    text = "word1 word2 word3 word4"
    result = chunk_text(text, limit=12)
    assert len(result) >= 2
    for chunk in result:
        assert len(chunk) <= 12


def test_gate_response_from_json() -> None:
    data = {
        "ok": True,
        "keeper_name": "luna",
        "reply": "hello world",
        "turn_stats": {
            "model_used": "claude-sonnet",
            "duration_ms": 1234,
            "tokens_used": 567,
        },
    }
    resp = GateResponse.from_json(data)
    assert resp.ok is True
    assert resp.keeper_name == "luna"
    assert resp.reply == "hello world"
    assert resp.model_used == "claude-sonnet"
    assert resp.duration_ms == 1234
    assert resp.tokens_used == 567


def test_gate_response_from_json_missing_stats() -> None:
    data = {"ok": True, "keeper_name": "luna", "reply": "hi"}
    resp = GateResponse.from_json(data)
    assert resp.ok is True
    assert resp.model_used == ""
    assert resp.duration_ms == 0


def test_gate_response_from_error() -> None:
    resp = GateResponse.from_error("timeout")
    assert resp.ok is False
    assert resp.error == "timeout"
    assert resp.reply == ""
