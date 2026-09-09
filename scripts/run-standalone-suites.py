#!/usr/bin/env python3
"""Build and run test suites with ocamlfind instead of dune.

This is a bounded runner for static OCaml library sources, not a replacement
for Dune rules or preprocessing. --generate explicitly enables the supported
embedded_config recipe; other generated modules still require Dune.
Wrapped units use their library namespace, and authored main modules and
interfaces remain unchanged. Dependency analysis determines the compile order;
its failure is reported as an unbuilt suite, never an invented test verdict.
C stubs are compiled separately in their owning library's staging directory.

Findlib packages are passed as declared. An archive-less package may aggregate
other packages; it does not identify a virtual implementation. Installed
Dune metadata supplies virtual/default-implementation declarations, and a
suite explicitly naming an implementation overrides that declared default.

DUNE_SOURCEROOT is set to the checkout being read, so a suite that reads source
files -- every Ast_grep structural guard does -- can be pointed at main and at a
branch with the same binary, which is how a baseline gets measured before an
expectation is changed.

Usage:
  scripts/run-standalone-suites.py --list
  scripts/run-standalone-suites.py test_tui_message_layout
  scripts/run-standalone-suites.py --all-matching 'test_tui_*'
  scripts/run-standalone-suites.py --source-root /path/to/other/checkout <name>
"""

from __future__ import annotations

import argparse
import fnmatch
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Library:
    name: str
    directory: str
    modules: tuple[str, ...]
    deps: tuple[str, ...]
    stubs: tuple[str, ...]
    c_library_flags: tuple[str, ...]
    wrapped: bool
    needs_dune: str | None = None


@dataclass
class Plan:
    suite: str
    libraries: list[Library] = field(default_factory=list)
    packages: list[str] = field(default_factory=list)
    link_flags: list[str] = field(default_factory=list)
    generated: dict[tuple[str, str], str] = field(default_factory=dict)


def strip_comments(text: str) -> str:
    """dune source with its `;` comments blanked out.

    A comment inside a field list is otherwise read as content: the words of
    `; masc_tui_message_layout owns the span ladder` join the libraries list,
    and a suite is then reported as needing `;`. A comment carrying an
    unbalanced paren also throws off the form reader below.
    """
    out: list[str] = []
    for line in text.splitlines(keepends=True):
        quoted = False
        cut = len(line)
        for index, char in enumerate(line):
            if char == '"':
                quoted = not quoted
            elif char == ";" and not quoted:
                cut = index
                break
        stripped = line[:cut]
        out.append(stripped if cut == len(line) else stripped + "\n")
    return "".join(out)


def balanced_form(text: str, start: int) -> str:
    """The parenthesised form beginning at [start], through its matching close."""
    depth = 0
    end = start
    while end < len(text):
        if text[end] == "(":
            depth += 1
        elif text[end] == ")":
            depth -= 1
            if depth == 0:
                break
        end += 1
    return text[start : end + 1]


def sexp_forms(text: str, head: str):
    """Every parenthesised form in [text] starting with [head], balanced.

    Written out rather than matched with a regex because these stanzas close
    inline -- `  masc_tui_message_layout))` -- so a pattern anchored on a
    closing paren at column zero silently finds none of them.
    """
    index = 0
    while True:
        index = text.find(head, index)
        if index < 0:
            return
        form = balanced_form(text, index)
        yield form
        index += len(form)


# `(libraries (re_export piaf) unix)` -- a library can be listed inside a
# nested form. The marker names no library of its own; what it wraps does.
NESTED_LIBRARY_MARKERS = ("re_export",)


def field_words(form: str, name: str) -> list[str] | None:
    """The words of `(name ...)` in [form], read to its matching paren.

    Anchored on whitespace after the field name so `(modules ...)` does not
    match `(modules_without_implementation ...)`, and balanced rather than
    stopped at the first `)`: reading to the first one truncates a field whose
    value nests, so `(libraries (re_export piaf) unix)` yields `(re_export
    piaf` and loses `unix` entirely.
    """
    head = re.search(rf"\({re.escape(name)}s?\s", form)
    if head is None:
        return None
    field = balanced_form(form, head.start())
    body = field[head.end() - head.start() : -1]
    words = body.replace("(", " ").replace(")", " ").split()
    return [word for word in words if word not in NESTED_LIBRARY_MARKERS]


