#!/usr/bin/env python3
"""Build and run test suites with ocamlfind instead of dune.

A suite whose dune stanza names only single-module libraries under bin/ or
test_lib/ does not need the masc library, and therefore does not need a build
of it. This script reads those stanzas, works out which modules the suite
actually reaches, compiles them in dependency order with ocamlfind, and runs
the result.

Why it is worth having: a targeted CI dispatch answers in about eight minutes,
and alcotest stops at the first failed assertion inside a case, so a case with
three stale assertions costs three dispatches. The same suites answer here in
well under a second each. Measured 2026-09-07: 91 suites built and ran in 119
seconds.

A library's C stubs are compiled alongside its modules, and its
(c_library_flags ...) reach the linker as -cclib. Without that the suite gets
as far as the linker and dies on an undefined symbol -- an answer that looks
like a verdict and is not.

The suites this cannot reach are the ones that name `masc` (or a sublibrary of
it). Building those from source is the local dune build this exists to avoid;
they stay on the CI dispatch.

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


@dataclass
class Plan:
    suite: str
    modules: list[tuple[str, str]] = field(default_factory=list)
    packages: list[str] = field(default_factory=list)
    stubs: list[tuple[str, str]] = field(default_factory=list)
    link_flags: list[str] = field(default_factory=list)
    # (library name, its modules) for each wrapped library that needs the
    # alias module dune generates. See [write_alias_module].
    aliases: list[tuple[str, tuple[str, ...]]] = field(default_factory=list)
    # (module, its text) for each module a dune rule would have produced.
    generated: list[tuple[str, str]] = field(default_factory=list)


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
    return sorted(os.path.basename(path)[: -len(".ml")] for path in paths)


def read_libraries(dune_path: str, directory: str, root_dir: str) -> dict[str, Library]:
    if not os.path.exists(dune_path):
        return {}
    text = strip_comments(open(dune_path, encoding="utf-8").read())
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
        # dune wraps a library's modules in a generated alias module unless
        # the stanza says otherwise, and nothing here generates that module.
        # Compiling one anyway gives every consumer an unbound module, so a
        # wrapped library is refused by name instead.
        #
        # One shape escapes that: a library whose only module carries the
        # library's own name is its own main module, and dune generates no
        # alias for it. Compiling the file gives exactly the module every
        # consumer names, so wrapping costs nothing there. time_compat,
        # dated_jsonl and fs_compat are that shape, and 71 suites link them.
        declared = (field_words(form, "wrapped") or ["true"])[0] != "false"
        wrapped = declared and modules != [name]
        library = Library(
            name,
            directory,
            tuple(modules),
            tuple(deps),
            tuple(stubs),
            tuple(c_flags),
            wrapped,
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
    text = strip_comments(open(os.path.join(root, "test/dune"), encoding="utf-8").read())
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
    # Libraries under lib/ as well. Whether one can be built from source is
    # decided per library below -- a wrapped one cannot -- rather than by
    # keeping only the leaves here, which used to exclude fs_compat and every
    # public name.
    # packages/ holds agent_core and its sublibraries, which nine suites name
    # as masc.agent_core. Unread, they were blocked on a name the index did
    # not carry; read, the report says the library is wrapped, which is the
    # thing that would have to change.
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


class Resolver:
    def __init__(
        self, libraries: dict[str, Library], root: str, generate: bool = False
    ):
        self.libraries = libraries
        self.root = root
        # Whether this run may run a dune rule's generator itself. Off by
        # default: it opens most of the tree, and most of what it opens is
        # slow enough that the PR gate's budget cannot hold it (#33939).
        self.generate = generate
        # Module name -> the text this run generated for it.
        self.generated: dict[str, str] = {}
        self._findlib: dict[str, bool] = {}
        self._archives: dict[str, str] = {}
        # Virtual findlib package -> the implementation this run linked.
        self.substitutions: dict[str, str] = {}
        self._package_list: list[str] | None = None

    def installed(self, name: str) -> bool:
        if name not in self._findlib:
            probe = subprocess.run(
                ["ocamlfind", "query", name], capture_output=True, check=False
            )
            self._findlib[name] = probe.returncode == 0
        return self._findlib[name]

    def generate_library(self, library: Library) -> bool:
        """Whether this runner may produce [library]'s modules itself.

        Only embedded_config, and only under --generate. It is
        `ocaml-crunch -m plain config`: one command, no network, a pure
        function of a directory this run already reads, and crunch is a
        declared build dependency. 896 suites link it.

        It stays off by default because of what it costs, not because of what
        it is. Measured on test_a* (36 suites): 18s without, over 280s with,
        because the suites it opens link wrapped libraries of several hundred
        modules that this runner flattens into one command line. The PR gate
        step has 15 minutes and the whole run already takes 268s. Behind the
        flag, one suite can be verified locally without that bill.

        The text is made once and kept in memory; the build directory gets a
        copy. Nothing is written into the checkout: a --list must not leave a
        file behind, and a source tree that grows an untracked .ml because a
        test ran is a worse trade than the coverage.
        """
        if not self.generate or library.name != "embedded_config":
            return False
        if "embedded_config" in self.generated:
            return True
        config = os.path.join(self.root, "config")
        if not os.path.isdir(config):
            return False
        crunch = subprocess.run(
            ["ocaml-crunch", "-m", "plain", config],
            capture_output=True,
            text=True,
            check=False,
        )
        if crunch.returncode != 0 or not crunch.stdout:
            return False
        self.generated["embedded_config"] = crunch.stdout
        return True

    def archive_of(self, name: str) -> str:
        """The native archive [name] provides, empty when it provides none.

        A findlib package with no archive is a virtual one: digestif declares
        `archive(native) = ""` and ships `digestif.c` and `digestif.ocaml`
        beside it. Linking the bare name compiles and then fails at the link
        with "No implementation provided for Digestif", which names the
        modules that wanted it rather than the package that is missing.
        """
        if name not in self._archives:
            probe = subprocess.run(
                ["ocamlfind", "query", "-format", "%(archive)", "-predicates",
                 "native", name],
                capture_output=True,
                text=True,
                check=False,
            )
            self._archives[name] = probe.stdout.strip() if probe.returncode == 0 else ""
        return self._archives[name]

    def _installed_packages(self) -> list[str]:
        """Every findlib package name, read once. `ocamlfind list` takes about
        a second here and the caller asks per dependency per suite; without
        this a --list over 1200 suites spent minutes in it."""
        if self._package_list is None:
            probe = subprocess.run(
                ["ocamlfind", "list"], capture_output=True, text=True, check=False
            )
            self._package_list = (
                [line.split()[0] for line in probe.stdout.splitlines() if line.split()]
                if probe.returncode == 0
                else []
            )
        return self._package_list

    def implementations_of(self, name: str) -> list[str]:
        """[name]'s subpackages that do provide an archive."""
        prefix = name + "."
        return [
            candidate
            for candidate in self._installed_packages()
            if candidate.startswith(prefix) and self.archive_of(candidate)
        ]

    def plan(self, suite: str, deps: list[str]) -> tuple[Plan | None, str | None]:
        ordered: list[str] = []
        packages: list[str] = []
        blocker: str | None = None

        def visit(name: str) -> bool:
            nonlocal blocker
            if name in ordered:
                return True
            library = self.libraries.get(name)
            if library is None:
                if self.installed(name):
                    resolved = name
                    if not self.archive_of(name):
                        # Virtual: an implementation has to be named. Taken in
                        # sorted order rather than declared, and printed once
                        # per run so the choice is visible if it ever starts to
                        # matter. Measured 2026-09-07 on the only virtual
                        # package this tree links: with digestif.c and with
                        # digestif.ocaml, test_fs_compat_capability_head gives
                        # 18 failures over 19 cases either way -- the verdict
                        # the dune lane reports.
                        #
                        # No archive is not the same as no implementation.
                        # threads.posix and mtime.clock.os declare none and
                        # resolve through findlib predicates and requires;
                        # only a package that ships archive-carrying
                        # subpackages is the virtual shape this substitutes
                        # for. Anything else passes through as written.
                        candidates = sorted(self.implementations_of(name))
                        if candidates:
                            resolved = candidates[0]
                            self.substitutions[name] = resolved
                            # Ahead of everything else. ocamlfind orders
                            # -package by declared dependency, and nothing
                            # declares a dependency on the implementation --
                            # mirage-crypto-rng requires the virtual
                            # `digestif`, so digestif_c.cmxa landed after it
                            # and the link refused: "Wrong link order:
                            # Mirage_crypto_rng__Fortuna depends on Digestif".
                            if resolved not in packages:
                                packages.insert(0, resolved)
                            return True
                    if resolved not in packages:
                        packages.append(resolved)
                    return True
                blocker = blocker or name
                return False
            # A library whose modules are not on disk comes out of a dune
            # rule. Two of them, and they are not the same case.
            #
            # embedded_config is ocaml-crunch over a directory this run
            # already reads, so --generate can produce it. masc_proto is
            # protoc, a system package CI's own opam run reports as
            # unavailable, so there is nothing to run either way and the
            # suites that need it say so.
            if library.modules and not any(
                os.path.exists(os.path.join(self.root, library.directory, module + ".ml"))
                for module in library.modules
            ):
                if not self.generate_library(library):
                    blocker = blocker or f"{name} (generated by a dune rule)"
                    return False
            for dependency in library.deps:
                if not visit(dependency):
                    return False
            ordered.append(name)
            return True

        for dependency in deps:
            if not visit(dependency):
                return None, blocker
        plan = Plan(suite)
        for name in ordered:
            library = self.libraries[name]
            for module in library.modules:
                plan.modules.append((library.directory, module))
            for stub in library.stubs:
                plan.stubs.append((library.directory, stub))
            if library.wrapped:
                plan.aliases.append((library.name, library.modules))
            for module in library.modules:
                if module in self.generated:
                    plan.generated.append((module, self.generated[module]))
            for flag in library.c_library_flags:
                # -lncurses reaches the C linker through the OCaml driver.
                plan.link_flags += ["-cclib", flag]
        plan.packages = packages
        return plan, None


