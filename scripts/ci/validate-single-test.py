#!/usr/bin/env python3
"""Admit one declared test target using the targeted runner's stanza parser."""
import os
from pathlib import Path
import sys

import stanza_env

ROOT = Path(stanza_env.REPO_ROOT)


def forms(directory):
    for _, source in stanza_env.included_stanza_sources(str(ROOT / directory / "dune")):
        yield from source


def alias_declared(name):
    for form in forms(Path("test")):
        if isinstance(form, list) and form and form[0] == "rule":
            if ["alias", "runtest-" + name] in form:
                return True
    return False


def validate(value):
    # One input means one resolver target, never CSV or the empty full-suite path.
    if not value or value != value.strip() or "," in value or any(c.isspace() for c in value):
        raise ValueError("name exactly one nonempty suite")
    path = Path(value)
    if path.is_absolute() or any(part in ("", ".", "..") or part.startswith("-")
                                for part in value.split("/")):
        raise ValueError("suite must be a repository-relative target, not an option or traversal")
    if not (ROOT / path).resolve().is_relative_to(ROOT.resolve()):
        raise ValueError("suite escapes repository")
    # Match the existing runner's Python/alias-before-OCaml resolution order.
    if (ROOT / "test" / (value + ".py")).is_file() or (ROOT / (value + ".py")).is_file():
        if alias_declared(path.name):
            return value
        raise ValueError("script has no declared runtest alias")
    if len(path.parts) == 1 and alias_declared(value):
        return value
    for candidate in (Path("test") / path, path):
        if (ROOT / (str(candidate) + ".ml")).is_file():
            if any(candidate.name in stanza_env.named_suites([form])
                   for form in forms(candidate.parent)):
                return value
            raise ValueError("source is not a declared Dune test")
    raise ValueError("suite names no declared targeted test; broad aliases are not accepted")


if __name__ == "__main__":
    try:
        suite = validate(os.environ["SUITE"])
    except (KeyError, ValueError, OSError, stanza_env.StanzaError) as exc:
        raise SystemExit(str(exc)) from exc
    print("Explicit single test: " + suite)
