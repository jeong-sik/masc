"""Emit BotConfig JSON schema to stdout for the dashboard config form.

Invoked by `./run.sh schema` or `python -m src.schema_dump`. The backend
captures the stdout once per server lifetime and serves it from
`/api/v1/sidecar/schema?name=telegram` so the dashboard can render a
config form without hand-coding field metadata.

`BotConfig.model_json_schema()` is a classmethod, so it does not require
the bot's required env vars to be set.
"""

from __future__ import annotations

import json
import sys

from .config import BotConfig


def main() -> int:
    schema = BotConfig.model_json_schema()
    json.dump(schema, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
