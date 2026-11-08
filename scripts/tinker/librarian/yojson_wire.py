# pyright: strict
"""JSON values as MASC's Yojson reads and writes them.

MASC reads a model answer with `Yojson.Safe.from_string` and renders prompt
sections with `Yojson.Safe.to_string`. Python's json module disagrees with both:
Yojson accepts comments, unquoted identifier keys, raw control characters in
strings and the NaN/Infinity literals, keeps duplicate members, reads integers
beyond the OCaml native range as `Intlit`, and writes floats in its own text.
This module follows the Yojson 3.0.0 source (`yojson/safe.ml`; masc.opam pins
yojson >= 3.0 < 4.0) instead. Edge cases were checked against a compiled probe
that calls `Yojson.Safe.from_string` (2026-11-08).

Pure: no I/O. Errors are values, never exceptions.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass

# OCaml 5 native int on 64-bit hosts: 63-bit two's complement.
OCAML_INT_MIN = -(2**62)
OCAML_INT_MAX = 2**62 - 1


@dataclass(frozen=True, slots=True)
class IntLit:
    """An integer literal outside the OCaml int range (Yojson `Intlit`), kept as text."""

    text: str


@dataclass(frozen=True, slots=True)
class JsonObject:
    """An object with its members in source order. Duplicate names are kept."""

    members: tuple[tuple[str, Json], ...]


type Json = None | bool | int | float | str | IntLit | tuple[Json, ...] | JsonObject


@dataclass(frozen=True, slots=True)
class Absent:
    """A member lookup that found no member (JSON null is a present `None`)."""


ABSENT = Absent()


def member(obj: JsonObject, key: str) -> Json | Absent:
    """`List.assoc_opt`: the first member with this name."""
    for name, value in obj.members:
        if name == key:
            return value
    return ABSENT


@dataclass(frozen=True, slots=True)
class JsonError:
    """Why the text is not a JSON value Yojson would read, and where."""

    offset: int
    detail: str


# ---------------------------------------------------------------- reader

_NUMBER = re.compile(r"-?(?:0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?")
_IDENT = re.compile(r"[a-zA-Z_][a-zA-Z0-9_]*")
_STRING_RUN = re.compile(r'[^"\\]*')
_HEX4 = re.compile(r"[0-9a-fA-F]{4}")
_SPACE_RUN = re.compile(r"[ \t\r\n]*")
# Literal tokens are matched as prefixes, as the Yojson lexer does: `nullx`
# reads `null` and then fails on `x` as the next token.
_LITERALS: tuple[tuple[str, Json], ...] = (
    ("true", True),
    ("false", False),
    ("null", None),
    ("NaN", math.nan),
    ("Infinity", math.inf),
    ("-Infinity", -math.inf),
)
_SIMPLE_ESCAPES = {'"': '"', "\\": "\\", "/": "/", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t"}

type _Read = tuple[Json, int] | JsonError


def _skip_space(text: str, pos: int) -> int | JsonError:
    """Whitespace is space, tab, CR and LF; `/* */` and `//` (to LF) comments count as space."""
    while True:
        space = _SPACE_RUN.match(text, pos)
        pos = space.end() if space is not None else pos
        if text.startswith("/*", pos):
            close = text.find("*/", pos + 2)
            if close < 0:
                return JsonError(len(text), "unterminated comment")
            pos = close + 2
        elif text.startswith("//", pos):
            newline = text.find("\n", pos + 2)
            pos = len(text) if newline < 0 else newline + 1
        else:
            return pos


def _read_string(text: str, pos: int) -> tuple[str, int] | JsonError:
    """A string token starting at the opening quote."""
    parts: list[str] = []
    pos += 1
    while True:
        run = _STRING_RUN.match(text, pos)
        if run is not None and run.end() > pos:
            parts.append(run.group())
            pos = run.end()
        if pos >= len(text):
            return JsonError(pos, "unexpected end of input in a string")
        if text[pos] == '"':
            return "".join(parts), pos + 1
        # A backslash.
        if pos + 1 >= len(text):
            return JsonError(pos, "unexpected end of input in an escape")
        escape = text[pos + 1]
        simple = _SIMPLE_ESCAPES.get(escape)
        if simple is not None:
            parts.append(simple)
            pos += 2
            continue
        if escape != "u":
            return JsonError(pos, "invalid escape sequence")
        first = _HEX4.match(text, pos + 2)
        if first is None:
            return JsonError(pos, "invalid escape sequence")
        code = int(first.group(), 16)
        pos += 6
        if 0xD800 <= code <= 0xDBFF:
            # A high surrogate needs an escaped low surrogate right after it.
            if not text.startswith("\\u", pos):
                return JsonError(pos, "missing escape sequence representing low surrogate")
            second = _HEX4.match(text, pos + 2)
            if second is None:
                return JsonError(pos, "invalid escape sequence")
            low = int(second.group(), 16)
            if not 0xDC00 <= low <= 0xDFFF:
                return JsonError(pos, "invalid low surrogate")
            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
            pos += 6
        # A lone low surrogate is accepted, as Yojson does.
        parts.append(chr(code))


def _read_number(text: str, pos: int) -> _Read:
    found = _NUMBER.match(text, pos)
    if found is None:
        return JsonError(pos, "invalid token")
    lexeme = found.group()
    if found.group(1) is not None or found.group(2) is not None:
        return float(lexeme), found.end()
    value = int(lexeme)
    if OCAML_INT_MIN <= value <= OCAML_INT_MAX:
        return value, found.end()
    return IntLit(lexeme), found.end()


def _read_object(text: str, pos: int) -> _Read:
    members: list[tuple[str, Json]] = []
    after = _skip_space(text, pos + 1)
    if isinstance(after, JsonError):
        return after
    pos = after
    if text.startswith("}", pos):
        return JsonObject(()), pos + 1
    while True:
        if text.startswith('"', pos):
            key = _read_string(text, pos)
            if isinstance(key, JsonError):
                return key
            name, pos = key
        else:
            ident = _IDENT.match(text, pos)
            if ident is None:
                return JsonError(pos, "expected string or identifier")
            name, pos = ident.group(), ident.end()
        after = _skip_space(text, pos)
        if isinstance(after, JsonError):
            return after
        if not text.startswith(":", after):
            return JsonError(after, "expected ':'")
        after = _skip_space(text, after + 1)
        if isinstance(after, JsonError):
            return after
        value = _read_value(text, after)
        if isinstance(value, JsonError):
            return value
        members.append((name, value[0]))
        after = _skip_space(text, value[1])
        if isinstance(after, JsonError):
            return after
        if text.startswith("}", after):
            return JsonObject(tuple(members)), after + 1
        if not text.startswith(",", after):
            return JsonError(after, "expected ',' or '}'")
        after = _skip_space(text, after + 1)
        if isinstance(after, JsonError):
            return after
        pos = after


def _read_array(text: str, pos: int) -> _Read:
    items: list[Json] = []
    after = _skip_space(text, pos + 1)
    if isinstance(after, JsonError):
        return after
    pos = after
    if text.startswith("]", pos):
        return (), pos + 1
    while True:
        value = _read_value(text, pos)
        if isinstance(value, JsonError):
            return value
        items.append(value[0])
        after = _skip_space(text, value[1])
        if isinstance(after, JsonError):
            return after
        if text.startswith("]", after):
            return tuple(items), after + 1
        if not text.startswith(",", after):
            return JsonError(after, "expected ',' or ']'")
        after = _skip_space(text, after + 1)
        if isinstance(after, JsonError):
            return after
        pos = after


def _read_value(text: str, pos: int) -> _Read:
    if pos >= len(text):
        return JsonError(pos, "unexpected end of input")
    head = text[pos]
    if head == "{":
        return _read_object(text, pos)
    if head == "[":
        return _read_array(text, pos)
    if head == '"':
        return _read_string(text, pos)
    for lexeme, literal in _LITERALS:
        if text.startswith(lexeme, pos):
            return literal, pos + len(lexeme)
    return _read_number(text, pos)


def parse(text: str) -> Json | JsonError:
    """`Yojson.Safe.from_string`: one value, optional space and comments around it."""
    start = _skip_space(text, 0)
    if isinstance(start, JsonError):
        return start
    if start >= len(text):
        return JsonError(start, "blank input data")
    read = _read_value(text, start)
    if isinstance(read, JsonError):
        return read
    end = _skip_space(text, read[1])
    if isinstance(end, JsonError):
        return end
    if end != len(text):
        return JsonError(end, "junk after end of JSON value")
    return read[0]


def read_value_at(text: str, pos: int) -> _Read:
    """One value that starts exactly at `pos`, and the offset just after it.

    Used to find where a `Yojson.Safe.to_string` section ends inside a prompt.
    Compact output has no space around the value, so none is skipped here.
    """
    return _read_value(text, pos)


# ---------------------------------------------------------------- writer

_ESCAPED = re.compile(r'["\\\x00-\x1f\x7f]')
_NAMED_ESCAPES = {'"': '\\"', "\\": "\\\\", "\b": "\\b", "\f": "\\f", "\n": "\\n", "\r": "\\r", "\t": "\\t"}


def _escape(found: re.Match[str]) -> str:
    char = found.group()
    named = _NAMED_ESCAPES.get(char)
    return named if named is not None else f"\\u{ord(char):04x}"


def write_string(value: str) -> str:
    """`write_string`: named escapes, `\\u00xx` (lowercase hex) for other controls and DEL."""
    return '"' + _ESCAPED.sub(_escape, value) + '"'


def format_float(value: float) -> str:
    """`write_float` for a finite float: `%.16g`, or `%.17g` when that does not read back.

    A text of only digits and '-' gains ".0" so the value stays a float.
    MASC's writer refuses NaN and infinities (`Json_error`); this writes the
    literals Yojson's reader accepts, so a test can build such an answer.
    """
    if math.isnan(value):
        return "NaN"
    if math.isinf(value):
        return "Infinity" if value > 0 else "-Infinity"
    text = f"{value:.16g}"
    if float(text) != value:
        text = f"{value:.17g}"
    if all(char.isdigit() or char == "-" for char in text):
        text += ".0"
    return text


def write(value: Json) -> str:
    """`Yojson.Safe.to_string`: compact, members in the order given."""
    match value:
        case None:
            return "null"
        case bool():
            return "true" if value else "false"
        case int():
            return str(value)
        case float():
            return format_float(value)
        case str():
            return write_string(value)
        case IntLit(text=text):
            return text
        case tuple():
            return "[" + ",".join(write(item) for item in value) + "]"
        case JsonObject(members=members):
            return "{" + ",".join(write_string(name) + ":" + write(item) for name, item in members) + "}"
