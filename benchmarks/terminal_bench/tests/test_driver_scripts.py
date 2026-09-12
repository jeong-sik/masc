"""A driver script must assign a variable before it expands one.

Every driver script runs under ``set -u``, where expanding an unset name ends
the script on that line. ``bootstrap.sh`` sourced its helper through ``$BENCH``
five lines above the ``BENCH=`` assignment, so every container bootstrap exited
there: nothing was installed and no MASC was started, silently, on every run.

Read rather than executed. These scripts install packages and start a server;
what can be held here is the order in which the file names its own variables.
"""
import re
from pathlib import Path

DRIVER = Path(__file__).resolve().parents[1] / "driver"

ASSIGN = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=")
# $NAME and ${NAME}, but not ${NAME:-default} and its relatives: those name a
# value to use when the variable is unset, which is what makes them safe under
# set -u and is why the script writes them that way.
EXPAND = re.compile(
    r"\$\{([A-Za-z_][A-Za-z0-9_]*)([^A-Za-z0-9_}]?)|\$([A-Za-z_][A-Za-z0-9_]*)"
)


def expansions(line):
    for match in EXPAND.finditer(line):
        braced, suffix, bare = match.group(1), match.group(2), match.group(3)
        if bare:
            yield bare
        elif braced and suffix in ("", "}"):
            yield braced
# A function's own names live and die inside it, so where they sit relative to
# each other in the file says nothing. Only the script's top-level names are
# ordered by the reader.
SCOPED = re.compile(r"^\s*(?:local|declare|typeset)\s+(?:-[A-Za-z]+\s+)*(.*)$")
NAMES = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)")


def first_positions(text):
    assigned, expanded, scoped = {}, {}, set()
    for number, line in enumerate(text.splitlines(), start=1):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        scope = SCOPED.match(line)
        if scope:
            for declaration in scope.group(1).split():
                name = NAMES.match(declaration)
                if name:
                    scoped.add(name.group(1))
        for name in expansions(line):
            expanded.setdefault(name, number)
        match = ASSIGN.match(line)
        if match:
            assigned.setdefault(match.group(1), number)
    for name in scoped:
        assigned.pop(name, None)
    return assigned, expanded


def test_every_script_assigns_before_it_expands():
    scripts = sorted(DRIVER.glob("*.sh"))
    assert scripts, "no driver scripts found to check"
    for script in scripts:
        assigned, expanded = first_positions(script.read_text())
        for name, assigned_at in assigned.items():
            expanded_at = expanded.get(name)
            if expanded_at is None:
                continue
            assert expanded_at >= assigned_at, (
                f"{script.name}: ${name} is expanded on line {expanded_at}, "
                f"before the script assigns it on line {assigned_at}; under "
                f"set -u that ends the script there"
            )


def test_bootstrap_names_bench_before_sourcing_the_helper():
    text = (DRIVER / "bootstrap.sh").read_text()
    assigned, expanded = first_positions(text)
    assert "BENCH" in assigned, "bootstrap.sh no longer assigns BENCH"
    assert expanded["BENCH"] >= assigned["BENCH"]