def modules_in(root: str, directory: str) -> list[str]:
    """Every module in [directory], the set dune takes when (modules) is absent."""
    paths = glob.glob(os.path.join(root, directory, "*.ml"))
    paths += glob.glob(os.path.join(root, directory, "*.mli"))
    return sorted({os.path.splitext(os.path.basename(path))[0] for path in paths})


def source_contract_reason(form: str, directory_text: str) -> str | None:
    # These declarations alter source identity, visibility or compilation.
    # Warning-only flags are intentionally left to Dune's warning checks.
    for feature in ("preprocess", "virtual_modules", "implements", "root_module",
                    "private_modules", "ocamlc_flags", "ocamlopt_flags",
                    "foreign_archives", "library_flags"):
        if field_words(form, feature) is not None:
            return f"{feature} requires Dune"
    subdirs = field_words(directory_text, "include_subdirs")
    if subdirs not in (None, ["no"]):
        return "include_subdirs requires Dune"
    stub_form = next(sexp_forms(form, "(foreign_stubs"), None)
    if stub_form is not None:
        if field_words(stub_form, "language") not in (None, ["c"]):
            return "foreign_stubs language requires Dune"
        for feature in ("flags", "include_dirs", "extra_deps", "mode"):
            if field_words(stub_form, feature) is not None:
                return f"foreign_stubs {feature} require Dune"
        if any(not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", name)
               for name in (field_words(stub_form, "name") or [])):
            return "foreign_stubs name expression requires Dune"
    flags = field_words(form, "flags") or []
    index = 0
    while index < len(flags):
        if flags[index] == ":standard":
            index += 1
        elif flags[index] in ("-w", "-warn-error") and index + 1 < len(flags):
            index += 2
        else:
            return "compiler flags beyond warning settings require Dune"
    return None


def read_libraries(dune_path: str, directory: str, root_dir: str) -> dict[str, Library]:
    if not os.path.exists(dune_path):
        return {}
    with open(dune_path, encoding="utf-8") as source:
        text = strip_comments(source.read())
    out: dict[str, Library] = {}
    for form in sexp_forms(text, "(library"):
        names = field_words(form, "name")
        if not names:
            continue
        name = names[0]
        # Without a (modules) field a library takes every module in its
        # directory. Reading the directory rather than assuming the library's
        # own name matters for the wrapping rule below: shared_types has no
        # shared_types.ml, and calling it single-module would send the build
        # after a file that does not exist.
        modules = field_words(form, "module") or modules_in(root_dir, directory)
        deps = field_words(form, "librarie") or field_words(form, "libraries") or []
        # C stubs are compiled alongside the modules: ocamlfind takes .c
        # files on the same command line. Without them the suite reaches the
        # linker and dies on an undefined symbol, which looks like a verdict
        # and is not.
        stubs: list[str] = []
        stub_form = next(sexp_forms(form, "(foreign_stubs"), None)
        if stub_form is not None:
            stubs = field_words(stub_form, "name") or []
        # (c_library_flags (-lncurses)) -- the value is its own parenthesised
        # list, so the words arrive wearing its brackets.
        c_flags = [
            word.strip("()")
            for word in (field_words(form, "c_library_flag") or [])
            if word.strip("()")
        ]
        wrapping = field_words(form, "wrapped") or ["true"]
        unsupported = source_contract_reason(form, text)
        if wrapping not in (["true"], ["false"]):
            unsupported = "wrapped transition requires Dune"
        if any(not re.fullmatch(r"[A-Za-z][A-Za-z0-9_']*", m) for m in modules):
            unsupported = "module expression requires Dune"
        wrapped = wrapping == ["true"]
        library = Library(
            name,
            directory,
            tuple(modules),
            tuple(deps),
            tuple(stubs),
            tuple(c_flags),
            wrapped,
            unsupported,
        )
        out[name] = library
        # A consumer names a library by whichever of the two the author wrote,
        # so both reach the same stanza.
        public = field_words(form, "public_name")
        if public:
            out[public[0]] = library
    return out


@dataclass(frozen=True)
class Suite:
    libraries: list[str]
    # Why dune, and only dune, can run this one. None when nothing says so.
    needs_dune: str | None = None


