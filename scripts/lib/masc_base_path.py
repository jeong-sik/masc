"""The MASC base path a script works on: its flag, or ``MASC_BASE_PATH``.

There is no home-directory or cwd default. A script that guesses a base path
reads or edits a workspace nobody named and reports confident numbers about
it, so a caller with neither a flag nor ``MASC_BASE_PATH`` must stop.

The value is taken as written and made absolute against the caller's cwd, so
a child process started elsewhere reads the same directory. Nothing else of
the server's own normalisation is repeated here: a second reading of what
``~`` or a trailing ``.masc`` means could disagree with the server the script
is measuring. A shell expands a tilde before argv and before ``export``, so
one that reaches this module was quoted; it is reported, not interpreted.
"""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from pathlib import Path

ENV_KEY = "MASC_BASE_PATH"


@dataclass(frozen=True, slots=True)
class Unexpanded:
    """A value that starts with a tilde the shell did not expand."""

    raw: str

    def message(self) -> str:
        return f"{self.raw!r} starts with a tilde the shell did not expand; pass the directory itself"


def read_path_flag(raw: str) -> Path | Unexpanded | None:
    """One directory or file flag value: blank is ``None``, a leading ``~``
    is :class:`Unexpanded`, and anything else is made absolute against cwd."""
    raw = raw.strip()
    if not raw:
        return None
    if raw.startswith("~"):
        return Unexpanded(raw)
    return Path(os.path.abspath(raw))


def resolve(flag_value: str | None) -> Path | Unexpanded | None:
    """The base path named by the flag; without a flag, by ``MASC_BASE_PATH``.

    ``None`` when nothing is named. A blank value names nothing, and a flag
    that was passed is never replaced by the environment, so
    ``--base-path ""`` is ``None`` rather than a silent switch to another
    workspace.
    """
    raw = os.environ.get(ENV_KEY, "") if flag_value is None else flag_value
    return read_path_flag(raw)


def required(flag: str) -> str:
    """The message for a caller whose :func:`resolve` named nothing."""
    return f"{flag} or {ENV_KEY} is required"


def require(parser: argparse.ArgumentParser, flag_value: str | None, flag: str) -> Path:
    """The base path, or the parser's usage error (exit 2) when there is none."""
    base = resolve(flag_value)
    if base is None:
        parser.error(required(flag))
    if isinstance(base, Unexpanded):
        parser.error(base.message())
    return base


def require_subpath(
    parser: argparse.ArgumentParser,
    flag_value: str | None,
    flag: str,
    *relative_under_base: str,
) -> Path:
    """The path named by ``flag_value``; when ``flag_value`` is ``None``,
    ``relative_under_base`` under the ``MASC_BASE_PATH`` directory.

    A blank ``flag_value`` names nothing (and does not fall back to
    ``MASC_BASE_PATH``); an unexpanded leading tilde is refused with the same
    message as :func:`require`.
    """
    if flag_value is None:
        return require(parser, None, flag).joinpath(*relative_under_base)
    parsed = read_path_flag(flag_value)
    if parsed is None:
        parser.error(required(flag))
    if isinstance(parsed, Unexpanded):
        parser.error(parsed.message())
    return parsed


def require_or_exit(flag_value: str | None, flag: str) -> Path:
    """:func:`require` for a caller with no parser at hand: the same message
    on stderr and exit 2."""
    base = resolve(flag_value)
    if base is None:
        print(f"error: {required(flag)}", file=sys.stderr)
        sys.exit(2)
    if isinstance(base, Unexpanded):
        print(f"error: {base.message()}", file=sys.stderr)
        sys.exit(2)
    return base
