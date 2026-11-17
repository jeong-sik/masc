#!/usr/bin/env python3
# pyright: strict
"""Pin references to four legacy token APIs to their per-file allow-list.

RFC a-request-reads-its-bearer-once-at-the-door, stage 4a (D6). Only
find_credential_by_token, resolve_agent_from_token, check_permission and
authorize_tool on Auth or Auth_credential_token are counted in lib/**/*.ml
outside lib/auth/. These are source references before PPX expansion, not
dynamic calls, request I/O counts or a dataflow analysis. This step
holds the four migrated legacy APIs steady; it does not prove the whole
ingress, credential-management or internal-token boundary.

find_token_credential, find_static_token_credential,
find_static_credential_by_token, verify_token, verify_internal_keeper_token,
internal_keeper_bearer, identify_bearer, resolve_role and resolve_role_* are
outside this guard, as are raw token comparisons. Their separate contracts
are not assessed by this four-API migration check.

- A count that grew is a new guarded reference. Pass the door's answer instead, or
  write in RFC D6 why it must read, and raise the count here.
- A count that shrank must shrink here too, so a removed read stays removed.
- A scanned file not in ALLOWED may not reference these four functions.

Comments, string literals and character literals are blanked before tokens
are read. Whitespace and comments around a qualified name's dots do not
hide it. Bare auth-module references are rejected conservatively: opens,
wrapped or typed aliases, first-class modules and functor arguments can all
hide the four guarded names. Only simple aliases that keep the name, such
as `module Auth = Auth` or `module Auth = Masc_auth.Auth`, are exempt.

Run: python3 -I scripts/ci/raw_token_auth_calls.py [--root DIR]
Exits 0 when the four APIs' counts match and no bare module reference hides
their names, 1 otherwise, naming each place. Other token helpers remain out
of scope even when this check succeeds.
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
_IDENTIFIER = re.compile(r"[^\W\d][\w']*")
_TOKEN = re.compile(r"[^\W\d][\w']*|\d+|[^\s]")
# lib/auth/ defines these functions and is the store they read.
EXEMPT_PREFIX = "lib/auth/"

# (file, function) -> static references to the four guarded legacy APIs.
# Each entry says why the file retains that reference.
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
    """A bare auth module that can hide a guarded member's name."""

    path: str
    line: int
    text: str


@dataclass(frozen=True, slots=True)
class Scan:
    calls: tuple[Call, ...]
    hidden: tuple[Hidden, ...]


def _line(code: str, offset: int) -> int:
    return code.count("\n", 0, offset) + 1


@dataclass(frozen=True, slots=True)
class _Token:
    text: str
    offset: int


def _module_name(text: str) -> bool:
    return bool(_IDENTIFIER.fullmatch(text)) and text[0].isupper()


def _name_preserving_aliases(tokens: list[_Token]) -> set[int]:
    """Only `module Auth = Pkg.Auth`-shaped simple aliases keep the name."""
    exempt: set[int] = set()
    for index, token in enumerate(tokens):
        if token.text != "module" or index + 3 >= len(tokens):
            continue
        name = tokens[index + 1].text
        if name not in QUALIFIERS or tokens[index + 2].text != "=":
            continue
        end = index + 3
        if not _module_name(tokens[end].text):
            continue
        while (
            end + 2 < len(tokens)
            and tokens[end + 1].text == "."
            and _module_name(tokens[end + 2].text)
        ):
            end += 2
        if end + 1 < len(tokens) and tokens[end + 1].text in (".", "("):
            continue
        if tokens[end].text == name:
            exempt.update((index + 1, end))
    return exempt