def needs_dune_reason(form: str) -> str | None:
    """What in the stanza puts this suite out of reach here.

    Read off the stanza rather than off the suite's own complaint: both of
    these print `main_eio executable is unbound; run the test via Dune` and
    exit non-zero, which arrives as a red verdict on code that was never run.
    """
    if next(sexp_forms(form, "(enabled_if"), None) is not None:
        return "enabled_if: dune decides whether this suite runs at all"
    for word in field_words(form, "dep") or []:
        if word.endswith(".exe"):
            return f"deps on a built executable ({word})"
    return None


def read_suites(root: str) -> dict[str, Suite]:
    with open(os.path.join(root, "test/dune"), encoding="utf-8") as source:
        text = strip_comments(source.read())
    for included in sorted(glob.glob(os.path.join(root, "test/stanzas/*.inc"))):
        text += "\n" + strip_comments(open(included, encoding="utf-8").read())
    out: dict[str, Suite] = {}
    for form in sexp_forms(text, "(test"):
        names = field_words(form, "name")
        if not names:
            continue
        deps = field_words(form, "librarie") or field_words(form, "libraries") or []
        suite = Suite(deps, needs_dune_reason(form))
        for name in names:
            out[name] = suite
    return out


def collect_libraries(root: str) -> dict[str, Library]:
    libraries = read_libraries(os.path.join(root, "bin/dune"), "bin", root)
    libraries.update(read_libraries(os.path.join(root, "test_lib/dune"), "test_lib", root))
    # test/deps holds masc_test_deps, which 806 suites link. Left out, every
    # one of them was reported as blocked on a library this index had never
    # heard of, which says nothing about what to unblock first.
    libraries.update(read_libraries(os.path.join(root, "test/deps/dune"), "test/deps", root))
    # test/dune and its includes declare libraries of their own beside the
    # suites -- exact_output_fixture is one -- and their modules sit in test/.
    libraries.update(read_libraries(os.path.join(root, "test/dune"), "test", root))
    for included in sorted(glob.glob(os.path.join(root, "test/stanzas/*.inc"))):
        libraries.update(read_libraries(included, "test", root))
    # Index source libraries by both private and public names. Whether a
    # library needs Dune is determined from its stanza and source inventory.
    library_dunes = (
        sorted(glob.glob(os.path.join(root, "lib/**/dune"), recursive=True))
        + sorted(glob.glob(os.path.join(root, "packages/**/dune"), recursive=True))
        # proto/ holds masc_proto, which 319 suites link. Unread, they were
        # all blocked on a name the index did not carry, which reads as "the
        # library is missing" rather than what it is.
        + sorted(glob.glob(os.path.join(root, "proto/dune")))
    )
    for path in library_dunes:
        directory = os.path.relpath(os.path.dirname(path), root)
        for name, library in read_libraries(path, directory, root).items():
            libraries.setdefault(name, library)
    return libraries


@dataclass(frozen=True)
class PackageMetadata:
    virtual: bool
    default_implementation: str | None
    implements: str | None


def read_package_metadata(text: str, name: str) -> PackageMetadata | None:
    for form in sexp_forms(text, "(library"):
        if field_words(form, "name") != [name]:
            continue
        default = field_words(form, "default_implementation")
        implements = field_words(form, "implements")
        return PackageMetadata(field_words(form, "kind") == ["virtual"],
                               default[0] if default else None,
                               implements[0] if implements else None)
    return None


@dataclass(frozen=True)
class GenerationFailure:
    reason: str


