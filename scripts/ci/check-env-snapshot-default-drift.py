#!/usr/bin/env python3
"""Fail when the operator env snapshot states a default the reader does not use.

`lib/config/env_config_snapshot.ml` is what `masc_config_*` introspection, the
H2 gateway and the dashboard report as each knob's default. The value that
actually applies comes from the reader's `~default:` at the `get_int` /
`get_float` / `get_bool` / `get_string` call site. Nothing tied the two
together, so #14143 raised MASC_HTTP_MAX_CONNECTIONS from 128 to 512 in the
reader and left the snapshot on 128 for three months.

Only literal-vs-literal pairs are compared. An entry that names a shared
constant -- `entry ~default:Masc_network_defaults.masc_http_default_host` --
cannot drift and is skipped, which is the shape this check wants to push
toward rather than a longer list of matching literals.
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
SNAPSHOT = REPO / "lib" / "config" / "env_config_snapshot.ml"
LIB = REPO / "lib"

# entry ~default:"512" "MASC_X" — default first, on the same line or the next.
DECLARED = re.compile(r'entry\s+~default:"([^"]*)"\s*\n?\s*"(MASC_[A-Z0-9_]+)"')
# get_int ~default:512 "MASC_X" — reader form, default immediately before the
# name. Scanned over whole-file text, not line by line: the two often sit on
# separate lines once the call no longer fits on one, and a line-scoped pattern
# would silently stop seeing exactly the readers this check exists for.
READER = re.compile(r'~default:\s*([^\s)]+)\s*\n?\s*"(MASC_[A-Z0-9_]+)"')


def numeric(value: str) -> float | None:
    try:
        return float(value.replace("_", ""))
    except ValueError:
        return None


def boolean(value: str) -> bool | None:
    return {"true": True, "false": False}.get(value)


# The snapshot writes this when a knob has no default at all: unset means the
# feature stays off, or the reader hands back an option the caller decides on.
NO_DEFAULT = "(none)"


def comparable(declared: str, actual: str) -> tuple[object, object] | None:
    """Return the pair to compare, or None when the two are not comparable."""
    dn, an = numeric(declared), numeric(actual)
    if dn is not None and an is not None:
        return dn, an
    db, ab = boolean(declared), boolean(actual)
    if db is not None and ab is not None:
        return db, ab
    # A reader whose default is itself a quoted literal states its text
    # directly, so the snapshot has to match that text — this is what keeps an
    # empty-string default comparable at all. A reader that names a constant
    # instead resolves at compile time and cannot be read here, so it is left
    # to the OCaml test that pins the two together.
    if actual.startswith('"') and actual.endswith('"') and len(actual) >= 2:
        return declared, actual[1:-1]
    return None


def main() -> int:
    snapshot_text = SNAPSHOT.read_text()
    declared = {var: default for default, var in DECLARED.findall(snapshot_text)}

    readers: dict[str, list[tuple[str, str, int]]] = {}
    for path in sorted(LIB.rglob("*.ml")):
        if path == SNAPSHOT:
            continue
        text = path.read_text()
        for match in READER.finditer(text):
            lineno = text.count("\n", 0, match.start()) + 1
            readers.setdefault(match.group(2), []).append(
                (match.group(1), str(path.relative_to(REPO)), lineno)
            )

    drift = []
    compared = 0
    for var, declared_default in declared.items():
        for actual, path, lineno in readers.get(var, []):
            # A reader only lands in `readers` because it declares ~default:, so
            # the snapshot claiming the knob has none is a statement about this
            # very call site and is false. This is the case the type-directed
            # comparison below cannot see — "(none)" is neither numeric nor
            # boolean, so `comparable` returns None and the pair is dropped —
            # and it is also the most misleading one to leave on the operator
            # surface: it reads as "unset does nothing".
            if declared_default == NO_DEFAULT:
                compared += 1
                drift.append((var, declared_default, actual, path, lineno))
                continue
            pair = comparable(declared_default, actual)
            if pair is None:
                continue
            compared += 1
            if pair[0] != pair[1]:
                drift.append((var, declared_default, actual, path, lineno))

    print(f"=== env snapshot default drift: {compared} literal pairs compared ===")
    if not drift:
        print("PASS: every stated default matches the reader that applies it")
        return 0

    print("FAIL: the operator surface states a default the reader does not use:")
    for var, declared_default, actual, path, lineno in drift:
        print(f"  {var}")
        print(f"    env_config_snapshot.ml says {declared_default!r}")
        print(f"    {path}:{lineno} uses {actual}")
    print()
    print("Name one shared constant and reference it from both, the way")
    print("MASC_HTTP_HOST references Masc_network_defaults.masc_http_default_host.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