def _in_module_expression(tokens: list[_Token], index: int) -> bool:
    """A bare module path needs a module context; `Error (Auth x)` does not.

    Walk back through the path's wrapping parentheses and module binding's
    annotation, stopping at a value/type declaration or structure body.
    Closed groups before this path are skipped, so a preceding first-class
    package does not turn a later value constructor into a module reference.
    """
    if index > 0 and tokens[index - 1].text == "`":
        return False
    if (
        index > 0
        and tokens[index - 1].text == "module"
        and index + 1 < len(tokens)
        and tokens[index + 1].text in ("=", ":")
        and (index < 2 or tokens[index - 2].text != "(")
    ):
        return False  # A module binding's name, not its right-hand side.
    closing = {")": "(", "]": "[", "}": "{"}
    skip: list[str] = []
    bound = False
    position = index - 1
    while position >= 0:
        text = tokens[position].text
        if text in closing:
            skip.append(closing[text])
        elif skip:
            if text == skip[-1]:
                skip.pop()
        elif text == "=":
            bound = True
        elif text == "end":
            if not bound:
                return False
            # A binding's `: sig ... end` annotation may precede its RHS.
            blocks = 1
            position -= 1
            while position >= 0 and blocks:
                part = tokens[position].text
                if part == "end":
                    blocks += 1
                elif part in ("sig", "struct", "object", "begin"):
                    blocks -= 1
                position -= 1
            continue
        elif (
            text == "type"
            and position > 0
            and tokens[position - 1].text == "module"
            and position + 1 < len(tokens)
            and tokens[position + 1].text == "of"
        ):
            return True
        elif text == "type" and position > 0 and tokens[position - 1].text in ("with", "and"):
            # These are module-type constraints, not a type declaration in
            # a structure. Keep looking for the binding's module context.
            position -= 2
            continue
        elif text in ("module", "open", "include", "functor"):
            return True
        elif text in (
            "let", "in", "type", "val", "external", "exception", "struct",
            "sig", "object", "begin", "fun", "function", "match", "with",
            "try", "then", "else", "do", "done", "while", "for", "|", ";", ",",
        ):
            return False
        position -= 1
    return False


def scan_text(path: str, text: str) -> Scan:
    code = code_only(text)
    tokens = [_Token(match.group(0), match.start()) for match in _TOKEN.finditer(code)]
    aliases = _name_preserving_aliases(tokens)
    calls: list[Call] = []
    hidden: list[Hidden] = []
    for index, token in enumerate(tokens):
        if token.text not in QUALIFIERS:
            continue
        member = (
            tokens[index + 2].text
            if index + 2 < len(tokens)
            and tokens[index + 1].text == "."
            and _IDENTIFIER.fullmatch(tokens[index + 2].text)
            else None
        )
        if member is not None and member in WATCHED:
            calls.append(Call(path, _line(code, token.offset), member))
        local_open = (
            index + 2 < len(tokens)
            and tokens[index + 1].text == "."
            and tokens[index + 2].text in ("(", "[", "{")
        )
        if member is None and index not in aliases and (
            local_open or _in_module_expression(tokens, index)
        ):
            hidden.append(Hidden(path, _line(code, token.offset), token.text))
    return Scan(tuple(calls), tuple(hidden))


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
            "  A new reference to a guarded legacy token API was added. Pass the door's answer "
            "(Auth.request_principal, Mcp_server_eio_caller_identity.bearer) "
            "instead, or give the reason in RFC D6 and raise the count in "
            "scripts/ci/raw_token_auth_calls.py."
        )
    else:
        lines.append(
            "  A guarded reference was removed. Lower the count in "
            "scripts/ci/raw_token_auth_calls.py so it stays removed."
        )
    return "\n".join(lines)


def report_hidden(hidden: Hidden) -> str:
    return (
        f"{hidden.path}:{hidden.line}: bare module `{hidden.text}` can hide "
        "the four guarded API names. Use a qualified member or a simple "
        "alias that keeps the module's name."
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else None)
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    args = parser.parse_args(argv)
    root: pathlib.Path = args.root
    found = scan(root)
    wrong = mismatches(found.calls, ALLOWED)
    if not wrong and not found.hidden:
        print(
            "four legacy auth API references: counts match the allow-list; "
            "other token helpers/raw comparisons are out of scope"
        )
        return 0
    for hidden in found.hidden:
        print(report_hidden(hidden), file=sys.stderr)
    for mismatch in wrong:
        print(report(mismatch), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
