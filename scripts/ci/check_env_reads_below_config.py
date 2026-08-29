#!/usr/bin/env python3
"""Ratchet direct environment reads above the canonical config boundary.

The dependency floor and each library's exact implementation files come from
``dune describe``. Source matching ignores comments and strings, and the
baseline stores a count per file so a removed read cannot become quota for
another file. Counts stay stable when unrelated edits move an existing read.
"""

from __future__ import annotations

import json
import pathlib
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import TypeAlias

REPO = pathlib.Path(__file__).resolve().parents[2]
BASELINE = REPO / "scripts" / "env-read-baseline.json"
CONFIG_LIB = "masc.config"
DIRECT_ENV_READ = re.compile(r"\b(?:Stdlib\s*\.\s*)?Sys\s*\.\s*getenv(?:_opt)?\b")
CHARACTER_LITERAL = re.compile(r"'(?:\\(?:[0-9]{3}|x[0-9a-fA-F]{2}|.)|[^\\'])'")
QUOTED_STRING_START = re.compile(r"\{([a-z_]*)\|")
Sexp: TypeAlias = str | list["Sexp"]


@dataclass(frozen=True)
class Library:
    name: str
    uid: str
    local: bool
    requires: tuple[str, ...]
    implementations: tuple[str, ...]


def describe() -> str:
    result = subprocess.run(
        [
            "dune",
            "describe",
            "workspace",
            "--root",
            ".",
            "--format",
            "sexp",
            "--lang",
            "0.1",
        ],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"dune describe failed:\n{result.stderr[:2000]}")
    return result.stdout


def tokenize(text: str) -> list[str]:
    tokens: list[str] = []
    index = 0
    while index < len(text):
        character = text[index]
        if character in "()":
            tokens.append(character)
            index += 1
        elif character.isspace():
            index += 1
        elif character == '"':
            end = index + 1
            while end < len(text) and text[end] != '"':
                end += 2 if text[end] == "\\" else 1
            if end >= len(text):
                raise ValueError("unterminated quoted atom in describe output")
            tokens.append(text[index : end + 1])
            index = end + 1
        else:
            end = index
            while end < len(text) and not text[end].isspace() and text[end] not in "()":
                end += 1
            tokens.append(text[index:end])
            index = end
    return tokens


def parse(tokens: list[str]) -> list[Sexp]:
    position = 0

    def walk() -> Sexp:
        nonlocal position
        if position >= len(tokens):
            raise ValueError("unexpected end of describe output")
        token = tokens[position]
        if token == "(":
            position += 1
            node: list[Sexp] = []
            while position < len(tokens) and tokens[position] != ")":
                node.append(walk())
            if position >= len(tokens):
                raise ValueError("unbalanced describe output: missing ')'")
            position += 1
            return node
        if token == ")":
            raise ValueError("unbalanced describe output: unexpected ')'")
        position += 1
        return token

    parsed: list[Sexp] = []
    while position < len(tokens):
        parsed.append(walk())
    return parsed


def required_field(record: list[Sexp], key: str) -> Sexp:
    matches = [
        child
        for child in record
        if isinstance(child, list) and child and child[0] == key
    ]
    if len(matches) != 1 or len(matches[0]) != 2:
        raise ValueError(f"library requires one single-valued {key!r} field")
    return matches[0][1]


def optional_field(record: list[Sexp], key: str) -> Sexp | None:
    matches = [
        child
        for child in record
        if isinstance(child, list) and child and child[0] == key
    ]
    if not matches:
        return None
    if len(matches) != 1 or len(matches[0]) != 2:
        raise ValueError(f"record has malformed {key!r} field")
    return matches[0][1]


def module_implementations(value: Sexp, library_name: str) -> tuple[str, ...]:
    if not isinstance(value, list):
        raise ValueError(f"library {library_name!r} has malformed modules field")
    paths: list[str] = []
    for module in value:
        if not isinstance(module, list):
            raise ValueError(f"library {library_name!r} has malformed module record")
        implementation = optional_field(module, "impl")
        if implementation is None or implementation == []:
            continue
        if (
            not isinstance(implementation, list)
            or len(implementation) != 1
            or not isinstance(implementation[0], str)
        ):
            raise ValueError(
                f"library {library_name!r} has malformed module implementation"
            )
        paths.append(implementation[0])
    return tuple(paths)


