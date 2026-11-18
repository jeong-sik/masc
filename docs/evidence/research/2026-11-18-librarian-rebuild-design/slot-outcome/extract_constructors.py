#!/usr/bin/env python3
"""List the constructors of named variant types in OCaml interface files.

Usage: extract_constructors.py REPO_ROOT < types.txt > constructors.tsv
types.txt: one "relative/path.mli<TAB>type_name" per line.
Output: path, type, constructor, one line per constructor, in source order.
A type that is not found, or that has no constructors, is an error.
"""
import re
import sys
from pathlib import Path

CONSTRUCTOR = re.compile(r"^\s*\|\s*([A-Z][A-Za-z0-9_']*)")
FIRST = re.compile(r"=\s*\|?\s*([A-Z][A-Za-z0-9_']*)")


def strip_comments(text: str) -> str:
    out, depth, i = [], 0, 0
    while i < len(text):
        two = text[i : i + 2]
        if two == "(*":
            depth += 1
            i += 2
        elif two == "*)" and depth:
            depth -= 1
            i += 2
        else:
            if depth == 0:
                out.append(text[i])
            elif text[i] == "\n":
                out.append("\n")
            i += 1
    return "".join(out)


def constructors(text: str, name: str) -> list[str]:
    """NAME is a top-level type, or Module.type for a type inside `module Module : sig`."""
    lines = strip_comments(text).split("\n")
    start = 0
    if "." in name:
        module, name = name.split(".", 1)
        opener = re.compile(rf"^\s*module\s+{re.escape(module)}\s*:\s*sig\b")
        hits = [i for i, line in enumerate(lines) if opener.match(line)]
        if len(hits) != 1:
            raise SystemExit(f"module {module}: {len(hits)} openers")
        start = hits[0] + 1
        head = re.compile(rf"^\s+(type|and)\s+{re.escape(name)}\s*=")
        stop = re.compile(r"^\s*(type|and|val|module|exception|external|end)\b")
    else:
        head = re.compile(rf"^(type|and)\s+(\([^)]*\)\s+|'[a-z_]+\s+)?{re.escape(name)}\s*=")
        stop = re.compile(r"^(type|and|val|module|exception|external)\b")
    for index in range(start, len(lines)):
        line = lines[index]
        if not head.match(line):
            continue
        found: list[str] = []
        first = FIRST.search(line)
        if first and "{" not in line.split("=", 1)[1][:3]:
            found.append(first.group(1))
        depth = line.count("{") - line.count("}")
        for body in lines[index + 1 :]:
            if depth == 0 and stop.match(body):
                break
            if depth == 0:
                match = CONSTRUCTOR.match(body)
                if match:
                    found.append(match.group(1))
            depth += body.count("{") - body.count("}")
        return list(dict.fromkeys(found))
    raise SystemExit(f"type {name} not found")


def main() -> None:
    root = Path(sys.argv[1])
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw or raw.startswith("#"):
            continue
        path, name = raw.split("\t")
        names = constructors((root / path).read_text(encoding="utf-8"), name)
        if not names:
            raise SystemExit(f"type {name} in {path} has no constructors")
        for constructor in names:
            print(f"{path}\t{name}\t{constructor}")


if __name__ == "__main__":
    main()