class Resolver:
    def __init__(self, libraries: dict[str, Library], root: str, generate: bool = False):
        self.libraries = libraries
        self.root = root
        self.generate = generate
        # A generator is evaluated at most once per owner during this run.
        # Failures remain failures with their original diagnostic for every
        # suite that reaches the same source, instead of rerunning the tool.
        self._generation_results: dict[tuple[str, str], str | GenerationFailure] = {}
        self._findlib: dict[str, bool] = {}
        self.substitutions: dict[str, str] = {}
        self._metadata: dict[str, PackageMetadata | None] = {}

    def generate_module(self, library: Library, module: str) -> str | GenerationFailure:
        key = (library.name, module)
        # One supported recipe, matching lib/embedded_config/dune. This is
        # not a generic Dune action interpreter or a basename fallback.
        supported = library.name == "embedded_config" and module_name(module) == "Embedded_config"
        if not supported:
            return GenerationFailure("source absent; no supported generator (requires Dune)")
        if not self.generate:
            return GenerationFailure("source absent; pass --generate for the embedded_config recipe")
        if key not in self._generation_results:
            config = os.path.join(self.root, "config")
            if not os.path.isdir(config):
                result = GenerationFailure(f"generator input directory absent: {config}")
            else:
                try:
                    crunch = subprocess.run(
                        ["ocaml-crunch", "-m", "plain", config],
                        capture_output=True, text=True, check=False,
                    )
                    if crunch.returncode != 0:
                        diagnostic = crunch.stderr.strip() or "no stderr"
                        result = GenerationFailure(
                            f"ocaml-crunch exited {crunch.returncode}: {diagnostic}")
                    elif not crunch.stdout:
                        result = GenerationFailure("ocaml-crunch succeeded but produced no source")
                    else:
                        result = crunch.stdout
                except OSError as error:
                    result = GenerationFailure(f"ocaml-crunch could not start: {error}")
            self._generation_results[key] = result
        return self._generation_results[key]

    def installed(self, name: str) -> bool:
        if name not in self._findlib:
            probe = subprocess.run(
                ["ocamlfind", "query", name], capture_output=True, check=False
            )
            self._findlib[name] = probe.returncode == 0
        return self._findlib[name]

    def package_metadata(self, name: str) -> PackageMetadata | None:
        if name not in self._metadata:
            probe = subprocess.run(
                ["ocamlfind", "query", "-format", "%m", name],
                capture_output=True, text=True, check=False,
            )
            metadata = None
            if probe.returncode == 0:
                path = os.path.join(os.path.dirname(probe.stdout.strip()), "dune-package")
                if os.path.isfile(path):
                    with open(path, encoding="utf-8") as source:
                        metadata = read_package_metadata(source.read(), name)
            self._metadata[name] = metadata
        return self._metadata[name]

    def resolve_packages(self, packages: list[str]) -> list[str]:
        if not packages:
            return []
        probe = subprocess.run(
            ["ocamlfind", "query", "-recursive", "-predicates", "native", "-format", "%p"] + packages,
            capture_output=True, text=True, check=False,
        )
        if probe.returncode != 0:
            raise StagingError("findlib dependency query failed: " + probe.stderr.strip())
        closure = list(dict.fromkeys(probe.stdout.split() + packages))
        metadata = {name: self.package_metadata(name) for name in closure}
        selected: dict[str, str] = {}
        # Existing explicit implementations (including required packages) win
        # over defaults. Two implementations of one virtual library cannot be
        # linked into the same executable.
        for name, info in metadata.items():
            if info is not None and info.implements is not None:
                prior = selected.get(info.implements)
                if prior is not None and prior != name:
                    raise StagingError(f"conflicting implementations for {info.implements}: {prior}, {name}")
                selected[info.implements] = name
        for name, info in metadata.items():
            if info is None or not info.virtual:
                continue
            implementation = selected.get(name, info.default_implementation)
            if implementation is None:
                continue
            target = self.package_metadata(implementation)
            if target is None or target.implements != name:
                raise StagingError(f"invalid declared implementation {implementation} for {name}")
            selected[name] = implementation
        self.substitutions.update(selected)
        # Implementations precede clients whose META requires only the virtual
        # package. findlib then orders each implementation's own dependencies.
        return list(dict.fromkeys(list(selected.values()) + packages))

    def plan(self, suite: str, deps: list[str]) -> tuple[Plan | None, str | None]:
        ordered: list[Library] = []
        complete: set[str] = set()
        visiting: set[str] = set()
        packages: list[str] = []
        generated: dict[tuple[str, str], str] = {}
        blocker: str | None = None

        def visit(name: str) -> bool:
            nonlocal blocker
            library = self.libraries.get(name)
            if library is None:
                if not self.installed(name):
                    blocker = name
                    return False
                if name not in packages:
                    packages.append(name)
                return True
            key = library.name
            if key in complete:
                return True
            if key in visiting:
                blocker = f"library dependency cycle at {name}"
                return False
            if library.needs_dune:
                blocker = f"{name} ({library.needs_dune})"
                return False
            for module in library.modules:
                origin = source_stem(self.root, library, module)
                missing_embedded_implementation = (
                    library.name == "embedded_config"
                    and module_name(module) == "Embedded_config"
                    and (origin is None or not os.path.isfile(origin + ".ml"))
                )
                if origin is None or missing_embedded_implementation:
                    result = self.generate_module(library, module)
                    if isinstance(result, GenerationFailure):
                        blocker = f"{name}.{module}: {result.reason}"
                        return False
                    generated[(library.name, module)] = result
            visiting.add(key)
            for dependency in library.deps:
                if not visit(dependency):
                    return False
            visiting.remove(key)
            complete.add(key)
            ordered.append(library)
            return True

        for dependency in deps:
            if not visit(dependency):
                return None, blocker
        try:
            resolved = self.resolve_packages(packages)
        except (OSError, StagingError) as error:
            return None, str(error)
        plan = Plan(suite, libraries=ordered, packages=resolved, generated=generated)
        for library in ordered:
            for flag in library.c_library_flags:
                plan.link_flags += ["-cclib", flag]
        return plan, None


