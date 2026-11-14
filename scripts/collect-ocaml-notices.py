#!/usr/bin/env python3
"""Collect the notice files of every opam package linked into release executables.

The package set comes from dune's link rule for each executable, not from
masc.opam: every External file the rule reads was installed by one opam
package, and ocamlopt also links its standard library and runtime without the
rule naming them.

A path is a notice when one of its components is named like one, so both
LICENSE.md and LICENSES/MIT.txt are. Each linked package's notices are copied
byte for byte from two places:

- its exact source (`opam source <name>.<version>`). A notice at the top of
  the tree ships. A notice deeper in the tree belongs either to code the
  upstream vendored into the library or to a tool, test or manual beside it,
  so NESTED_NOTICES says which for that exact version; a nested notice it
  does not cover stops the collection.
- the files it installed as doc/<dir>/<notice>. A dune-built package installs
  only LICENSE* there by itself, so COPYING, NOTICE and AUTHORS come from the
  source. Every other installed file is a copy of a source file.

A linked package with no notice stops the collection unless NO_UPSTREAM_NOTICE
names that exact version.

The output is OUT/<package>/<path> and OUT/packages.json. The runtime
packagers ship that directory as licenses/ocaml/ in masc-runtime-<platform>.

Run it from the repository root, inside the opam environment that built the
executables, after `dune build --release` of the same targets. Libraries built
from this checkout count as MASC's own code. Release builds see only tracked
files, so the gitignored vendor/ copies are never among them.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from collections.abc import Callable, Iterator, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import TypeAlias, cast

SCHEMA = "masc.ocaml-notices.v1"
MANIFEST = "packages.json"
FROM_SOURCE = "source"
# opam colours its output even through a pipe when OPAMCOLOR=always, as the
# GitHub macOS runners set it; the listings are parsed, so every opam call says
# --color=never.
NO_COLOR = "--color=never"

# opam metadata has no field that names a license file, so upstream file names
# are the only signal. The dylib notices in package-macos-runtime.py use the
# same names. Compared on the upper-cased path component.
NOTICE_PREFIXES = ("LICENSE", "LICENCE", "COPYING", "NOTICE", "COPYRIGHT", "AUTHORS")

# scripts/install.sh refuses a runtime archive member outside this alphabet.
SHIPPABLE_COMPONENT = r"[A-Za-z0-9_.+-]+"
SHIPPABLE_NAME = re.compile(SHIPPABLE_COMPONENT)
SHIPPABLE_PATH = re.compile(rf"{SHIPPABLE_COMPONENT}(?:/{SHIPPABLE_COMPONENT})*")

# Exact versions whose installed files and source hold no notice file, read on
# 2026-11-14 from `opam source` of each version. A version that gains a notice
# file fails the collection until its entry is removed here.
NO_UPSTREAM_NOTICE: Mapping[tuple[str, str], str] = {
    ("ambient-context", "0.2"): "the 0.2 release archive has no license or notice file",
    ("ambient-context-eio", "0.2"): "the 0.2 release archive has no license or notice file",
    ("opentelemetry", "0.13"): "the 0.13 release archive has no license or notice file",
    ("zstd", "0.4"): "the 0.4 release archive has no license or notice file",
    ("mcp_protocol", "1.3.0"): "jeong-sik/mcp-protocol-sdk v1.3.0 has no license file",
    ("ws-direct-core", "0.2.0"): "jeong-sik/ws-direct d812d6f has no license file",
    ("ws-direct-eio", "0.2.0"): "jeong-sik/ws-direct d812d6f has no license file",
    ("ws-direct-gluten", "0.2.0"): "jeong-sik/ws-direct d812d6f has no license file",
}


@dataclass(frozen=True, slots=True)
class Ship:
    """The nested notice covers code built into a linked archive."""

    why: str


@dataclass(frozen=True, slots=True)
class Exclude:
    """Every notice below this directory covers code no linked archive holds."""

    why: str


# Notices below the top of a linked package's source, read on 2026-11-14 from
# the versions in the local 5.5.2 switch and in masc.opam.locked. Which code is
# linked was read from the archives `dune rules` names. An entry covers the
# notices at or below its path, so the Ship entries name single files and the
# Exclude entries whole directories.
NestedRules: TypeAlias = "Mapping[str, Ship | Exclude]"
ATDGEN_RUNTIME: NestedRules = {
    "atdj": Exclude("the atdj tool; the library is built from atdgen-runtime/"),
    "atds": Exclude("the atds tool; the library is built from atdgen-runtime/"),
}
DECOMPRESS: NestedRules = {"test": Exclude("test data")}
DUNE_BUILD_INFO: NestedRules = {
    "doc": Exclude("dune's manual"),
    "src": Exclude("dune's own sources; the library is built from otherlibs/build-info/"),
    "test": Exclude("dune's tests"),
    "vendor": Exclude("libraries vendored into the dune binary; the library is built from otherlibs/build-info/"),
}
H2: NestedRules = {"hpack/test": Exclude("test data"), "lib_test": Exclude("test data")}
MENHIR_LIB: NestedRules = {
    "coq-menhirlib": Exclude("the Coq library; menhirLib is built from lib/"),
    "fix": Exclude("a library of the menhir generator; menhirLib is built from lib/"),
    "pprint": Exclude("a library of the menhir generator; menhirLib is built from lib/"),
}
PIAF: NestedRules = {"vendor/multipart_form/LICENSE.md": Ship(
    "vendor/multipart_form builds the linked lib/piaf/multipart_form/piaf_multipart_form.cmxa")}
PPXLIB: NestedRules = {"bench": Exclude("benchmarks")}
YAML: NestedRules = {
    "vendor/License": Ship("libyaml's C sources in vendor/ build the linked lib/yaml/c/libyaml_c_stubs.a")}

# Keyed by exact version, like NO_UPSTREAM_NOTICE: whether a directory stays
# outside the linked archives is a fact about one version, and macOS release
# builds install unlocked versions that differ from the Linux ones. A version
# with no entry here stops the collection on its first nested notice, and an
# entry naming a path that version lacks stops it too.
NESTED_NOTICES: Mapping[tuple[str, str], NestedRules] = {
    ("atdgen-runtime", "4.2.0"): ATDGEN_RUNTIME,
    ("decompress", "1.5.3"): DECOMPRESS,
    ("decompress", "1.6.1"): DECOMPRESS,
    ("dune-build-info", "3.22.2"): DUNE_BUILD_INFO,
    ("dune-build-info", "3.24.2"): DUNE_BUILD_INFO,
    ("h2", "0.13.0"): H2,
    ("h2-eio", "0.13.0"): H2,
    ("menhirLib", "20250912"): MENHIR_LIB,
    ("piaf", "0.2.0"): PIAF,
    ("ppxlib", "0.38.0"): PPXLIB,
    ("ppxlib", "0.39.0"): PPXLIB,
    ("yaml", "3.2.0"): YAML,
}


@dataclass(frozen=True, slots=True)
class Refused:
    """Why the collection stopped. Every reason found is kept, not only the first."""

    reasons: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Linked:
    name: str
    version: str
    # opam's source-hash: the commit a pinned package was built from.
    source_hash: str | None


@dataclass(frozen=True, slots=True)
class Found:
    ships_as: PurePosixPath
    data: bytes
    found_in: str


@dataclass(frozen=True, slots=True)
class Excluded:
    path: str
    why: str


@dataclass(frozen=True, slots=True)
class Notice:
    path: str
    data: bytes
    found_in: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Shipped:
    notices: tuple[Notice, ...]


@dataclass(frozen=True, slots=True)
class NoUpstreamNotice:
    reason: str


@dataclass(frozen=True, slots=True)
class Accounted:
    package: Linked
    outcome: Shipped | NoUpstreamNotice
    excluded: tuple[Excluded, ...]


Run: TypeAlias = Callable[[Sequence[str]], "str | Refused"]
NestedNotices: TypeAlias = Mapping[tuple[str, str], NestedRules]


def run_command(argv: Sequence[str]) -> str | Refused:
    completed = subprocess.run(list(argv), capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        return Refused((f"`{' '.join(argv)}` exited {completed.returncode}: {completed.stderr.strip()}",))
    return completed.stdout


def is_notice(name: str) -> bool:
    return name.upper().startswith(NOTICE_PREFIXES)


def notice_depth(parts: Sequence[str]) -> int | None:
    """Index of the first path component named like a notice."""
    return next((index for index, part in enumerate(parts) if is_notice(part)), None)


def reasons_of(*values: object) -> tuple[str, ...]:
    return tuple(reason for value in values if isinstance(value, Refused) for reason in value.reasons)


def linked_externals(target: str, rules_json: str) -> tuple[str, ...] | Refused:
    """Files outside the workspace that dune's link rule for `target` reads."""
    rules: object = json.loads(rules_json)
    if not isinstance(rules, list) or len(cast(list[object], rules)) != 1:
        return Refused((f"dune rules {target}: expected exactly one rule",))
    rule = cast(list[object], rules)[0]
    deps = cast(dict[str, object], rule).get("deps") if isinstance(rule, dict) else None
    if not isinstance(deps, list):
        return Refused((f"dune rules {target}: the rule has no dependency list",))
    externals: list[str] = []
    for dep in cast(list[object], deps):
        match dep:
            case {"File": ["External", str() as path]}:
                externals.append(path)
            case {"File": ["In_build_dir" | "In_source_tree", str()]}:
                pass  # built from this checkout: MASC's own code
            case _:
                return Refused((f"dune rules {target}: unrecognised dependency {dep!r}",))
    if not externals:
        # A link rule reads at least the compiler; a copy or alias rule reads
        # only the build directory and would hide what the original links.
        return Refused((f"dune rules {target}: the rule reads no installed file, so it does not link "
                        "the executable; name the target dune links",))
    return tuple(externals)


