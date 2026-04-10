"""Tests for GateResponse parsing and construction."""

from __future__ import annotations

import pytest

from gate_shared import GateResponse


class TestFromJson:
    def test_parses_full_response(self) -> None:
        data = {
            "ok": True,
            "keeper_name": "sangsu",
            "reply": "hello world",
            "turn_stats": {
                "model_used": "qwen3.5:35b",
                "duration_ms": 4500,
                "tokens_used": 120,
            },
            "structured": {"blocks": [{"type": "card", "description": "test"}]},
        }
        resp = GateResponse.from_json(data)
        assert resp.ok is True
        assert resp.keeper_name == "sangsu"
        assert resp.reply == "hello world"
        assert resp.model_used == "qwen3.5:35b"
        assert resp.duration_ms == 4500
        assert resp.tokens_used == 120
        assert resp.structured is not None
        assert resp.error == ""

    def test_handles_missing_turn_stats(self) -> None:
        data = {"ok": True, "keeper_name": "test", "reply": "hi"}
        resp = GateResponse.from_json(data)
        assert resp.ok is True
        assert resp.model_used == ""
        assert resp.duration_ms == 0
        assert resp.tokens_used == 0

    def test_handles_non_dict_turn_stats(self) -> None:
        data = {"ok": True, "reply": "hi", "turn_stats": "invalid"}
        resp = GateResponse.from_json(data)
        assert resp.model_used == ""

    def test_handles_non_dict_structured(self) -> None:
        data = {"ok": True, "reply": "hi", "structured": "not a dict"}
        resp = GateResponse.from_json(data)
        assert resp.structured is None

    def test_defaults_for_empty_data(self) -> None:
        resp = GateResponse.from_json({})
        assert resp.ok is False
        assert resp.keeper_name == ""
        assert resp.reply == ""
        assert resp.error == ""


class TestFromError:
    def test_creates_error_response(self) -> None:
        resp = GateResponse.from_error("gate timeout after 120s")
        assert resp.ok is False
        assert resp.error == "gate timeout after 120s"
        assert resp.reply == ""
        assert resp.keeper_name == ""
        assert resp.structured is None

    def test_frozen_dataclass(self) -> None:
        resp = GateResponse.from_error("test")
        with pytest.raises(AttributeError):
            resp.ok = True  # type: ignore[misc]
