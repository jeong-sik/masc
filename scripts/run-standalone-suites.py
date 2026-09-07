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
        depth = 0
        end = index
        while end < len(text):
            if text[end] == "(":
                depth += 1
            elif text[end] == ")":
                depth -= 1
                if depth == 0:
                    break
            end += 1
        yield text[index : end + 1]
        index = end + 1


# `(libraries (re_export piaf) unix)` -- a library can be listed inside a
# nested form. The marker names no library of its own; what it wraps does.
NESTED_LIBRARY_MARKERS = ("re_export",)


def field_words(form: str, name: str) -> list[str] | None:
    """The words of `(name ...)` in [form], read to its matching paren.

    Stopping at the first `)` instead would truncate a field whose value
    nests -- `(libraries (re_export piaf) unix)` read that way yields
    `(re_export piaf` and loses `unix` entirely.
    """
    field = next(sexp_forms(form, f"({name}"), None)
    if field is None:
        return None
    body = field[field.index(" ") + 1 : -1] if " " in field else ""
    words = body.replace("(", " ").replace(")", " ").split()
    return [word for word in words if word not in NESTED_LIBRARY_MARKERS]


def read_libraries(dune_path: str, directory: str) -> dict[str, Library]:
    if not os.path.exists(dune_path):
        return {}
    text = strip_comments(open(dune_path, encoding="utf-8").read())
    out: dict[str, Library] = {}
    for form in sexp_forms(text, "(library"):
        names = field_words(form, "name")
        if not names:
            continue
        name = names[0]
        modules = field_words(form, "module") or [name]
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
        wrapped = (field_words(form, "wrapped") or ["true"])[0] != "false"
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


def read_suites(root: str) -> dict[str, list[str]]:
    text = open(os.path.join(root, "test/dune"), encoding="utf-8").read()
    for included in sorted(glob.glob(os.path.join(root, "test/stanzas/*.inc"))):
        text += "\n" + open(included, encoding="utf-8").read()
    out: dict[str, list[str]] = {}
    for form in sexp_forms(text, "(test"):
        names = field_words(form, "name")
        if not names:
            continue
        deps = field_words(form, "librarie") or field_words(form, "libraries") or []
        for name in names:
            out[name] = deps
    return out


def collect_libraries(root: str) -> dict[str, Library]:
    libraries = read_libraries(os.path.join(root, "bin/dune"), "bin")
    libraries.update(read_libraries(os.path.join(root, "test_lib/dune"), "test_lib"))
    # test/deps holds masc_test_deps, which 806 suites link. Left out, every
    # one of them was reported as blocked on a library this index had never
    # heard of, which says nothing about what to unblock first.
    libraries.update(read_libraries(os.path.join(root, "test/deps/dune"), "test/deps"))
    # test/dune and its includes declare libraries of their own beside the
    # suites -- exact_output_fixture is one -- and their modules sit in test/.
    libraries.update(read_libraries(os.path.join(root, "test/dune"), "test"))
    for included in sorted(glob.glob(os.path.join(root, "test/stanzas/*.inc"))):
        libraries.update(read_libraries(included, "test"))
    # Libraries under lib/ as well. Whether one can be built from source is
    # decided per library below -- a wrapped one cannot -- rather than by
    # keeping only the leaves here, which used to exclude fs_compat and every
    # public name.
    for path in sorted(glob.glob(os.path.join(root, "lib/**/dune"), recursive=True)):
        directory = os.path.relpath(os.path.dirname(path), root)
        for name, library in read_libraries(path, directory).items():
            libraries.setdefault(name, library)
    return libraries


class Resolver:
    def __init__(self, libraries: dict[str, Library]):
        self.libraries = libraries
        self._findlib: dict[str, bool] = {}

    def installed(self, name: str) -> bool:
        if name not in self._findlib:
            probe = subprocess.run(
                ["ocamlfind", "query", name], capture_output=True, check=False
            )
            self._findlib[name] = probe.returncode == 0
        return self._findlib[name]

    def plan(self, suite: str, deps: list[str]) -> tuple[Plan | None, str | None]:
        ordered: list[str] = []
        packages: list[str] = []
        blocker: str | None = None

        def visit(name: str) -> bool:
            nonlocal blocker
            if name in ordered:
                return True
            library = self.libraries.get(name)
            if library is not None and library.wrapped:
                blocker = blocker or f"{name} (wrapped)"
                return False
            if library is None:
                if self.installed(name):
                    if name not in packages:
                        packages.append(name)
                    return True
                blocker = blocker or name
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


def build_and_run(plan: Plan, root: str, source_root: str, keep: str | None) -> Outcome:
    workdir = keep or tempfile.mkdtemp(prefix=f"{plan.suite}-")
    os.makedirs(workdir, exist_ok=True)
    sources: list[str] = []

    def stage(directory: str, module: str) -> None:
        origin = os.path.join(root, directory, module + ".ml")
        if not os.path.exists(origin):
            return
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
    shutil.copy(os.path.join(root, "test", plan.suite + ".ml"), workdir)
    sources.append(plan.suite + ".ml")

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
        detail = compile.stderr.strip().splitlines()
        return Outcome(None, detail[-1] if detail else "build failed")

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
    return Outcome(False, summary, failure_detail(output))


# What alcotest printed under each failed assertion, bounded. The names alone
# were not enough the first time this ran in CI: test_dune_local_script failed
# two assertions there and passed here, and a reader had only the two names to
# work from -- no expected, no received, and an environment they could not
# reproduce. The Expected/Received pair is the part that travels.
DETAIL_LINES = 40
# Alcotest prints the pair a couple of blank lines under the FAIL line, then a
# backtrace. Stop at the backtrace: it names alcotest's own frames, not the
# assertion, and it is the longest part of the block.
SKIP_REASONS_SHOWN = 10
DETAIL_STOP = ("Raised at", "ASSERT", "FAIL", "Logs saved to", "Testing ")


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
    args = parser.parse_args()

    root = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    source_root = os.path.abspath(args.source_root or root)

    suites = read_suites(root)
    resolver = Resolver(collect_libraries(root))

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
        plan, blocker = resolver.plan(name, suites[name])
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