@dataclass(frozen=True)
class Outcome:
    """One suite's verdict. `built` is None when it never got as far as a
    verdict, which is a gap in this harness rather than a red test."""

    built: bool | None
    summary: str
    detail: str = ""


def module_name(name: str) -> str:
    return name[:1].upper() + name[1:]


def source_stem(root: str, library: Library, module: str) -> str | None:
    for stem in dict.fromkeys((module, module[:1].lower() + module[1:])):
        path = os.path.join(root, library.directory, stem)
        if os.path.isfile(path + ".ml") or os.path.isfile(path + ".mli"):
            return path
    return None


class StagingError(Exception):
    """No test verdict can be drawn from an invalid source/command plan."""


@dataclass(frozen=True)
class SourceGroup:
    directory: str
    sources: tuple[str, ...]
    stubs: tuple[str, ...] = ()
    alias: str | None = None
    opened: str | None = None


@dataclass(frozen=True)
class StagedPlan:
    groups: tuple[SourceGroup, ...]
    packages: tuple[str, ...]
    link_flags: tuple[str, ...]
    executable: str


def stage_plan(plan: Plan, root: str, workdir: str) -> StagedPlan:
    # --keep may be reused. A fresh namespace also excludes previous .cmi/.cmx
    # files, so a removed source cannot be satisfied by an earlier build.
    staging = os.path.relpath(tempfile.mkdtemp(prefix=".standalone-", dir=workdir), workdir)
    groups: list[SourceGroup] = []
    unit_owners: dict[str, str] = {}

    def reserve(unit: str, owner: str) -> None:
        if unit in unit_owners:
            raise StagingError(f"compilation unit {unit} belongs to both {unit_owners[unit]} and {owner}")
        unit_owners[unit] = owner

    for library in plan.libraries:
        main = module_name(library.name)
        directory = os.path.join(staging, library.name)
        os.makedirs(os.path.join(workdir, directory))
        has_main = any(module_name(m) == main for m in library.modules)
        members = [m for m in library.modules if module_name(m) != main]
        wrapped = library.wrapped and bool(members)
        alias_unit = main + "__" if has_main else main
        alias = None
        if wrapped:
            reserve(alias_unit, library.name)
            alias = os.path.join(directory, alias_unit + ".ml")
            with open(os.path.join(workdir, alias), "w", encoding="utf-8") as out:
                for member in members:
                    out.write(f"module {module_name(member)} = {main}__{module_name(member)}\n")
        sources: list[str] = []
        for module in library.modules:
            public = module_name(module)
            unit = main + "__" + public if wrapped and public != main else public
            reserve(unit, library.name)
            origin = source_stem(root, library, module)
            generated = plan.generated.get((library.name, module))
            if origin is None and generated is None:
                raise StagingError(f"source absent: {library.directory}/{module}")
            for extension in (".mli", ".ml"):
                target = os.path.join(directory, unit + extension)
                if extension == ".ml" and generated is not None:
                    with open(os.path.join(workdir, target), "w", encoding="utf-8") as source:
                        source.write(generated)
                    sources.append(target)
                elif origin is not None and os.path.isfile(origin + extension):
                    shutil.copyfile(origin + extension, os.path.join(workdir, target))
                    sources.append(target)
        stubs: list[str] = []
        stub_directory = os.path.join(directory, "stubs")
        if library.stubs:
            os.makedirs(os.path.join(workdir, stub_directory))
        for stub in library.stubs:
            target = os.path.join(stub_directory, stub + ".c")
            shutil.copyfile(os.path.join(root, library.directory, stub + ".c"), os.path.join(workdir, target))
            stubs.append(target)
        if library.stubs:
            for header in glob.glob(os.path.join(root, library.directory, "*.h")):
                shutil.copyfile(header, os.path.join(workdir, stub_directory, os.path.basename(header)))
        groups.append(SourceGroup(directory, tuple(sources), tuple(stubs), alias,
                                  alias_unit if wrapped else None))

    directory = os.path.join(staging, "suite")
    os.makedirs(os.path.join(workdir, directory))
    reserve(module_name(plan.suite), "test suite")
    target = os.path.join(directory, plan.suite + ".ml")
    shutil.copyfile(os.path.join(root, "test", plan.suite + ".ml"), os.path.join(workdir, target))
    groups.append(SourceGroup(directory, (target,)))
    return StagedPlan(tuple(groups), tuple(["alcotest"] + plan.packages),
                      tuple(plan.link_flags), plan.suite + ".exe")


