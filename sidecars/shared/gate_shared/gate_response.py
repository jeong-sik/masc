"""GateResponse -- common response type for all Channel Gate connectors.

This is the SSOT for the gate message response structure.
All connector sidecars import from here instead of duplicating.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, cast


@dataclass(frozen=True, slots=True)
class GateResponse:
    """Parsed response from POST /api/v1/gate/message."""

    ok: bool
    keeper_name: str
    reply: str
    model_used: str
    duration_ms: int
    tokens_used: int
    error: str
    structured: dict[str, Any] | None

    @staticmethod
    def from_json(data: dict[str, Any]) -> GateResponse:
        raw_stats = data.get("turn_stats")
        stats = cast(dict[str, Any], raw_stats) if isinstance(raw_stats, dict) else {}
        raw_structured = data.get("structured")
        structured = (
            cast(dict[str, Any], raw_structured)
            if isinstance(raw_structured, dict)
            else None
        )
        # Read priority for the routing identifier: prefer destination_id
        # (introduced in B2 Phase 2) and fall back to the legacy keeper_name
        # key so sidecars handle both old and new gate emit shapes. Pairs
        # with gate_protocol.outbound_to_json which currently emits both.
        destination = str(data.get("destination_id", ""))
        keeper_name = destination if destination else str(data.get("keeper_name", ""))
        return GateResponse(
            ok=bool(data.get("ok", False)),
            keeper_name=keeper_name,
            reply=str(data.get("reply", "")),
            model_used=str(stats.get("model_used", "")),
            duration_ms=int(stats.get("duration_ms", 0)),
            tokens_used=int(stats.get("tokens_used", 0)),
            error=str(data.get("error", "")),
            structured=structured,
        )

    @staticmethod
    def from_error(msg: str) -> GateResponse:
        return GateResponse(
            ok=False,
            keeper_name="",
            reply="",
            model_used="",
            duration_ms=0,
            tokens_used=0,
            error=msg,
            structured=None,
        )