def installed_versions(run: Run) -> dict[str, Linked] | Refused:
    listing = run(["opam", "list", NO_COLOR, "--installed", "--short", "--columns=name,version,source-hash"])
    if isinstance(listing, Refused):
        return listing
    versions: dict[str, Linked] = {}
    for line in listing.splitlines():
        match line.split():
            case [name, version]:
                versions[name] = Linked(name, version, None)
            case [name, version, source_hash]:
                versions[name] = Linked(name, version, source_hash)
            case _:
                return Refused((f"opam list: unreadable line {line!r}",))
    return versions


def owned_files(run: Run, packages: Sequence[str]) -> dict[str, tuple[str, ...]] | Refused:
    files: dict[str, tuple[str, ...]] = {}
    for name in packages:
        listing = run(["opam", "show", NO_COLOR, "--list-files", name])
        if isinstance(listing, Refused):
            return listing
        # The listing ends with an empty line.
        files[name] = tuple(line for line in listing.splitlines() if line)
    return files


def linked_packages(externals: set[str], files: Mapping[str, tuple[str, ...]]) -> list[str] | Refused:
    owners: dict[str, list[str]] = {}
    for name, paths in files.items():
        for path in paths:
            owners.setdefault(path, []).append(name)
    packages: set[str] = set()
    reasons: list[str] = []
    for path in sorted(externals):
        match owners.get(path, []):
            case [name]:
                packages.add(name)
            case []:
                reasons.append(f"{path} is linked, but no installed opam package owns it")
            case several:
                reasons.append(f"{path} is owned by several opam packages: {', '.join(several)}")
    return Refused(tuple(reasons)) if reasons else sorted(packages)


