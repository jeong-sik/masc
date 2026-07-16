"""Shared connector components for MASC Channel Gate sidecars."""

from .diagnostics import (
    NETWORK_TIMEOUT_SEC,
    AutoFix,
    Check,
    CheckFn,
    Diagnostics,
    FixOutcome,
    Severity,
    check_dependencies_installed,
    exit_code_for,
    render_fix_outcomes,
    render_json,
    render_pretty,
)
from .gate_client_base import GateClientBase
from .gate_response import GateResponse
from .structured_content import (
    SUPPORTED_BLOCK_TYPES,
    response_text,
    structured_plain_text,
)

__all__ = [
    "AutoFix",
    "Check",
    "CheckFn",
    "Diagnostics",
    "FixOutcome",
    "GateClientBase",
    "GateResponse",
    "NETWORK_TIMEOUT_SEC",
    "Severity",
    "SUPPORTED_BLOCK_TYPES",
    "check_dependencies_installed",
    "exit_code_for",
    "render_fix_outcomes",
    "render_json",
    "render_pretty",
    "response_text",
    "structured_plain_text",
]