def compile_commands(staged: StagedPlan, workdir: str) -> list[list[str]]:
    """Compile each real unit once; -open never leaks to another library.

    The alias is compiled first with -no-alias-deps. ocamldep's -map resolves
    short internal names to their namespaced units, including interface edges:
    https://ocaml.org/manual/5.5/depend.html . An authored main is a normal
    source in this order, never a generated map or an inferred public API.
    """
    packages = ",".join(staged.packages)
    base = ["ocamlfind", "ocamlopt", "-package", packages, "-w", "-a", "-no-alias-deps"]
    commands: list[list[str]] = []
    objects: list[str] = []
    includes: list[str] = []
    for group in staged.groups:
        includes += ["-I", group.directory]
        for stub in group.stubs:
            obj = os.path.splitext(stub)[0] + ".o"
            commands.append(base + ["-c", stub, "-o", obj])
            objects.append(obj)
        if group.alias:
            obj = os.path.splitext(group.alias)[0] + ".cmx"
            commands.append(base + includes + ["-c", group.alias, "-o", obj])
            objects.append(obj)
        opened = ["-open", group.opened] if group.opened else []
        if group.sources:
            mapping = ["-map", group.alias] if group.alias else []
            probe = subprocess.run(
                ["ocamlfind", "ocamldep", "-package", packages] + includes
                + mapping + opened + ["-sort"] + list(group.sources),
                cwd=workdir, capture_output=True, text=True, check=False,
            )
            if probe.returncode != 0:
                raise StagingError("dependency analysis failed: " + probe.stderr.strip())
            ordered = probe.stdout.split()
            if len(ordered) != len(group.sources) or set(ordered) != set(group.sources):
                raise StagingError("dependency analysis omitted or duplicated source files")
            for source in ordered:
                extension = ".cmi" if source.endswith(".mli") else ".cmx"
                obj = os.path.splitext(source)[0] + extension
                commands.append(base + includes + opened + ["-c", source, "-o", obj])
                if extension == ".cmx":
                    objects.append(obj)
    commands.append(base + includes + ["-linkpkg"] + objects
                    + list(staged.link_flags) + ["-o", staged.executable])
    return commands


