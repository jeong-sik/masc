"""The MASC base path a script works on: its flag, or ``MASC_BASE_PATH``.

There is no home-directory or cwd default. A script that guesses a base path
reads or edits a workspace nobody named and reports confident numbers about
it, so a caller with neither a flag nor ``MASC_BASE_PATH`` gets ``None`` and
must stop.
"""

from __future__ import annotations

import os
from pathlib import Path

ENV_KEY = "MASC_BASE_PATH"


def resolve(flag_value: str | None) -> Path | None:
    """The base path named by the flag; without a flag, by ``MASC_BASE_PATH``.

    A blank value names nothing. A flag that was passed is never replaced by
    the environment, so ``--base-path ""`` is ``None`` rather than a silent
    switch to another workspace.
    """
    raw = os.environ.get(ENV_KEY, "") if flag_value is None else flag_value
    raw = raw.strip()
    return Path(raw).expanduser() if raw else None


def required(flag: str) -> str:
    """The message for a caller that got ``None`` from :func:`resolve`."""
    return f"{flag} or {ENV_KEY} is required"
