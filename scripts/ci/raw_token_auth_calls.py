#!/usr/bin/env python3
# pyright: strict
"""Hold the reads of a raw bearer to the places that may make them.

RFC a-request-reads-its-bearer-once-at-the-door, D6. A request's bearer is
read once, at the door, and the layers below take the door's answer. The
functions in WATCHED read a raw token again. A call to one of them outside
lib/auth/ is counted per file, and the count must equal the one in ALLOWED.

- A count that grew is a new read. Pass the door's answer to it instead, or
  write in RFC D6 why it must read, and raise the count here.
- A count that shrank must shrink here too, so a removed read stays removed.
- A file not in ALLOWED may not call these functions at all.

Comments, string literals and character literals are blanked before
matching, so a function named in a comment is not a call. The match needs
the module's name, so a file may not reach these modules without it: an
`open`, `include`, local open (`Auth.( ... )`) or alias under another name
fails the check. `module Auth = Auth` keeps the name and is allowed.

Run: python3 -I scripts/ci/raw_token_auth_calls.py [--root DIR]
Exits 0 when every count matches and no file hides the name, 1 otherwise,
naming each place.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from dataclasses import dataclass

WATCHED = (
    "find_credential_by_token",
    "resolve_agent_from_token",
    "check_permission",
    "authorize_tool",
)
QUALIFIERS = ("Auth", "Auth_credential_token")
_QUALIFIER = "(?:" + "|".join(QUALIFIERS) + ")"
CALL = re.compile(r"\b" + _QUALIFIER + r"\.(" + "|".join(WATCHED) + r")\b")
# Ways to reach a qualifier's functions without writing its name. A module
# path may precede it (`open Masc_auth.Auth`).
_PATH = r"(?:[A-Z]\w*\.)*"
HIDING = re.compile(
    r"\b(?:open!?|include)\s+" + _PATH + r"(?P<opened>" + _QUALIFIER + r")\b"
    r"|\bmodule\s+(?P<alias>[A-Z]\w*)\s*=\s*" + _PATH + r"(?P<aliased>" + _QUALIFIER + r")\b"
    r"|\b(?P<local>" + _QUALIFIER + r")\.[(\[{]"
)
# lib/auth/ defines these functions and is the store they read.
EXEMPT_PREFIX = "lib/auth/"

# (file, function) -> number of calls. Each entry says why the file reads a
# raw bearer.
ALLOWED: dict[tuple[str, str], int] = {
    # The HTTP doors: /mcp, seat, observer, operator, dashboard and the
    # credential administration routes.
    ("lib/server/server_auth.ml", "check_permission"): 1,
    ("lib/server/server_auth.ml", "authorize_tool"): 1,
    ("lib/server/server_auth.ml", "find_credential_by_token"): 3,
    # The gRPC door (authorize_grpc_request) admits a call with no bearer
    # when the workspace does not require one.
    ("lib/server/masc_grpc_server.ml", "check_permission"): 1,
    # The dashboard WebSocket door (dashboard/hello).
    ("lib/server/server_mcp_transport_ws.ml", "check_permission"): 1,
    # The SSE registration door.
    ("lib/sse.ml", "find_credential_by_token"): 1,
    # The dashboard dev token store classifies a stored token it owns.
    ("lib/server/server_routes_http_dashboard_dev_token.ml", "find_credential_by_token"): 1,
    # D3: dispatch asks the store about the internal Keeper bearer
    # (find_required_credential). 3b: Add-on exports read an Unread token.
    ("lib/mcp_server_eio_protocol.ml", "find_credential_by_token"): 2,
    # D5: a token no door read (auth off, no door, the internal Keeper
    # token) is read as before.
    ("lib/mcp_server_eio_caller_identity.ml", "resolve_agent_from_token"): 1,
    ("lib/mcp_server_eio_execute.ml", "find_credential_by_token"): 1,
    # D5: a call under a name that is not the credential's owner, and an
    # unread token, pair the name with the token.
    ("lib/mcp_server_eio_execute.ml", "check_permission"): 1,
    ("lib/mcp_server_eio_execute.ml", "authorize_tool"): 1,
}

_CHAR_LITERAL = re.compile(
    r"'(?:[^\\'\n]|\\(?:[\\'\"ntbr ]|[0-9]{3}|x[0-9a-fA-F]{2}|o[0-3][0-7]{2}))'"
)
_QUOTED_STRING_OPEN = re.compile(r"\{([a-z_]*)\|")


def _blank(text: str) -> str:
    """Spaces in place of `text`, keeping its newlines."""
    return "".join("\n" if ch == "\n" else " " for ch in text)


def _string_end(text: str, start: int) -> int:
    """Index just past the "..." literal that opens at `start`."""
    i = start + 1
    while i < len(text):
        if text[i] == "\\":
            i += 2
        elif text[i] == '"':
            return i + 1
        else:
            i += 1
    return len(text)


def code_only(text: str) -> str:
    """`text` with OCaml comments and literals blanked, lines kept.

    Comments nest, and a string literal inside a comment is lexed as a
    string, so a `*)` in it does not close the comment.
    """
    out: list[str] = []
    i = 0
    depth = 0
    while i < len(text):
        if text.startswith("(*", i):
            depth += 1
            out.append("  ")
            i += 2
        elif depth > 0 and text.startswith("*)", i):
            depth -= 1
            out.append("  ")
            i += 2
        elif text[i] == '"':
            end = _string_end(text, i)
            out.append(_blank(text[i:end]))
            i = end
        elif text[i] == "{" and (opened := _QUOTED_STRING_OPEN.match(text, i)):
            closing = "|" + opened.group(1) + "}"
            close_at = text.find(closing, opened.end())
            end = len(text) if close_at < 0 else close_at + len(closing)
            out.append(_blank(text[i:end]))
            i = end
        elif text[i] == "'" and (char := _CHAR_LITERAL.match(text, i)):
            out.append(_blank(char.group(0)))
            i = char.end()
        elif depth > 0:
            out.append(_blank(text[i]))
            i += 1
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


@dataclass(frozen=True, slots=True)
class Call:
    path: str
    line: int
    function: str


@dataclass(frozen=True, slots=True)
class Hidden:
    """A place that reaches a qualifier without writing its name."""

    path: str
    line: int
    text: str


@dataclass(frozen=True, slots=True)
class Scan:
    calls: tuple[Call, ...]
    hidden: tuple[Hidden, ...]


def _line(code: str, offset: int) -> int:
    return code.count("\n", 0, offset) + 1


def scan_text(path: str, text: str) -> Scan:
    code = code_only(text)
    calls = tuple(
        Call(path, _line(code, match.start()), match.group(1))
        for match in CALL.finditer(code)
    )
    hidden = tuple(
        Hidden(path, _line(code, match.start()), match.group(0))
        for match in HIDING.finditer(code)
        if match.group("alias") is None or match.group("alias") != match.group("aliased")
    )
    return Scan(calls, hidden)


def scan(root: pathlib.Path) -> Scan:
    calls: list[Call] = []
    hidden: list[Hidden] = []
    for file in sorted((root / "lib").rglob("*.ml")):
        path = file.relative_to(root).as_posix()
        if path.startswith(EXEMPT_PREFIX):
            continue
        found = scan_text(path, file.read_text(encoding="utf-8"))
        calls.extend(found.calls)
        hidden.extend(found.hidden)
    return Scan(tuple(calls), tuple(hidden))


@dataclass(frozen=True, slots=True)
class Mismatch:
    path: str
    function: str
    allowed: int
    found: tuple[Call, ...]


def mismatches(
    found: tuple[Call, ...], allowed: dict[tuple[str, str], int]
) -> list[Mismatch]:
    by_key: dict[tuple[str, str], list[Call]] = {}
    for call in found:
        by_key.setdefault((call.path, call.function), []).append(call)
    keys = sorted(set(by_key) | set(allowed))
    return [
        Mismatch(path, function, allowed.get((path, function), 0), tuple(calls))
        for (path, function) in keys
        if len(calls := by_key.get((path, function), [])) != allowed.get((path, function), 0)
    ]


def report(mismatch: Mismatch) -> str:
    lines = [
        f"{mismatch.path}: {mismatch.function} is called {len(mismatch.found)} "
        f"time(s); ALLOWED says {mismatch.allowed}."
    ]
    lines.extend(f"  {call.path}:{call.line}" for call in mismatch.found)
    if len(mismatch.found) > mismatch.allowed:
        lines.append(
            "  A new call reads the raw bearer again. Pass the door's answer "
            "(Auth.request_principal, Mcp_server_eio_caller_identity.bearer) "
            "instead, or give the reason in RFC D6 and raise the count in "
            "scripts/ci/raw_token_auth_calls.py."
        )
    else:
        lines.append(
            "  A read was removed. Lower the count in "
            "scripts/ci/raw_token_auth_calls.py so it stays removed."
        )
    return "\n".join(lines)


def report_hidden(hidden: Hidden) -> str:
    return (
        f"{hidden.path}:{hidden.line}: `{hidden.text}` reaches the module "
        "without its name, so this check cannot see the calls. Write "
        "Auth.<function> or Auth_credential_token.<function> at each call."
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else None)
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    args = parser.parse_args(argv)
    root: pathlib.Path = args.root
    found = scan(root)
    wrong = mismatches(found.calls, ALLOWED)
    if not wrong and not found.hidden:
        print("raw token auth calls: every count matches RFC D6's allow-list")
        return 0
    for hidden in found.hidden:
        print(report_hidden(hidden), file=sys.stderr)
    for mismatch in wrong:
        print(report(mismatch), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