def read_notice(path: Path, ships_as: PurePosixPath, found_in: str) -> Found | Refused:
    if path.is_symlink() or not path.is_file():
        return Refused((f"{path} is named like a notice but is not a regular file",))
    return Found(ships_as, path.read_bytes(), found_in)


def is_directory(path: Path) -> bool:
    return path.is_dir() and not path.is_symlink()


def installed_notices(package: str, paths: Sequence[str], doc_dir: Path) -> list[Found] | Refused:
    found: list[Found] = []
    reasons: list[str] = []
    for text in paths:
        path = Path(text)
        if doc_dir not in path.parents:
            continue  # a copy of a source file, read from the source instead
        directory, *below = path.relative_to(doc_dir).parts
        depth = notice_depth(below)
        if depth is None or is_directory(path):
            continue
        place = f"doc/{path.relative_to(doc_dir).as_posix()}"
        if depth > 0:
            reasons.append(f"{package}: {place} is a notice inside a subdirectory of doc/{directory}/; "
                           "only notices at its top are read")
            continue
        match read_notice(path, PurePosixPath(*below), place):
            case Refused(more):
                reasons.extend(more)
            case Found() as notice:
                found.append(notice)
    return Refused(tuple(reasons)) if reasons else found


def tree(root: Path) -> Iterator[Path]:
    """Every entry below `root`, outside .git, without following symlinks."""
    for entry in sorted(root.iterdir()):
        if entry.name == ".git":
            continue
        yield entry
        if is_directory(entry):
            yield from tree(entry)