@dataclass(frozen=True)
class Outcome:
    """One suite's verdict. `built` is None when it never got as far as a
    verdict, which is a gap in this harness rather than a red test."""

    built: bool | None
    summary: str
    detail: str = ""


def write_alias_module(workdir: str, library: str, modules: tuple[str, ...]) -> str | None:
    """The module dune generates for a wrapped library, written out.

    dune renames a wrapped library's modules to `<lib>__<Module>` and adds a
    `<lib>` module binding each one, so a consumer writes `Lib.Module`. The
    renaming is not needed here -- one build directory, one suite -- but the
    binding is: without it every `Lib.Module` in a consumer is unbound.
    `module Module = Module` gives exactly that binding.

    A wrapped library whose only module carries the library's own name has no
    generated alias in dune either: that module is the namespace. Writing one
    would collide with it, so this returns None.
    """
    if list(modules) == [library]:
        return None
    path = os.path.join(workdir, library + ".ml")
    with open(path, "w", encoding="utf-8") as out:
        for module in modules:
            if os.path.exists(os.path.join(workdir, module + ".ml")):
                out.write(f"module {module[:1].upper()}{module[1:]} = "
                          f"{module[:1].upper()}{module[1:]}\n")
    return library + ".ml"


def sort_sources_by_dependency(
    workdir: str, sources: list[str], packages: list[str]
) -> tuple[list[str], str | None]:
    """[sources] with the .ml files in dependency order, .mli kept ahead of
    its own .ml, and the .c files left where they are, and why the order is
    the one it came in with when the sort could not be made.

    ocamldep answers over whatever is in the directory, so this sorts across
    libraries as well as within one. A failure to sort is not raised: the
    unsorted order is worth compiling, because a suite whose sources already
    happen to be in order builds from it.

    But it must be reported. Unsorted, the compile fails at the first module
    that names one behind it, and says "Unbound module Types" -- which reads
    as a missing module and sends the reader looking for a file that is
    staged and right there. The reason is one line up: ocamldep exits 2 with
    "cycle in dependencies", which the alias modules this runner writes for
    wrapped libraries can produce. Carrying that line to the failure is the
    difference between a legible gap and a wrong lead.
    """
    modules = [name for name in sources if name.endswith(".ml")]
    if len(modules) < 2:
        return sources, None
    # The .mli files go in as well. A module can name another only in its
    # interface -- fs_compat's atomic_write.mli reaches
    # Capability_recovery_reconciler where its .ml does not -- and a sort that
    # sees only the implementations puts them the wrong way round, which
    # arrives as ocamlopt's "Wrong link order".
    interfaces = [name for name in sources if name.endswith(".mli")]
    probe = subprocess.run(
        ["ocamlfind", "ocamldep", "-package", ",".join(["alcotest"] + packages),
         "-sort"] + interfaces + modules,
        cwd=workdir,
        capture_output=True,
        text=True,
        check=False,
    )
    if probe.returncode != 0:
        first = next(
            (
                line.strip()
                for line in probe.stderr.splitlines()
                if line.strip().startswith("Error:")
            ),
            "ocamldep exited %d" % probe.returncode,
        )
        return sources, "sources are in the order they were staged: " + first
    ordered = [name for name in probe.stdout.split() if name in set(modules)]
    if len(ordered) != len(modules):
        return sources, (
            "sources are in the order they were staged: ocamldep returned %d"
            " of %d modules" % (len(ordered), len(modules))
        )
    out = [name for name in sources if name.endswith(".c")]
    interfaces = {name for name in sources if name.endswith(".mli")}
    for module in ordered:
        interface = module + "i"
        if interface in interfaces:
            out.append(interface)
        out.append(module)
    return out, None


