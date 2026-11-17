#!/usr/bin/env python3
"""Fail when a dune test stanza loads config/prompts without depending on it.

`Prompt_defaults.init` and `set_markdown_dir` (through `Prompt_registry` or
`Prompt_defaults`) read the markdown files under config/prompts at run time. Dune caches a test action by
its declared inputs, so a stanza that does not declare the directory returns a
cached pass after a prompt-only change (issue #33083).

The check parses every dune file and `.inc` under test/, finds each `test` or
`tests` stanza, and collects its modules plus the modules of test-local
libraries it links. When any of those modules calls one of the functions, the
stanza's `deps` field must contain the exact form below.

Executables are skipped: dune runs them only on request (`dune exec`), so no
cached result exists for them.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

REQUIRED_DEP = "(source_tree %{workspace_root}/config/prompts)"
LOADER_CALL = re.compile(r"\bPrompt_defaults\.init\b|\bset_markdown_dir\b")
TEST_KINDS = frozenset({"test", "tests"})



@dataclass(frozen=True, slots=True)
class Stanza:
    path: Path
    kind: str
    names: tuple[str, ...]
    modules: tuple[str, ...] | None  # None: no modules field, dune takes all
    libraries: tuple[str, ...]
    deps_text: str


def strip_comments(text: str) -> str:
    out: list[str] = []
    in_string = False
    i = 0
    while i < len(text):
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < len(text):
                out.append(text[i + 1])
                i += 1
            elif c == '"':
                in_string = False
        elif c == '"':
            in_string = True
            out.append(c)
        elif c == ";":
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        else:
            out.append(c)
        i += 1
    return "".join(out)


def top_forms(text: str) -> list[str]:
    forms: list[str] = []
    depth = 0
    start = 0
    for i, c in enumerate(text):
        if c == "(":
            if depth == 0:
                start = i
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                forms.append(text[start : i + 1])
    return forms


def field_forms(form: str) -> dict[str, str]:
    """Return each direct child field of a stanza keyed by its head atom."""
    fields: dict[str, str] = {}
    for child in top_forms(form[1:-1]):
        head = re.match(r"\(\s*([\w-]+)", child)
        if head is not None:
            fields[head.group(1)] = child
    return fields


def atoms(field: str | None) -> tuple[str, ...]:
    if field is None:
        return ()
    words = re.findall(r"[^\s()]+", field)
    return tuple(words[1:])


def parse_stanzas(path: Path) -> list[Stanza]:
    stanzas: list[Stanza] = []
    for form in top_forms(strip_comments(path.read_text())):
        head = re.match(r"\(\s*([\w-]+)", form)
        if head is None:
            continue
        fields = field_forms(form)
        names = atoms(fields.get("name")) + atoms(fields.get("names"))
        modules_field = fields.get("modules")
        stanzas.append(
            Stanza(
                path=path,
                kind=head.group(1),
                names=names,
                modules=None if modules_field is None else atoms(modules_field),
                libraries=atoms(fields.get("libraries")),
                deps_text=fields.get("deps", ""),
            )
        )
    return stanzas


def module_files(dune_dir: Path) -> dict[str, Path]:
    return {p.stem: p for p in dune_dir.glob("*.ml")}


def stanza_dir(stanza: Stanza) -> Path:
    # `.inc` files are included from test/dune; modules live next to that dune.
    return stanza.path.parent.parent if stanza.path.suffix == ".inc" else stanza.path.parent


def violations(test_root: Path) -> list[str]:
    files = sorted(test_root.rglob("dune")) + sorted(test_root.rglob("*.inc"))
    stanzas = [s for f in files for s in parse_stanzas(f)]
    found: list[str] = []
    callers: dict[Path, frozenset[str]] = {}
    for d in {stanza_dir(s) for s in stanzas}:
        callers[d] = frozenset(
            m for m, p in module_files(d).items() if LOADER_CALL.search(p.read_text())
        )
    local_libs: dict[tuple[Path, str], tuple[str, ...]] = {}
    for s in stanzas:
        if s.kind == "library" and s.modules is not None:
            for n in s.names:
                local_libs[(stanza_dir(s), n)] = s.modules
    for s in stanzas:
        if s.kind not in TEST_KINDS:
            continue
        d = stanza_dir(s)
        own = s.modules if s.modules is not None else tuple(module_files(d))
        linked = tuple(m for lib in s.libraries for m in local_libs.get((d, lib), ()))
        hits = sorted(set(own + linked) & callers[d])
        if hits and REQUIRED_DEP not in s.deps_text:
            found.append(f"{s.path}: {s.kind} {' '.join(s.names)} (modules: {', '.join(hits)})")
    return found


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    found = violations(root / "test")
    if found:
        print(
            "These test stanzas load config/prompts through Prompt_defaults but do not\n"
            f"declare it. Add `(deps {REQUIRED_DEP})`:",
            file=sys.stderr,
        )
        for line in found:
            print(f"  {line}", file=sys.stderr)
        return 1
    print("test prompt deps: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