def decode_workspace(text: str) -> tuple[list[Library], str]:
    parsed = parse(tokenize(text))
    tree: Sexp = parsed[0] if len(parsed) == 1 else parsed
    libraries: list[Library] = []
    contexts: list[str] = []

    def visit(node: Sexp) -> None:
        if not isinstance(node, list):
            return
        if len(node) == 2 and node[0] == "build_context":
            if not isinstance(node[1], str):
                raise ValueError("build_context must be an atom")
            contexts.append(node[1])
        if node and node[0] == "library":
            if len(node) != 2 or not isinstance(node[1], list):
                raise ValueError("malformed library variant in describe output")
            record = node[1]
            name = required_field(record, "name")
            uid = required_field(record, "uid")
            local = required_field(record, "local")
            requires = required_field(record, "requires")
            modules = required_field(record, "modules")
            if not isinstance(name, str) or not isinstance(uid, str):
                raise ValueError("library name and uid must be atoms")
            if not isinstance(local, str) or local not in ("true", "false"):
                raise ValueError(f"library {name!r} has malformed local field")
            if not isinstance(requires, list) or not all(
                isinstance(dependency, str) for dependency in requires
            ):
                raise ValueError(f"library {name!r} has malformed requires field")
            require_uids = tuple(
                dependency for dependency in requires if isinstance(dependency, str)
            )
            libraries.append(
                Library(
                    name=name,
                    uid=uid,
                    local=local == "true",
                    requires=require_uids,
                    implementations=module_implementations(modules, name),
                )
            )
        for child in node:
            visit(child)

    visit(tree)
    by_uid: dict[str, Library] = {}
    for library in libraries:
        if library.uid in by_uid:
            raise ValueError(f"duplicate library uid {library.uid!r}")
        by_uid[library.uid] = library
    dangling = sorted(
        (library.name, dependency)
        for library in libraries
        for dependency in library.requires
        if dependency not in by_uid
    )
    if dangling:
        rendered = ", ".join(
            f"{name} -> {dependency}" for name, dependency in dangling[:8]
        )
        suffix = " ..." if len(dangling) > 8 else ""
        raise ValueError(
            f"describe graph has dangling requires UIDs: {rendered}{suffix}"
        )
    unique_contexts = sorted(set(contexts))
    if len(unique_contexts) != 1:
        raise ValueError(
            f"expected one build_context, found {len(unique_contexts)}: "
            f"{unique_contexts}"
        )
    return libraries, unique_contexts[0]


def config_floor(libraries: list[Library]) -> set[str]:
    by_name = {library.name: library for library in libraries}
    by_uid = {library.uid: library for library in libraries}
    config = by_name.get(CONFIG_LIB)
    if config is None or not config.local:
        raise ValueError(f"local library {CONFIG_LIB!r} not found")
    seen: set[str] = set()
    stack = list(config.requires)
    while stack:
        uid = stack.pop()
        if uid in seen:
            continue
        seen.add(uid)
        dependency = by_uid.get(uid)
        if dependency is not None:
            stack.extend(dependency.requires)
    return {
        library.name
        for uid in seen
        if (library := by_uid.get(uid)) is not None and library.local
    }


def libraries_above_floor(libraries: list[Library], floor: set[str]) -> set[str]:
    return {
        library.name
        for library in libraries
        if library.local and library.name != CONFIG_LIB and library.name not in floor
    }


def source_path(build_path: str, build_context: str) -> pathlib.Path | None:
    path = pathlib.PurePosixPath(build_path)
    context = pathlib.PurePosixPath(build_context)
    try:
        relative = path.relative_to(context)
    except ValueError as error:
        raise ValueError(
            f"local implementation {build_path!r} is outside {build_context!r}"
        ) from error
    if ".." in relative.parts:
        raise ValueError(f"local implementation {build_path!r} is not normalized")
    candidate = REPO.joinpath(*relative.parts)
    return candidate if candidate.is_file() else None


def is_production_source(path: pathlib.Path) -> bool:
    relative = path.relative_to(REPO)
    parts = relative.parts
    if not parts or path.suffix != ".ml":
        return False
    if parts[0] == "lib":
        return True
    return len(parts) >= 4 and parts[0] == "packages" and parts[2] == "lib"