def classify(package: Linked, path: Path, relative: PurePosixPath, depth: int,
             covering: Sequence[tuple[PurePosixPath, Ship | Exclude]]) -> Found | Excluded | Refused:
    match depth, list(covering):
        case 0, []:
            return read_notice(path, relative, FROM_SOURCE)
        case 0, [(key, _), *_]:
            return Refused((f"NESTED_NOTICES for {package.name}.{package.version} names {key}, but {relative} "
                            "is at the top of the source and ships by itself; drop that path",))
        case _, []:
            return Refused((f"{package.name}.{package.version}: {relative} is a notice below the top of the "
                            "source; give NESTED_NOTICES a path for this version that ships or excludes it",))
        case _, [(_, Ship())]:
            return read_notice(path, relative, FROM_SOURCE)
        case _, [(_, Exclude(why))]:
            return Excluded(relative.as_posix(), why)
        case _, several:  # two or more entries
            paths = ", ".join(str(key) for key, _ in several)
            return Refused((f"{package.name}.{package.version}: {relative} is covered by several NESTED_NOTICES "
                            f"paths: {paths}",))


def source_notices(run: Run, package: Linked, scratch: Path,
                   nested_notices: NestedNotices) -> tuple[list[Found], list[Excluded]] | Refused:
    root = scratch / package.name
    fetched = run(["opam", "source", NO_COLOR, f"--dir={root}", f"{package.name}.{package.version}"])
    if isinstance(fetched, Refused):
        return fetched
    entries = {PurePosixPath(path): entry
               for path, entry in nested_notices.get((package.name, package.version), {}).items()}
    used: set[PurePosixPath] = set()
    found: list[Found] = []
    excluded: list[Excluded] = []
    reasons: list[str] = []
    for path in tree(root):
        relative = PurePosixPath(path.relative_to(root).as_posix())
        depth = notice_depth(relative.parts)
        if depth is None or is_directory(path):
            continue
        covering = [(key, entry) for key, entry in sorted(entries.items())
                    if key == relative or key in relative.parents]
        used.update(key for key, _ in covering)
        match classify(package, path, relative, depth, covering):
            case Found() as notice:
                found.append(notice)
            case Excluded() as entry:
                excluded.append(entry)
            case Refused(more):
                reasons.extend(more)
    reasons.extend(f"NESTED_NOTICES for {package.name}.{package.version} names {key}, which holds no notice "
                   "in that version; drop that path" for key in sorted(set(entries) - used))
    return Refused(tuple(reasons)) if reasons else (found, excluded)


def merge(package: str, found: Sequence[Found]) -> tuple[Notice, ...] | Refused:
    by_path: dict[str, tuple[bytes, list[str]]] = {}
    for notice in found:
        path = notice.ships_as.as_posix()
        if SHIPPABLE_PATH.fullmatch(path) is None:
            return Refused((f"{package}: notice {path!r} has a name the installer refuses",))
        seen = by_path.setdefault(path, (notice.data, []))
        if seen[0] != notice.data:
            return Refused((f"{package}: {path} differs between {seen[1][0]} and {notice.found_in}",))
        seen[1].append(notice.found_in)
    return tuple(Notice(path, data, tuple(places)) for path, (data, places) in sorted(by_path.items()))


def decide(package: Linked, notices: tuple[Notice, ...],
           no_upstream_notice: Mapping[tuple[str, str], str]) -> Shipped | NoUpstreamNotice | Refused:
    match notices, no_upstream_notice.get((package.name, package.version)):
        case (), None:
            return Refused((f"{package.name}.{package.version} is linked, but neither its installed files "
                            "nor its source hold a license or notice file",))
        case (), str() as reason:
            return NoUpstreamNotice(reason)
        case _, None:
            return Shipped(notices)
        case _, str():
            paths = ", ".join(notice.path for notice in notices)
            return Refused((f"NO_UPSTREAM_NOTICE names {package.name}.{package.version}, which has {paths}; "
                            "remove the entry",))


def account(package: Linked, files: tuple[str, ...], doc_dir: Path, run: Run, scratch: Path,
            no_upstream_notice: Mapping[tuple[str, str], str],
            nested_notices: NestedNotices) -> Accounted | Refused:
    if SHIPPABLE_NAME.fullmatch(package.name) is None:
        return Refused((f"package {package.name!r} has a name the installer refuses",))
    installed = installed_notices(package.name, files, doc_dir)
    source = source_notices(run, package, scratch, nested_notices)
    if isinstance(installed, Refused) or isinstance(source, Refused):
        return Refused(reasons_of(installed, source))
    from_source, excluded = source
    notices = merge(package.name, installed + from_source)
    outcome = notices if isinstance(notices, Refused) else decide(package, notices, no_upstream_notice)
    if isinstance(outcome, Refused):
        return outcome
    return Accounted(package, outcome, tuple(excluded))


