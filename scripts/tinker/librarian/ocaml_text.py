# pyright: strict
"""OCaml Stdlib text functions that MASC applies to prompt and answer text.

Pure: no I/O.
"""

from __future__ import annotations


def ocaml_trim(text: str) -> str:
    """`String.trim`: strips only ' ', '\\012', '\\n', '\\r' and '\\t'."""
    return text.strip(" \x0c\n\r\t")


def ocaml_quoted(text: str) -> str:
    """OCaml `%S`: `String.escaped` between double quotes, bytes outside 32..126 as decimal."""
    out: list[str] = []
    for byte in text.encode("utf-8", "surrogatepass"):
        char = chr(byte)
        match char:
            case '"' | "\\":
                out.append("\\" + char)
            case "\n":
                out.append("\\n")
            case "\t":
                out.append("\\t")
            case "\r":
                out.append("\\r")
            case "\b":
                out.append("\\b")
            case _ if 32 <= byte <= 126:
                out.append(char)
            case _:
                out.append(f"\\{byte:03d}")
    return '"' + "".join(out) + '"'
