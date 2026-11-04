"""Fail loudly when a test/stanzas/*.inc file and test/dune disagree.

test/dune lists every stanza file by hand with one `(include stanzas/...)`
line each. Forget one line and the test does not fail: it silently stops
existing. This check compares the two sets in both directions and prints
every offending file name.

Exclusions are an explicit list below, not a pattern: README.md documents
the directory and is never a stanza. Dune `;` comments are skipped because
test/dune carries an example `(include stanzas/test_name.inc)` line in its
header comment (and nowhere else).

Runs two ways:
  python3 test/test_stanzas_include.py        # from the repo root
  dune build @test-stanzas-include            # standalone alias, never required
"""

import argparse
import sys
from collections import Counter
from pathlib import Path

INCLUDE_PREFIX = "(include stanzas/"
HERE = Path(__file__).resolve().parent

# Exact file names under test/stanzas/ that are not test stanzas.
# README.md is directory documentation; dune would reject it as a stanza.
NON_STANZA_FILES = frozenset({"README.md"})


def parse_includes(dune_path):
    """Return (includes, malformed) from test/dune.

    includes maps file name -> list of 1-based line numbers. malformed
    holds (line number, line text) for lines that start an include but do
    not parse as exactly one `(include stanzas/<name>)`.
    """
    includes = {}
    malformed = []
    for lineno, raw in enumerate(dune_path.read_text().splitlines(), 1):
        # Dune treats `;` as a line comment anywhere; an example include
        # lives in the header comment and must not count as a real one.
        code = raw.split(";", 1)[0].strip()
        if not code or not code.startswith(INCLUDE_PREFIX):
            continue
        name = None
        if code.endswith(")") and code.count("(") == 1 and code.count(")") == 1:
            name = code[len(INCLUDE_PREFIX) : -1]
        if not name or any(ch.isspace() for ch in name) or "/" in name:
            malformed.append((lineno, raw.strip()))
            continue
        includes.setdefault(name, []).append(lineno)
    return includes, malformed


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dune", type=Path, default=HERE / "dune")
    parser.add_argument("--stanzas-dir", type=Path, default=HERE / "stanzas")
    args = parser.parse_args(argv)

    files = {
        p.name
        for p in args.stanzas_dir.iterdir()
        if p.is_file() and p.suffix == ".inc" and p.name not in NON_STANZA_FILES
    }
    includes, malformed = parse_includes(args.dune)
    included = set(includes)

    errors = []
    for name in sorted(files - included):
        errors.append(f"{args.stanzas_dir.name}/{name}: file exists but has no (include) line in {args.dune}")
    for name in sorted(included - files):
        lines = ",".join(str(n) for n in includes[name])
        errors.append(
            f"(include stanzas/{name}): included by {args.dune} (line {lines}) but file is missing"
        )
    for name, lines in sorted(includes.items()):
        if len(lines) > 1:
            joined = ",".join(str(n) for n in lines)
            errors.append(f"(include stanzas/{name}): included {len(lines)} times ({args.dune} lines {joined})")
    for lineno, text in malformed:
        errors.append(f"{args.dune} line {lineno}: malformed include line: {text}")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"OK: {len(files)} stanza files, {len(included)} includes, sets match")
    return 0


if __name__ == "__main__":
    sys.exit(main())