def implementation_files(
    libraries: list[Library], names: set[str], build_context: str
) -> set[pathlib.Path]:
    files: set[pathlib.Path] = set()
    for library in libraries:
        if library.name not in names:
            continue
        for implementation in library.implementations:
            path = source_path(implementation, build_context)
            if path is not None and is_production_source(path):
                files.add(path)
    return files


def mask_ocaml_non_code(text: str) -> str:
    """Replace comments and strings with spaces while preserving newlines."""
    masked = list(text)

    def blank(start: int, end: int) -> None:
        for offset in range(start, end):
            if masked[offset] != "\n":
                masked[offset] = " "

    index = 0
    while index < len(text):
        if text.startswith("(*", index):
            start = index
            depth = 1
            index += 2
            while index < len(text) and depth:
                if text.startswith("(*", index):
                    depth += 1
                    index += 2
                elif text.startswith("*)", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            if depth:
                raise ValueError("unterminated OCaml comment")
            blank(start, index)
            continue
        character = CHARACTER_LITERAL.match(text, index)
        if character is not None:
            start = index
            index = character.end()
            blank(start, index)
            continue
        if text[index] == '"':
            start = index
            index += 1
            while index < len(text):
                if text[index] == "\\":
                    index += 2
                elif text[index] == '"':
                    index += 1
                    break
                else:
                    index += 1
            else:
                raise ValueError("unterminated OCaml string")
            blank(start, min(index, len(text)))
            continue
        quoted = QUOTED_STRING_START.match(text, index)
        if quoted is not None:
            start = index
            terminator = f"|{quoted.group(1)}}}"
            index = quoted.end()
            end = text.find(terminator, index)
            if end < 0:
                raise ValueError("unterminated OCaml quoted string")
            index = end + len(terminator)
            blank(start, index)
            continue
        index += 1
    return "".join(masked)


def read_counts(paths: set[pathlib.Path]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for path in sorted(paths):
        text = path.read_text(encoding="utf-8")
        code = mask_ocaml_non_code(text)
        count = sum(1 for _ in DIRECT_ENV_READ.finditer(code))
        if count:
            counts[path.relative_to(REPO).as_posix()] = count
    return counts


def load_baseline(path: pathlib.Path) -> dict[str, int]:
    data = json.loads(path.read_text(encoding="utf-8"))
    counts = data.get("direct_env_read_counts_above_config_floor")
    if not isinstance(counts, dict):
        raise ValueError("baseline requires direct_env_read_counts_above_config_floor")
    decoded: dict[str, int] = {}
    for source, count in counts.items():
        if not isinstance(source, str) or type(count) is not int or count <= 0:
            raise ValueError(f"malformed baseline entry for {source!r}")
        decoded[source] = count
    return decoded


def write_baseline(path: pathlib.Path, counts: dict[str, int]) -> None:
    data = {
        "_comment": (
            "Per-file counts of syntax-aware direct Sys.getenv/Sys.getenv_opt "
            "sites in production implementations above masc.config's dependency "
            "floor. Regenerate with scripts/ci/check_env_reads_below_config.py "
            "--write-baseline."
        ),
        "_issue": "#29353",
        "direct_env_read_counts_above_config_floor": counts,
    }
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def site_diff(
    current: dict[str, int], baseline: dict[str, int]
) -> tuple[list[str], list[str], list[str]]:
    added = sorted(set(current) - set(baseline))
    removed = sorted(set(baseline) - set(current))
    changed = sorted(
        path for path in set(current) & set(baseline) if current[path] != baseline[path]
    )
    return added, removed, changed


def collect() -> tuple[set[str], dict[str, int], dict[str, int]]:
    libraries, build_context = decode_workspace(describe())
    floor = config_floor(libraries)
    above = libraries_above_floor(libraries, floor)
    floor_files = implementation_files(libraries, floor, build_context)
    above_files = implementation_files(libraries, above, build_context)
    overlap = floor_files & above_files
    if overlap:
        rendered = ", ".join(
            path.relative_to(REPO).as_posix() for path in sorted(overlap)
        )
        raise ValueError(
            f"implementation files owned both above and below floor: {rendered}"
        )
    return floor, read_counts(floor_files), read_counts(above_files)


def main(write: bool = False) -> int:
    print("=== direct env reads above the config floor ===")
    try:
        floor, below_counts, above_counts = collect()
        if write:
            write_baseline(BASELINE, above_counts)
            print(f"WROTE: {BASELINE.relative_to(REPO)}")
            return 0
        baseline = load_baseline(BASELINE)
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 2

    below_count = sum(below_counts.values())
    above_count = sum(above_counts.values())
    print(f"  config floor: {len(floor)} local librar(ies), {below_count} site(s)")
    print(f"  above:        {len(above_counts)} file(s), {above_count} site(s)")
    if above_counts != baseline:
        added, removed, changed = site_diff(above_counts, baseline)
        print("\nFAIL: direct environment read sites differ from the baseline.")
        for label, paths in (
            ("added", added),
            ("removed", removed),
            ("changed", changed),
        ):
            if paths:
                print(f"  {label}: {', '.join(paths)}")
        print(
            "      Route new reads through Env_config_core, then regenerate "
            "the baseline with --write-baseline.\n"
            "      A library that depends on masc.config nowhere by design "
            "cannot: a standalone deployed binary, or a package whose "
            "boundary the config layer sits outside of. Say so in a comment "
            "at the read and record the site instead."
        )
        return 1
    print(f"\nPASS: {above_count} direct environment read site(s) match baseline.")
    return 0


def self_test() -> int:
    fixture = """
((build_context _build/default)
 (library
  ((modules (((impl (_build/default/lib/config/env_config_core.ml)))
             ((name Interface_only))))
   (requires (core_uid external_uid))
   (local true)
   (uid config_uid)
   (name masc.config)))
 (library
  ((uid core_uid) (name masc.core) (requires ()) (local true)
   (modules (((name Core) (impl (_build/default/lib/core.ml)))))))
 (library
  ((name external.lib) (uid external_uid) (local false) (requires ())
   (modules ())))
 (library
  ((name masc.app) (local true) (requires (config_uid)) (uid app_uid)
   (modules (((name Nested)
              (impl (_build/default/lib/keeper/nested.ml))))))))
"""
    libraries, context = decode_workspace(fixture)
    floor = config_floor(libraries)
    assert context == "_build/default"
    assert floor == {"masc.core"}, floor
    assert libraries_above_floor(libraries, floor) == {"masc.app"}
    app = next(library for library in libraries if library.name == "masc.app")
    assert app.implementations == ("_build/default/lib/keeper/nested.ml",)

    source = """
let one = Sys.getenv "ONE"
(* Sys.getenv_opt "COMMENT" (* Sys.getenv "NESTED" *) *)
let two = Stdlib.Sys.getenv_opt "TWO"
let text = "Sys.getenv COMMENT"
let quoted = {tag|Sys.getenv_opt COMMENT|tag}
"""
    matches = list(DIRECT_ENV_READ.finditer(mask_ocaml_non_code(source)))
    assert len(matches) == 2, matches
    assert [source.count("\n", 0, match.start()) + 1 for match in matches] == [2, 4]
    assert site_diff(
        {"added.ml": 1, "changed.ml": 4},
        {"removed.ml": 2, "changed.ml": 3},
    ) == (["added.ml"], ["removed.ml"], ["changed.ml"])
    shifted_matches = list(
        DIRECT_ENV_READ.finditer(mask_ocaml_non_code("\n\n" + source))
    )
    assert len(shifted_matches) == len(matches)
    with tempfile.TemporaryDirectory() as temporary_directory:
        baseline_path = pathlib.Path(temporary_directory) / "baseline.json"

        def write_test_baseline(count: object) -> None:
            baseline_path.write_text(
                json.dumps(
                    {"direct_env_read_counts_above_config_floor": {"app.ml": count}}
                ),
                encoding="utf-8",
            )

        write_test_baseline(2)
        assert load_baseline(baseline_path) == {"app.ml": 2}
        for malformed_count in (True, [], 0, -1, 1.5):
            write_test_baseline(malformed_count)
            try:
                load_baseline(baseline_path)
            except ValueError:
                pass
            else:
                raise AssertionError(
                    f"malformed baseline count accepted: {malformed_count!r}"
                )
    print("PASS: env-read config-floor self-test")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    if sys.argv[1:] == ["--write-baseline"]:
        sys.exit(main(write=True))
    if sys.argv[1:]:
        sys.exit(
            "usage: check_env_reads_below_config.py [--self-test|--write-baseline]"
        )
    sys.exit(main())
