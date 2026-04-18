"""Shared connector components for MASC Channel Gate sidecars."""

from .doctor import (
    AutoFix,
    Check,
    CheckFn,
    Doctor,
    Severity,
    exit_code_for,
    render_json,
    render_pretty,
)
from .gate_client_base import BreakerSnapshot, GateClientBase
from .gate_response import GateResponse

__all__ = [
    "AutoFix",
    "BreakerSnapshot",
    "Check",
    "CheckFn",
    "Doctor",
    "GateClientBase",
    "GateResponse",
    "Severity",
    "exit_code_for",
    "render_json",
    "render_pretty",
]