def build_and_run(plan: Plan, root: str, source_root: str, keep: str | None) -> Outcome:
    workdir = keep or tempfile.mkdtemp(prefix=f"{plan.suite}-")
    os.makedirs(workdir, exist_ok=True)
    sources: list[str] = []

    # Module name -> the directory it was staged from. Flattening several
    # libraries into one directory is what makes this runner simple, and it is
    # also the one thing dune's wrapping exists to prevent: two libraries may
    # each have a types.ml, and here the second copy lands on the first.
    # agent_core has exactly that -- base/types.ml and llm_provider/types.ml --
    # and the compile then says "Unbound module Types" about a types.ml that is
    # staged and right there, because it is the other one.
    staged_from: dict[str, str] = {}
    collisions: list[str] = []

    def stage(directory: str, module: str) -> None:
        origin = os.path.join(root, directory, module + ".ml")
        if not os.path.exists(origin):
            return
        previous = staged_from.get(module)
        if previous is not None and previous != directory:
            collisions.append(f"{module}.ml: {previous} and {directory}")
        staged_from[module] = directory
        # The interface too, when there is one. Without it every abstract type
        # arrives concrete and the suite compiles against a wider signature
        # than dune gives it -- which is how it would pass here and fail there.
        interface = origin + "i"
        if os.path.exists(interface):
            shutil.copy(interface, workdir)
            sources.append(module + ".mli")
        shutil.copy(origin, workdir)
        sources.append(module + ".ml")

    # The C sources come first on the command line: ocamlfind compiles them
    # and hands the objects to the linker with the modules that call them.
    for directory, stub in plan.stubs:
        origin = os.path.join(root, directory, stub + ".c")
        if os.path.exists(origin):
            shutil.copy(origin, workdir)
            sources.append(stub + ".c")
    for directory, module in plan.modules:
        stage(directory, module)
    for module, text in plan.generated:
        with open(os.path.join(workdir, module + ".ml"), "w", encoding="utf-8") as out:
            out.write(text)
        sources.append(module + ".ml")
    for library, modules in plan.aliases:
        alias = write_alias_module(workdir, library, modules)
        if alias is not None:
            sources.append(alias)
    shutil.copy(os.path.join(root, "test", plan.suite + ".ml"), workdir)
    sources.append(plan.suite + ".ml")

    # dune compiles a library's modules in dependency order; a stanza's
    # (modules ...) is a set written for people to read. Ordering by the
    # stanza worked while every library here was a leaf with a handful of
    # modules and broke on the first sixteen-module one, where
    # capability_exact_read uses eio_resource_scope listed after it. Ask
    # ocamldep, which answers across libraries too -- the same question the
    # command line asks, since everything is staged flat.
    sources, unsorted_reason = sort_sources_by_dependency(
        workdir, sources, plan.packages
    )

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

    packages = ",".join(["alcotest"] + plan.packages)
    # -w -a: the suite and its libraries are built with the repo's own flags by
    # dune, and CI is where a warning has to be answered. Repeating them here
    # would only turn an unrelated warning into a failure to run at all.
    compile = subprocess.run(
        ["ocamlfind", "ocamlopt", "-package", packages, "-linkpkg", "-w", "-a"]
        + sources
        + plan.link_flags
        + ["-o", plan.suite + ".exe"],
        cwd=workdir,
        capture_output=True,
        text=True,
        check=False,
    )
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
        # Ahead of the compiler, because the compiler is describing the
        # consequence: unsorted, it stops at the first module that names one
        # behind it and calls that module unbound.
        # Both reasons go ahead of the compiler, and the collision ahead of
        # the sort: a name that means two files is why the sort could not be
        # made, and the sort not being made is why the compiler stopped where
        # it did. Reported on a failure rather than on staging, because a
        # suite that never reaches the shadowed module builds and passes, and
        # refusing that would lose coverage to a hazard it did not meet.
        if unsorted_reason is not None:
            head.insert(0, "  " + unsorted_reason)
        if collisions:
            head.insert(
                0,
                "  %d module name(s) staged from two libraries, so one copy"
                " shadows the other: %s"
                % (len(collisions), "; ".join(sorted(collisions)[:3])),
            )
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
        "--generate",
        action="store_true",
        help=(
            "run ocaml-crunch to produce embedded_config, which 896 suites"
            " link. Off by default: it opens most of the tree and the suites"
            " it opens are slow enough to overrun the PR gate's budget"
            " (#33939). Use it to verify one suite locally."
        ),
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
            print(f"buildable  {plan.suite}  ({len(plan.modules)} modules)")
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
    # suites, each because a library it links is wrapped. Name them
    # individually only when the caller asked for particular suites; otherwise
    # count them by reason, which is also the list of what to unblock first.
    for package, implementation in sorted(resolver.substitutions.items()):
        print(f"note  {package} is virtual; linked {implementation}")
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