def build_and_run(plan: Plan, root: str, source_root: str, keep: str | None) -> Outcome:
    workdir = keep or tempfile.mkdtemp(prefix=f"{plan.suite}-")
    os.makedirs(workdir, exist_ok=True)
    try:
        staged = stage_plan(plan, root, workdir)
        commands = compile_commands(staged, workdir)
    except (OSError, StagingError) as error:
        return Outcome(None, str(error))

    # Some suites read a path relative to the working directory rather than
    # through DUNE_SOURCEROOT -- test_tool_name_prefix_boundary opens
    # "config/tools" -- because dune runs them with the workspace in view.
    # Linked in so those reads resolve, and so alcotest's own per-case output
    # still lands in this directory rather than in the checkout. _build is left
    # out on purpose: it is the one place a run could write over a real build.
    for entry in sorted(os.listdir(source_root)):
        if entry in {"_build", ".git", ".worktrees"} or entry.startswith("."):
            continue
        link = os.path.join(workdir, entry)
        if not os.path.exists(link) and not os.path.islink(link):
            os.symlink(os.path.join(source_root, entry), link)

    for command in commands:
        compile = subprocess.run(command, cwd=workdir, capture_output=True,
                                 text=True, check=False)
        if compile.returncode != 0:
            break
    if compile.returncode != 0:
        # Reported apart from a test failure: a suite that will not build says
        # nothing about the code it tests, and counting it as red would put a
        # gap in this harness on the same line as a real defect.
        # The whole error, bounded, not its last line. ocamlopt writes a
        # "No implementation provided for the following modules:" over three
        # lines, and reporting the last one alone printed the continuation --
        # "Capability_recovery_reconciler (…cmx)" -- which reads as a link
        # order complaint and sent one reader after the sort instead of after
        # the missing package (#33799).
        detail = compile.stderr.strip().splitlines()
        # findlib writes several warning shapes -- "[WARNING] Package X:
        # Deprecated", "[WARNING] Interface digestif.cmi occurs in several
        # directories" -- and any of them ahead of the error becomes the
        # summary line if only the package one is dropped.
        detail = [line for line in detail if "findlib: [WARNING]" not in line
                  and "[WARNING] Package" not in line]
        if not detail:
            return Outcome(None, "build failed")
        head = detail[:BUILD_DETAIL_LINES]
        if len(detail) > BUILD_DETAIL_LINES:
            head.append("  ... (truncated)")
        return Outcome(None, head[0], "\n".join(head[1:]))

    # Run inside its own directory: alcotest writes its per-case output under
    # the working directory, and a shared one has suites overwriting each other.
    run = subprocess.run(
        [os.path.join(workdir, plan.suite + ".exe"), "-e"],
        cwd=workdir,
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "DUNE_SOURCEROOT": source_root},
    )
    output = run.stdout + run.stderr
    if run.returncode == 0:
        summary = "ok"
        for line in output.splitlines():
            if "Test Successful" in line:
                summary = line.strip()
        return Outcome(True, summary)
    failures = [line.strip() for line in output.splitlines() if line.startswith("FAIL")]
    summary = "; ".join(failures) if failures else "failed"
    return Outcome(False, summary, failure_detail(output) or output_tail(output))


# What alcotest printed under each failed assertion, bounded. The names alone
# were not enough the first time this ran in CI: test_dune_local_script failed
# two assertions there and passed here, and a reader had only the two names to
# work from -- no expected, no received, and an environment they could not
# reproduce. The Expected/Received pair is the part that travels.
DETAIL_LINES = 40
# Alcotest prints the pair a couple of blank lines under the FAIL line, then a
# backtrace. Stop at the backtrace: it names alcotest's own frames, not the
# assertion, and it is the longest part of the block.
BUILD_DETAIL_LINES = 8
SKIP_REASONS_SHOWN = 10
DETAIL_STOP = ("Raised at", "ASSERT", "FAIL", "Logs saved to", "Testing ")


def output_tail(output: str) -> str:
    """The end of a run that failed without naming an assertion.

    A suite need not be alcotest, and one that exits non-zero with no FAIL
    line left the report as the bare word "failed" -- which is what a reader
    of a CI log got for test_ci_run_tests_script, a Linux-only red with
    nothing to act on. The tail is where a shell suite says what happened.
    """
    lines = [line.rstrip() for line in output.splitlines() if line.strip()]
    if not lines:
        return "the suite exited non-zero and wrote nothing"
    tail = lines[-DETAIL_LINES:]
    if len(lines) > DETAIL_LINES:
        tail.insert(0, "  ... (earlier output omitted)")
    return "\n".join(tail)


