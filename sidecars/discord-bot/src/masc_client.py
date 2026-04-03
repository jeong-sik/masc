"""Compatibility wrapper for the older ``masc_client`` import path."""

from .gate_client import BreakerSnapshot, GateClient, GateResponse

MascGateClient = GateClient

__all__ = ["BreakerSnapshot", "GateClient", "GateResponse", "MascGateClient"]
