"""Compatibility wrapper for the older ``masc_client`` import path.

Deprecated: import from gate_client directly.
"""

import warnings

warnings.warn(
    "masc_client is deprecated; import from gate_client directly",
    DeprecationWarning,
    stacklevel=2,
)

from .gate_client import BreakerSnapshot, GateClient, GateResponse

MascGateClient = GateClient

__all__ = ["BreakerSnapshot", "GateClient", "GateResponse", "MascGateClient"]
