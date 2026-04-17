"""Pin the dashboard contract for `python -m src.schema_dump`.

The dashboard's connector config form shells out to this module via the
backend `/api/v1/sidecar/schema?name=discord` route. The shape it relies
on is `{"properties": {<field>: {...}}, ...}` — a top-level object with
a non-empty `properties` map keyed by alias names like `DISCORD_BOT_TOKEN`.

If a refactor changes BotConfig in a way that breaks this shape (e.g.
nested $defs without inlined properties) the dashboard form silently
shows no fields. Pinning here makes that a CI failure.

We exercise schema_dump.main() in-process rather than spawning a
subprocess because the test runner's `sys.executable` doesn't always
match the venv that has pydantic_settings installed (uv shim quirk).
"""

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
    assert "properties" in schema, "schema must expose a top-level 'properties' map"
    properties = schema["properties"]
    assert isinstance(properties, dict)
    assert len(properties) >= 5, (
        f"discord BotConfig should expose 5+ fields; got {len(properties)}"
    )


def test_schema_dump_includes_required_token() -> None:
    schema = _capture_schema()
    properties = schema.get("properties", {})
    assert isinstance(properties, dict)
    assert "DISCORD_BOT_TOKEN" in properties, (
        "DISCORD_BOT_TOKEN must surface as a property so the form can request it"
    )


def test_schema_dump_marks_token_required() -> None:
    """Required fields must appear in the top-level `required` array so the
    dashboard form can mark them and refuse submission with empty values."""
    schema = _capture_schema()
    required = schema.get("required", [])
    assert isinstance(required, list)
    assert "DISCORD_BOT_TOKEN" in required
