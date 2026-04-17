"""Dashboard contract pin for imessage-bot. See discord-bot test for rationale."""

from __future__ import annotations

import io
import json
from contextlib import redirect_stdout

from src.schema_dump import main


def _capture_schema() -> dict[str, object]:
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = main()
    assert rc == 0
    parsed = json.loads(buf.getvalue())
    assert isinstance(parsed, dict)
    return parsed


def test_schema_dump_has_properties() -> None:
    schema = _capture_schema()
    assert "properties" in schema
    properties = schema["properties"]
    assert isinstance(properties, dict)
    assert len(properties) >= 3