def collect(targets: Sequence[str], run: Run, no_upstream_notice: Mapping[tuple[str, str], str],
            nested_notices: NestedNotices) -> list[Accounted] | Refused:
    externals: set[str] = set()
    for target in targets:
        rules = run(["dune", "rules", "--release", "--format=json", target])
        linked = rules if isinstance(rules, Refused) else linked_externals(target, rules)
        if isinstance(linked, Refused):
            return linked
        externals.update(linked)
    stdlib = run(["ocamlopt", "-where"])
    doc = run(["opam", "var", NO_COLOR, "doc"])
    versions = installed_versions(run)
    match stdlib, doc, versions:
        case str(), str(), dict():
            externals.add(str(Path(stdlib.strip()) / "stdlib.cmxa"))
            doc_dir = Path(doc.strip())
        case _:
            return Refused(reasons_of(stdlib, doc, versions))
    files = owned_files(run, sorted(versions))
    if isinstance(files, Refused):
        return files
    packages = linked_packages(externals, files)
    if isinstance(packages, Refused):
        return packages
    results: list[Accounted] = []
    reasons: list[str] = []
    with tempfile.TemporaryDirectory(prefix="masc-ocaml-sources-") as scratch:
        for name in packages:
            match account(versions[name], files[name], doc_dir, run, Path(scratch),
                          no_upstream_notice, nested_notices):
                case Refused(more):
                    reasons.extend(more)
                case Accounted() as accounted:
                    results.append(accounted)
    return Refused(tuple(reasons)) if reasons else results


def manifest_entry(entry: Accounted) -> dict[str, object]:
    package = entry.package
    record: dict[str, object] = {
        "name": package.name, "version": package.version, "source_hash": package.source_hash,
        "excluded": [{"path": excluded.path, "why": excluded.why} for excluded in entry.excluded]}
    match entry.outcome:
        case Shipped(notices):
            record["notices"] = [
                {"file": f"{package.name}/{notice.path}", "sha256": hashlib.sha256(notice.data).hexdigest(),
                 "found_in": list(notice.found_in)} for notice in notices]
        case NoUpstreamNotice(reason):
            record["notices"] = []
            record["no_upstream_notice"] = reason
    return record


def write(out: Path, targets: Sequence[str], packages: Sequence[Accounted]) -> None:
    out.mkdir(parents=True)
    for entry in packages:
        match entry.outcome:
            case Shipped(notices):
                for notice in notices:
                    path = out / entry.package.name / notice.path
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(notice.data)
                    path.chmod(0o644)
            case NoUpstreamNotice():
                pass  # recorded in the manifest only; there is no file to copy
    manifest = {"schema": SCHEMA, "executables": list(targets),
                "packages": [manifest_entry(entry) for entry in packages]}
    path = out / MANIFEST
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    path.chmod(0o644)


def produce(out: Path, targets: Sequence[str], run: Run, no_upstream_notice: Mapping[tuple[str, str], str],
            nested_notices: NestedNotices) -> list[Accounted] | Refused:
    """Write OUT only when every linked package is accounted for."""
    if out.exists():
        return Refused((f"{out} already exists",))
    result = collect(targets, run, no_upstream_notice, nested_notices)
    if not isinstance(result, Refused):
        write(out, targets, result)
    return result


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, required=True, help="new directory for the notices")
    parser.add_argument("targets", nargs="+", help="release executables as dune builds them, e.g. bin/main_eio.exe")
    args = parser.parse_args(argv)
    out = cast(Path, args.out)
    result = produce(out, cast(list[str], args.targets), run_command, NO_UPSTREAM_NOTICE, NESTED_NOTICES)
    if isinstance(result, Refused):
        for reason in result.reasons:
            print(f"collect-ocaml-notices: {reason}", file=sys.stderr)
        return 1
    shipped = [entry.outcome for entry in result if isinstance(entry.outcome, Shipped)]
    print(f"collect-ocaml-notices: {len(result)} linked opam packages, "
          f"{sum(len(outcome.notices) for outcome in shipped)} notice files, "
          f"{len(result) - len(shipped)} without an upstream notice, "
          f"{sum(len(entry.excluded) for entry in result)} nested notices excluded -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
