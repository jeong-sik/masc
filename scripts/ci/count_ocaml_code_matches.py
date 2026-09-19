#!/usr/bin/env python3
"""Count a regex in the code of OCaml sources, never in comments or strings.

A plain `rg '[@@deriving tla]' lib/` also counts a sentence that mentions
the attribute, so a floor built on it moves when a comment is edited. This
blanks comments, string literals and quoted strings first, the way the OCaml
lexer reads them, and only then matches:

  - comments nest, and inside a comment the lexer still reads string
    literals, quoted strings, character literals, `''` and identifiers, so
    `(* "*)" *)` is one comment and `(* '"' *)` opens no string;
  - `{|...|}`, `{id|...|id}` and the quoted extensions `{%ext|...|}`,
    `{%%ext|...|}` and `{%ext id|...|id}` (the name may be dotted) end only
    at their own terminator, in code and in comments;
  - `'"'`, `'\\''` and a quote around a raw newline are characters; a
    character literal holds one ASCII byte, so `'é'` is not one;
  - an identifier, including one with UTF-8 letters such as `café'`, keeps
    its trailing quote.

Blanking keeps newlines, so a match keeps its line. An unterminated comment,
string or quoted string is an error that names the file, not a guess.

Usage:
  count_ocaml_code_matches.py files   PATTERN ROOT   # .ml files with a match
  count_ocaml_code_matches.py matches PATTERN ROOT   # matches over all .ml
  count_ocaml_code_matches.py subdirs PATTERN ROOT   # distinct first-level
                                                     # entries under ROOT
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

# OCaml 5 identifiers take UTF-8 letters; the lexer checks them later, so
# any non-ASCII character is read as part of an identifier here.
IDENTIFIER_START = r"A-Za-z_\u0080-\U0010ffff"
IDENTIFIER = re.compile(rf"[{IDENTIFIER_START}][{IDENTIFIER_START}0-9']*")
EXTENSION_NAME = rf"[{IDENTIFIER_START}][{IDENTIFIER_START}0-9']*(?:\.[{IDENTIFIER_START}][{IDENTIFIER_START}0-9']*)*"
CHARACTER_LITERAL = re.compile(
    r"'(?:\r*\n|\\(?:[\\\"'ntbr ]|[0-9]{3}|o[0-3][0-7]{2}|x[0-9A-Fa-f]{2})|(?![\\'\n\r])[\x00-\x7f])'"
)
# The lexer's [\'\'] rule: inside a comment two quotes are one token.
EMPTY_QUOTES = "''"
QUOTED_STRING_START = re.compile(rf"\{{(?:%%?{EXTENSION_NAME}[ \t]*)?([a-z_]*)\|")


class OcamlLexError(ValueError):
    pass


def mask_ocaml_non_code(text: str) -> str:
    """Replace comments and string contents with spaces, keeping newlines."""
    masked = list(text)
    length = len(text)

    def blank(start: int, end: int) -> None:
        for offset in range(start, end):
            if masked[offset] != "\n":
                masked[offset] = " "

    def end_of_string(index: int) -> int:
        index += 1
        while index < length:
            character = text[index]
            if character == "\\":
                index += 2
            elif character == '"':
                return index + 1
            else:
                index += 1
        raise OcamlLexError("unterminated string literal")

    def end_of_quoted(match: re.Match[str]) -> int:
        terminator = f"|{match.group(1)}}}"
        end = text.find(terminator, match.end())
        if end < 0:
            raise OcamlLexError("unterminated quoted string")
        return end + len(terminator)

    def end_of_comment(index: int) -> int:
        depth = 0
        while index < length:
            if text.startswith("(*", index):
                depth += 1
                index += 2
                continue
            if text.startswith("*)", index):
                depth -= 1
                index += 2
                if depth == 0:
                    return index
                continue
            if text[index] == '"':
                index = end_of_string(index)
                continue
            quoted = QUOTED_STRING_START.match(text, index)
            if quoted is not None:
                index = end_of_quoted(quoted)
                continue
            if text.startswith(EMPTY_QUOTES, index):
                index += len(EMPTY_QUOTES)
                continue
            character = CHARACTER_LITERAL.match(text, index)
            if character is not None:
                index = character.end()
                continue
            identifier = IDENTIFIER.match(text, index)
            if identifier is not None:
                index = identifier.end()
                continue
            index += 1
        raise OcamlLexError("unterminated comment")

    index = 0
    while index < length:
        if text.startswith("(*", index):
            end = end_of_comment(index)
            blank(index, end)
            index = end
            continue
        if text[index] == '"':
            end = end_of_string(index)
            blank(index, end)
            index = end
            continue
        quoted = QUOTED_STRING_START.match(text, index)
        if quoted is not None:
            end = end_of_quoted(quoted)
            blank(index, end)
            index = end
            continue
        character = CHARACTER_LITERAL.match(text, index)
        if character is not None:
            blank(index, character.end())
            index = character.end()
            continue
        identifier = IDENTIFIER.match(text, index)
        if identifier is not None:
            index = identifier.end()
            continue
        index += 1
    return "".join(masked)


def implementation_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for directory, subdirectories, names in os.walk(root):
        subdirectories[:] = sorted(d for d in subdirectories if not d.startswith("."))
        files.extend(Path(directory) / name for name in sorted(names) if name.endswith(".ml"))
    return files


def code_match_counts(pattern: re.Pattern[str], root: Path) -> dict[Path, int]:
    counts: dict[Path, int] = {}
    for path in implementation_files(root):
        text = path.read_text(encoding="utf-8")
        try:
            code = mask_ocaml_non_code(text)
        except OcamlLexError as error:
            raise OcamlLexError(f"{path}: {error}") from error
        count = len(pattern.findall(code))
        if count:
            counts[path] = count
    return counts


def main(argv: list[str]) -> int:
    if len(argv) != 4 or argv[1] not in ("files", "matches", "subdirs"):
        print(f"usage: {argv[0]} files|matches|subdirs PATTERN ROOT", file=sys.stderr)
        return 1
    mode, pattern, root = argv[1], re.compile(argv[2]), Path(argv[3])
    if not root.is_dir():
        print(f"{root} is not a directory", file=sys.stderr)
        return 1
    try:
        counts = code_match_counts(pattern, root)
    except OcamlLexError as error:
        print(f"cannot read OCaml source: {error}", file=sys.stderr)
        return 1
    if mode == "files":
        print(len(counts))
    elif mode == "matches":
        print(sum(counts.values()))
    else:
        print(len({path.relative_to(root).parts[0] for path in counts}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
