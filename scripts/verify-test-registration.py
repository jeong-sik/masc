#!/usr/bin/env python3
"""Verify every test_*.ml file under test/ is registered in a dune or .inc file.

Parses dune S-expressions properly (handling multiline, nested forms, strings,
and comments) to avoid the false-positive flood from regex-based approaches.
"""

import sys
from pathlib import Path


def tokenize(content: str):
    """Tokenize dune sexp content into atoms, strings, parens. Skip comments."""
    tokens = []
    i = 0
    n = len(content)
    while i < n:
        c = content[i]
        if c in "()":
            tokens.append(c)
            i += 1
        elif c == ";":
            while i < n and content[i] != "\n":
                i += 1
        elif c.isspace():
            i += 1
        elif c == '"':
            i += 1
            start = i
            while i < n and content[i] != '"':
                if content[i] == "\\" and i + 1 < n:
                    i += 2
                else:
                    i += 1
            tokens.append(("string", content[start:i]))
            i += 1  # skip closing quote
        else:
            start = i
            while i < n and content[i] not in '() \t\n\r;"':
                i += 1
            tokens.append(("atom", content[start:i]))
    return tokens


def extract_test_names(tokens):
    """Extract test names from tokenized dune/inc content.

    Handles:
      (tests (names name1 name2 ...))
      (test (name single_name) (modules mod1 ...))
      (executable (name single_name) (modules mod1 ...))
      (library (name ...) (modules mod1 ...))
    """
    tests = set()
    i = 0
    n = len(tokens)

    while i < n:
        if tokens[i] == "(":
            # Look ahead for stanza type
            if i + 1 < n and isinstance(tokens[i + 1], tuple):
                stanza = tokens[i + 1][1]
                if stanza == "tests":
                    # Scan inside this (tests ...) block for executable names
                    # and explicitly registered support modules. A support
                    # module need not be an executable entry point, but it is
                    # still registered in Dune and must not be reported as an
                    # unregistered source file.
                    j = i + 2
                    depth = 1
                    while j < n and depth > 0:
                        if tokens[j] == "(":
                            depth += 1
                            if (
                                depth == 2
                                and j + 1 < n
                                and isinstance(tokens[j + 1], tuple)
                                and tokens[j + 1][1] in ("names", "modules")
                            ):
                                # collect atoms inside (names ...)/(modules ...)
                                k = j + 2
                                names_depth = 1
                                while k < n and names_depth > 0:
                                    if tokens[k] == "(":
                                        names_depth += 1
                                    elif tokens[k] == ")":
                                        names_depth -= 1
                                        if names_depth == 0:
                                            break
                                    elif (
                                        isinstance(tokens[k], tuple)
                                        and tokens[k][0] == "atom"
                                    ):
                                        tests.add(tokens[k][1])
                                    k += 1
                                j = k
                                continue
                        elif tokens[j] == ")":
                            depth -= 1
                        j += 1
                elif stanza in ("test", "executable", "library"):
                    # Scan inside this block for (name ...) and (modules ...)
                    j = i + 2
                    depth = 1
                    while j < n and depth > 0:
                        if tokens[j] == "(":
                            depth += 1
                            if (
                                depth == 2
                                and j + 1 < n
                                and isinstance(tokens[j + 1], tuple)
                            ):
                                field = tokens[j + 1][1]
                                if (
                                    field == "name"
                                    and j + 2 < n
                                    and isinstance(tokens[j + 2], tuple)
                                    and tokens[j + 2][0] == "atom"
                                ):
                                    tests.add(tokens[j + 2][1])
                                elif field == "modules":
                                    # collect atoms inside (modules ...)
                                    k = j + 2
                                    modules_depth = 1
                                    while k < n and modules_depth > 0:
                                        if tokens[k] == "(":
                                            modules_depth += 1
                                        elif tokens[k] == ")":
                                            modules_depth -= 1
                                            if modules_depth == 0:
                                                break
                                        elif (
                                            isinstance(tokens[k], tuple)
                                            and tokens[k][0] == "atom"
                                        ):
                                            tests.add(tokens[k][1])
                                        k += 1
                                    j = k
                                    continue
                        elif tokens[j] == ")":
                            depth -= 1
                        j += 1
        i += 1

    return tests


def extract_includes(tokens):
    """Extract (include path) references from tokenized content."""
    includes = []
    i = 0
    n = len(tokens)
    while i < n:
        if (
            tokens[i] == "("
            and i + 1 < n
            and isinstance(tokens[i + 1], tuple)
            and tokens[i + 1][1] == "include"
            and i + 2 < n
            and isinstance(tokens[i + 2], tuple)
            and tokens[i + 2][0] in ("atom", "string")
        ):
            includes.append(tokens[i + 2][1])
        i += 1
    return includes


def main():
    repo_root = Path(".").resolve()
    test_dir = repo_root / "test"

    if not test_dir.exists():
        print("error: test/ directory not found", file=sys.stderr)
        return 1

    # 1. Discover all test_*.ml source files
    ml_files = sorted(test_dir.rglob("test_*.ml"))
    ml_names = {f.stem for f in ml_files}

    # 2. Parse all dune and .inc files under test/
    registered = set()
    files_to_parse = []
    files_to_parse.extend(sorted(test_dir.rglob("dune")))
    files_to_parse.extend(sorted(test_dir.rglob("*.inc")))

    # Also resolve includes that point outside test/ (unlikely, but handle)
    parsed_paths = set()
    pending = list(files_to_parse)

    while pending:
        path = pending.pop()
        if path in parsed_paths:
            continue
        parsed_paths.add(path)

        if not path.exists():
            continue

        content = path.read_text()
        tokens = tokenize(content)
        registered.update(extract_test_names(tokens))

        # Queue included files relative to the current file's directory
        for inc in extract_includes(tokens):
            inc_path = path.parent / inc
            if inc_path.exists() and inc_path not in parsed_paths:
                pending.append(inc_path)

    # 3. Compare
    unregistered = sorted(ml_names - registered)
    # Only flag orphaned registrations that look like test files
    orphaned = sorted({r for r in (registered - ml_names) if r.startswith("test_")})

    print(f"test_*.ml files found:    {len(ml_names)}")
    print(f"Registered in dune/.inc:  {len(registered)}")
    print(f"Unregistered:             {len(unregistered)}")
    print(f"Orphaned registrations:   {len(orphaned)}")

    if unregistered:
        print("\nUnregistered test_*.ml files (no dune registration found):")
        for name in unregistered:
            print(f"  {name}")

    if orphaned:
        print("\nOrphaned registrations (registered but no .ml file):")
        for name in orphaned:
            print(f"  {name}")

    return 1 if unregistered else 0


if __name__ == "__main__":
    sys.exit(main())
