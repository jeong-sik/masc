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

# Every `entry ` in the snapshot, so the report has a denominator it did not
# make up. Anything below this count that is not compared has to be named.
ENTRY = re.compile(r"^\s*entry\s", re.MULTILINE)

# The env var each side names: a literal, or an identifier that a
# `let x_env = "MASC_..."` elsewhere resolves. Both sides need the second form.
# The snapshot writes `entry ~default:X Env_config_core.foo_env_key` and a
# reader writes `get_int ~default:30 telemetry_retention_days_env`, and while
# the name is behind a constant neither side is comparable to anything -- 57
# of the snapshot's 120 entries sat outside this check for that reason, under
# a line that said "63 literal pairs compared / PASS".
NAME = r'(?:"(MASC_[A-Z0-9_]+)"|([A-Za-z][A-Za-z0-9_.\']*))'

# entry ~default:"512" "MASC_X" — default first, on the same line or the next.
DECLARED = re.compile(r'entry\s+~default:"([^"]*)"\s*\n?\s*' + NAME)
# get_int ~default:512 "MASC_X" — reader form, default immediately before the
# name. Scanned over whole-file text, not line by line: the two often sit on
# separate lines once the call no longer fits on one, and a line-scoped pattern
# would silently stop seeing exactly the readers this check exists for.
READER = re.compile(r'~default:\s*([^\s)]+)\s*\n?\s*' + NAME)

# let masc_host_env_key = "MASC_HOST"
ALIAS = re.compile(r'^\s*let\s+([a-z_][A-Za-z0-9_\']*)\s*=\s*"(MASC_[A-Z0-9_]+)"\s*$',
                   re.MULTILINE)


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


def build_aliases(sources: list[tuple[pathlib.Path, str]]) -> dict[str, str]:
    """Identifier -> env var, for names bound to a literal somewhere in lib.

    Registered both bare and module-qualified, because the snapshot writes
    [Env_config_core.foo_env_key] and the module that defines it writes
    [foo_env_key]. A bare name bound to two different vars in two files is
    dropped rather than guessed: the qualified form still resolves, and a
    wrong guess would compare a knob against a reader for a different knob.
    """
    bare: dict[str, set[str]] = {}
    aliases: dict[str, str] = {}
    for path, text in sources:
        module = path.stem[:1].upper() + path.stem[1:]
        for name, var in ALIAS.findall(text):
            aliases[f"{module}.{name}"] = var
            bare.setdefault(name, set()).add(var)
    for name, vars_ in bare.items():
        if len(vars_) == 1:
            aliases[name] = next(iter(vars_))
    return aliases


def resolve(literal: str, identifier: str, aliases: dict[str, str]) -> str | None:
    """The env var a matched name stands for, or None when it is unresolvable."""
    if literal:
        return literal
    return aliases.get(identifier)


def main() -> int:
    snapshot_text = SNAPSHOT.read_text()
    sources = [
        (path, path.read_text())
        for path in sorted(LIB.rglob("*.ml"))
    ]
    aliases = build_aliases(sources)

    entry_total = len(ENTRY.findall(snapshot_text))
    declared: dict[str, str] = {}
    unresolved_names = 0
    restated = 0
    matches = DECLARED.findall(snapshot_text)
    # An entry whose ~default: is not a quoted literal never reaches the
    # regex at all, so it is the difference between the entry count and the
    # match count rather than a category the loop below can see.
    unmatched = entry_total - len(matches)
    for default, literal, identifier in matches:
        var = resolve(literal, identifier, aliases)
        if var is None:
            unresolved_names += 1
            continue
        if var in declared:
            restated += 1
        declared[var] = default

    readers: dict[str, list[tuple[str, str, int]]] = {}
    for path, text in sources:
        if path == SNAPSHOT:
            continue
        for match in READER.finditer(text):
            var = resolve(match.group(2) or "", match.group(3) or "", aliases)
            if var is None:
                continue
            lineno = text.count("\n", 0, match.start()) + 1
            readers.setdefault(var, []).append(
                (match.group(1), str(path.relative_to(REPO)), lineno)
            )

    drift = []
    compared = 0
    no_reader = 0
    incomparable = 0
    # Counted per entry, not per (entry, reader) pair: a knob read in three
    # places is one line on the operator surface, and mixing the two units is
    # how a breakdown stops adding up to the total it is a breakdown of. Every
    # mismatching reader still gets its own line in the failure below.
    for var, declared_default in declared.items():
        if not readers.get(var):
            no_reader += 1
            continue
        entry_compared = False
        for actual, path, lineno in readers.get(var, []):
            # A reader only lands in `readers` because it declares ~default:, so
            # the snapshot claiming the knob has none is a statement about this
            # very call site and is false. This is the case the type-directed
            # comparison below cannot see — "(none)" is neither numeric nor
            # boolean, so `comparable` returns None and the pair is dropped —
            # and it is also the most misleading one to leave on the operator
            # surface: it reads as "unset does nothing".
            if declared_default == NO_DEFAULT:
                entry_compared = True
                drift.append((var, declared_default, actual, path, lineno))
                continue
            pair = comparable(declared_default, actual)
            if pair is None:
                continue
            entry_compared = True
            if pair[0] != pair[1]:
                drift.append((var, declared_default, actual, path, lineno))
        if entry_compared:
            compared += 1
        else:
            incomparable += 1

    # The denominator is the snapshot's own entry count, and every entry this
    # check could not reach is named. A report that only prints what it
    # compared reads as 100% however small the numerator gets, which is how 57
    # of 120 entries went unexamined behind a PASS.
    print(
        f"=== env snapshot default drift: {compared} of {entry_total} "
        "snapshot entries compared ==="
    )
    unreached = entry_total - compared
    if unreached:
        print(f"  {unreached} not compared:")
        for count, why in (
            (unmatched, "state a default that is not a quoted literal"),
            (unresolved_names, "name an env var this check cannot resolve"),
            (restated, "restate a var another entry already declared"),
            (no_reader, "have no reader that states a ~default:"),
            (incomparable, "state a default the reader's form cannot be compared to"),
        ):
            if count:
                print(f"    {count} {why}")
        rest = (
            unreached - unmatched - unresolved_names - restated - no_reader
            - incomparable
        )
        if rest:
            print(f"    {rest} unaccounted for")
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