def failure_detail(output: str) -> str:
    lines = output.splitlines()
    keep: list[str] = []
    for index, line in enumerate(lines):
        if not line.startswith("FAIL"):
            continue
        keep.append(line.rstrip())
        for follow in lines[index + 1 : index + 12]:
            stripped = follow.rstrip()
            if stripped.lstrip().startswith(DETAIL_STOP):
                break
            if stripped and not set(stripped) <= {"\u2500", "\u2502", " "}:
                keep.append(stripped)
        if len(keep) >= DETAIL_LINES:
            keep.append("  ... (truncated)")
            break
    return "\n".join(keep[:DETAIL_LINES + 1])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suites", nargs="*", help="suite names, e.g. test_tui_agenda")
    parser.add_argument(
        "--all-matching",
        metavar="GLOB",
        action="append",
        default=[],
        help="every suite whose name matches; repeatable",
    )
    parser.add_argument(
        "--list", action="store_true", help="print what can be built and stop"
    )
    parser.add_argument(
        "--source-root",
        metavar="PATH",
        help=(
            "checkout whose sources the suites read through DUNE_SOURCEROOT."
            " The suites themselves still come from this repo, which is what"
            " makes it useful: a branch's assertions can be run against main."
        ),
    )
    parser.add_argument(
        "--keep",
        metavar="DIR",
        help="build in DIR and leave it there, instead of a temporary directory",
    )
    parser.add_argument(
        "--generate", action="store_true",
        help="run the supported ocaml-crunch embedded_config recipe into owned staging sources",
    )
    args = parser.parse_args()

    root = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    source_root = os.path.abspath(args.source_root or root)

    suites = read_suites(root)
    resolver = Resolver(collect_libraries(root), root, generate=args.generate)

    if args.all_matching:
        wanted = sorted(
            n
            for n in suites
            if any(fnmatch.fnmatch(n, pattern) for pattern in args.all_matching)
        )
    elif args.suites:
        wanted = list(args.suites)
    elif args.list:
        wanted = sorted(suites)
    else:
        parser.error("name a suite, or pass --all-matching or --list")

    plans: list[Plan] = []
    blocked: list[tuple[str, str]] = []
    for name in wanted:
        if name not in suites:
            blocked.append((name, "no such suite in test/dune"))
            continue
        if suites[name].needs_dune is not None:
            blocked.append((name, suites[name].needs_dune))
            continue
        plan, blocker = resolver.plan(name, suites[name].libraries)
        if plan is None:
            blocked.append((name, f"needs {blocker}"))
        else:
            plans.append(plan)

    if args.list:
        for plan in plans:
            print(f"buildable  {plan.suite}  ({sum(len(lib.modules) for lib in plan.libraries)} modules)")
        for name, why in blocked:
            print(f"blocked    {name}  {why}")
        print(f"\n{len(plans)} buildable, {len(blocked)} blocked")
        return 0

    started = time.time()
    failed = 0
    unbuilt = 0
    for plan in plans:
        keep = os.path.join(args.keep, plan.suite) if args.keep else None
        outcome = build_and_run(plan, root, source_root, keep)
        if outcome.built is None:
            unbuilt += 1
            label = "build"
        elif outcome.built:
            label = "ok   "
        else:
            failed += 1
            label = "FAIL "
        print(f"{label} {plan.suite}: {outcome.summary}")
        if outcome.detail:
            for line in outcome.detail.splitlines():
                print(f"      {line}")
    # One line per skip buries the verdicts: a full run skips over a thousand
    # suites with dependencies requiring Dune. Name them
    # individually only when the caller asked for particular suites; otherwise
    # count them by reason, which is also the list of what to unblock first.
    for package, implementation in sorted(resolver.substitutions.items()):
        print(f"note  declared implementation for {package}: {implementation}")
    if args.suites:
        for name, why in blocked:
            print(f"skip  {name}: {why}")
    elif blocked:
        reasons: dict[str, int] = {}
        for _name, why in blocked:
            reasons[why] = reasons.get(why, 0) + 1
        ranked = sorted(reasons.items(), key=lambda pair: -pair[1])
        for why, count in ranked[:SKIP_REASONS_SHOWN]:
            print(f"skip  {count} suites: {why}")
        rest = len(ranked) - SKIP_REASONS_SHOWN
        if rest > 0:
            print(f"skip  ... and {rest} further reasons")
    print(
        f"\n{len(plans) - failed - unbuilt} passed, {failed} failed,"
        f" {unbuilt} would not build, {len(blocked)} skipped"
        f" in {time.time() - started:.0f}s"
    )
    # A suite that would not build is this harness falling short, not a verdict
    # on the tree, so it does not fail the run.
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
