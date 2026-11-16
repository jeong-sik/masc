#!/usr/bin/env python3
"""The notice collector ships what dune links and refuses a linked package it cannot account for."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from types import ModuleType
from typing import Protocol, cast
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "collect-ocaml-notices.py"


def load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("collect_ocaml_notices", SCRIPT)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


notices = load()


class Refusal(Protocol):
    reasons: tuple[str, ...]


TARGET = "bin/main_eio.exe"
HOOK = "bin/masc_antigravity_path_hook.exe"
NO_COLOR = "--color=never"
TLS_LICENSE = b"Copyright (c) 2014, David Kaloper and Hannes Mehnert\n"
OCAML_LICENSE = b"the OCaml Core System is distributed under the LGPL\n"
SSL_COPYING = b"GNU LESSER GENERAL PUBLIC LICENSE\n"
LIBYAML_LICENSE = b"Copyright (c) 2006-2016 Kirill Simonov\n"
YAML_LICENSE = b"ISC License\n"


@dataclass
class Package:
    version: str
    # Paths relative to the switch prefix; installed files get these bytes.
    installed: dict[str, bytes]
    # Files of the package's `opam source` tree, by path below its top.
    source: dict[str, bytes]
    # Symbolic links of the source tree: path below its top -> link target.
    links: dict[str, str] = field(default_factory=dict[str, str])
    source_hash: str | None = None


@dataclass
class Switch:
    """A fake opam switch and dune: answers the commands the collector runs."""

    prefix: Path
    packages: dict[str, Package]
    # Installed files each target's link rule reads, relative to the prefix.
    linked: dict[str, list[str]]
    deps: list[object] = field(default_factory=list[object])
    # Commands that exit non-zero, and `opam source` specs that do; the
    # source directory is random, so it is matched by spec.
    failing: list[list[str]] = field(default_factory=list[list[str]])
    unfetchable: list[str] = field(default_factory=list[str])
    commands: list[list[str]] = field(default_factory=list[list[str]])

    def install(self) -> None:
        for package in self.packages.values():
            for relative, data in package.installed.items():
                path = self.prefix / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)

    def rules(self, target: str) -> str:
        externals: list[object] = [{"File": ["External", str(self.prefix / path)]} for path in self.linked[target]]
        workspace: list[object] = [{"File": ["In_build_dir", "_build/default/bin/.main_eio.eobjs/native/main.cmx"]}]
        return json.dumps([{"deps": externals + workspace + self.deps,
                            "targets": {"files": ["_build/default/" + target], "directories": []}}])

    def fetch(self, root: Path, spec: str) -> str:
        name, version = spec.split(".", 1)
        package = self.packages[name]
        assert package.version == version, spec
        root.mkdir(parents=True)
        (root / "dune-project").write_text("(lang dune 3.0)\n")
        (root / ".git").mkdir()
        (root / ".git/COPYING.hook").write_text("a git hook, not a notice\n")
        for file, data in package.source.items():
            (root / file).parent.mkdir(parents=True, exist_ok=True)
            (root / file).write_bytes(data)
        for file, target in package.links.items():
            (root / file).symlink_to(target)
        return f"Successfully extracted to {root}\n"

    def __call__(self, argv: Sequence[str]) -> str | object:
        command = list(argv)
        self.commands.append(command)
        if command in self.failing:
            return notices.Refused((f"`{' '.join(command)}` exited 1: failed",))
        match command:
            case ["dune", "rules", "--release", "--format=json", target] if target in self.linked:
                return self.rules(target)
            case ["ocamlopt", "-where"]:
                return str(self.prefix / "lib/ocaml") + "\n"
            case ["opam", "var", "--color=never", "doc"]:
                return str(self.prefix / "doc") + "\n"
            case ["opam", "list", "--color=never", "--installed", "--short", "--columns=name,version,source-hash"]:
                return "".join(f"{name:<24}{package.version:<14}{package.source_hash or ''}\n"
                               for name, package in sorted(self.packages.items()))
            case ["opam", "show", "--color=never", "--list-files", name]:
                package = self.packages[name]
                return "".join(f"{self.prefix / relative}\n" for relative in sorted(package.installed)) + "\n"
            case ["opam", "source", "--color=never", directory, spec] if directory.startswith("--dir="):
                if spec in self.unfetchable:
                    return notices.Refused((f"`opam source {spec}` exited 5: no network",))
                return self.fetch(Path(directory[len("--dir="):]), spec)
            case _:
                raise AssertionError(f"unexpected command {command}")


def switch(prefix: Path) -> Switch:
    packages = {
        "ocaml-compiler": Package("5.5.2", {
            "lib/ocaml/stdlib.cmxa": b"stdlib", "lib/ocaml/unix/unix.cmxa": b"unix",
            "bin/ocamlopt.opt": b"ocamlopt", "doc/ocaml/LICENSE": OCAML_LICENSE}, {"LICENSE": OCAML_LICENSE}),
        "tls": Package("2.1.5", {
            "lib/tls/tls.cmxa": b"tls", "lib/tls/tls.a": b"tls", "doc/tls/LICENSE.md": TLS_LICENSE,
            "doc/tls/README.md": b"readme"}, {"LICENSE.md": TLS_LICENSE, "README.md": b"readme"}),
        # dune installs LICENSE* only; this package's COPYING lives in its source.
        "ssl": Package("0.7.0", {"lib/ssl/ssl.cmxa": b"ssl"}, {"COPYING": SSL_COPYING}),
        # Installed for the tests, never linked into the release executables.
        "alcotest": Package("1.9.1", {"lib/alcotest/alcotest.cmxa": b"alcotest",
                                      "doc/alcotest/LICENSE.md": b"ISC"}, {"LICENSE.md": b"ISC"}),
    }
    return Switch(prefix, packages, {TARGET: ["bin/ocamlopt.opt", "lib/ocaml/unix/unix.cmxa", "lib/tls/tls.a",
                                              "lib/tls/tls.cmxa", "lib/ssl/ssl.cmxa"]})


def yaml_package() -> Package:
    """A package that vendors a C library and keeps tests with their own notice."""
    return Package("3.2.0", {"lib/yaml/yaml.cmxa": b"yaml", "lib/yaml/c/libyaml_c_stubs.a": b"stubs",
                             "doc/yaml/LICENSE.md": YAML_LICENSE},
                   {"LICENSE.md": YAML_LICENSE, "vendor/License": LIBYAML_LICENSE,
                    "tests/data/COPYING": b"test corpus terms\n", "src/yaml.ml": b"let x = 1\n"})


YAML_RULES: Mapping[str, object] = {
    "vendor/License": notices.Ship("vendor/ builds the linked libyaml_c_stubs.a"),
    "tests": notices.Exclude("test data"),
}
YAML_NESTED: Mapping[tuple[str, str], Mapping[str, object]] = {("yaml", "3.2.0"): YAML_RULES}


class CollectNotices(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.out = self.root / "notices"
        self.switch = switch(self.root / "switch")

    def link_yaml(self) -> None:
        self.switch.packages["yaml"] = yaml_package()
        self.switch.linked[TARGET].append("lib/yaml/c/libyaml_c_stubs.a")

    def produce(self, no_upstream_notice: Mapping[tuple[str, str], str] | None = None,
                nested: Mapping[tuple[str, str], Mapping[str, object]] | None = None,
                targets: Sequence[str] = (TARGET,)) -> object:
        self.switch.install()
        return notices.produce(self.out, list(targets), self.switch, no_upstream_notice or {}, nested or {})

    def refusal(self, no_upstream_notice: Mapping[tuple[str, str], str] | None = None,
                nested: Mapping[tuple[str, str], Mapping[str, object]] | None = None) -> str:
        result = self.produce(no_upstream_notice, nested)
        self.assertIsInstance(result, notices.Refused)
        self.assertFalse(self.out.exists(), "a refused collection must not leave a partial directory")
        return "\n".join(cast(Refusal, result).reasons)

    def manifest(self, targets: Sequence[str] = (TARGET,)) -> dict[str, dict[str, object]]:
        data = json.loads((self.out / "packages.json").read_text())
        self.assertEqual(notices.SCHEMA, data["schema"])
        self.assertEqual(list(targets), data["executables"])
        return {entry["name"]: entry for entry in data["packages"]}

    def shipped_files(self) -> set[str]:
        return {path.relative_to(self.out).as_posix() for path in self.out.rglob("*") if path.is_file()}

    def test_ships_the_notices_of_every_linked_package_and_of_nothing_else(self) -> None:
        result = self.produce()
        self.assertNotIsInstance(result, notices.Refused)
        packages = self.manifest()
        # The standard library and runtime come with ocamlopt, unnamed by the rule.
        self.assertEqual({"ocaml-compiler", "ssl", "tls"}, set(packages))
        self.assertEqual("0.7.0", packages["ssl"]["version"])
        self.assertEqual({"packages.json", "ocaml-compiler/LICENSE", "ssl/COPYING", "tls/LICENSE.md"},
                         self.shipped_files())
        self.assertEqual(TLS_LICENSE, (self.out / "tls/LICENSE.md").read_bytes())
        self.assertEqual(SSL_COPYING, (self.out / "ssl/COPYING").read_bytes())
        self.assertEqual(OCAML_LICENSE, (self.out / "ocaml-compiler/LICENSE").read_bytes())
        self.assertEqual({"name": "tls", "version": "2.1.5", "source_hash": None, "excluded": [],
                          "notices": [{"file": "tls/LICENSE.md", "found_in": ["doc/tls/LICENSE.md", "source"],
                                       "sha256": hashlib.sha256(TLS_LICENSE).hexdigest()}]},
                         packages["tls"])
        for path in self.out.rglob("*"):
            if path.is_file():
                self.assertEqual(0o644, path.stat().st_mode & 0o777, path)

    def test_every_opam_listing_is_asked_for_without_colour(self) -> None:
        # OPAMCOLOR=always colours even piped output; the fake answers only the uncoloured form.
        self.assertNotIsInstance(self.produce(), notices.Refused)
        opam = [command for command in self.switch.commands if command[0] == "opam"]
        self.assertTrue(opam)
        for command in opam:
            self.assertIn(NO_COLOR, command)

    def test_the_standard_library_owner_is_linked_even_when_the_rule_names_none_of_its_files(self) -> None:
        self.switch.linked[TARGET] = ["lib/tls/tls.cmxa"]
        self.assertNotIsInstance(self.produce(), notices.Refused)
        self.assertEqual({"ocaml-compiler", "tls"}, set(self.manifest()))

    def test_the_packages_of_every_target_are_shipped(self) -> None:
        self.switch.linked = {TARGET: ["lib/tls/tls.cmxa"], HOOK: ["bin/ocamlopt.opt", "lib/ssl/ssl.cmxa"]}
        self.assertNotIsInstance(self.produce(targets=(TARGET, HOOK)), notices.Refused)
        self.assertEqual({"ocaml-compiler", "ssl", "tls"}, set(self.manifest((TARGET, HOOK))))

    def test_a_pinned_package_records_the_commit_it_was_built_from(self) -> None:
        self.switch.packages["ssl"].source_hash = "d812d6fec4153efc11235661e0d4b4d0d789c45b"
        self.assertNotIsInstance(self.produce(), notices.Refused)
        self.assertEqual("d812d6fec4153efc11235661e0d4b4d0d789c45b", self.manifest()["ssl"]["source_hash"])

    def test_a_linked_package_without_any_notice_stops_the_collection(self) -> None:
        self.switch.packages["ssl"].source = {}
        self.assertIn("ssl.0.7.0 is linked", self.refusal())

    def test_a_listed_version_without_an_upstream_notice_is_recorded_without_files(self) -> None:
        self.switch.packages["ssl"].source = {}
        result = self.produce({("ssl", "0.7.0"): "the 0.7.0 release archive has no notice file"})
        self.assertNotIsInstance(result, notices.Refused)
        self.assertEqual({"name": "ssl", "version": "0.7.0", "source_hash": None, "excluded": [], "notices": [],
                          "no_upstream_notice": "the 0.7.0 release archive has no notice file"},
                         self.manifest()["ssl"])
        self.assertFalse((self.out / "ssl").exists())

    def test_a_listed_version_that_has_a_notice_stops_the_collection(self) -> None:
        reasons = self.refusal({("ssl", "0.7.0"): "the 0.7.0 release archive has no notice file"})
        self.assertIn("NO_UPSTREAM_NOTICE names ssl.0.7.0, which has COPYING", reasons)

    def test_another_version_of_a_listed_package_still_needs_a_notice(self) -> None:
        self.switch.packages["ssl"].source = {}
        self.assertIn("ssl.0.7.0 is linked", self.refusal({("ssl", "0.6.0"): "no notice"}))

    def test_a_linked_file_no_installed_package_owns_stops_the_collection(self) -> None:
        self.switch.linked[TARGET].append("lib/vendored/vendored.cmxa")
        self.assertIn("lib/vendored/vendored.cmxa is linked, but no installed opam package owns it", self.refusal())

    def test_one_notice_name_with_two_contents_stops_the_collection(self) -> None:
        self.switch.packages["tls"].source = {"LICENSE.md": b"another text\n"}
        self.assertIn("tls: LICENSE.md differs between doc/tls/LICENSE.md and source", self.refusal())

    def test_an_unrecognised_dune_dependency_stops_the_collection(self) -> None:
        self.switch.deps = [{"Alias": ["bin", "default"]}]
        self.assertIn("unrecognised dependency", self.refusal())

    def test_a_rule_that_reads_no_installed_file_is_not_taken_for_a_link(self) -> None:
        self.switch.linked[TARGET] = []
        self.assertIn(f"dune rules {TARGET}: the rule reads no installed file", self.refusal())

    def test_a_failed_opam_source_stops_the_collection(self) -> None:
        self.switch.unfetchable = ["ssl.0.7.0"]
        self.assertIn("`opam source ssl.0.7.0` exited 5: no network", self.refusal())

    def test_a_failed_opam_show_stops_the_collection(self) -> None:
        self.switch.failing = [["opam", "show", NO_COLOR, "--list-files", "alcotest"]]
        self.assertIn("--list-files alcotest` exited 1", self.refusal())

    def test_a_notice_installed_outside_doc_is_not_read(self) -> None:
        # It is a copy of a source file, and the source is read instead.
        self.switch.packages["ssl"].installed["lib/ssl/LICENSE"] = b"an installed copy\n"
        self.assertNotIsInstance(self.produce(), notices.Refused)
        self.assertEqual({"packages.json", "ocaml-compiler/LICENSE", "ssl/COPYING", "tls/LICENSE.md"},
                         self.shipped_files())

    def test_a_notice_in_a_subdirectory_of_doc_stops_the_collection(self) -> None:
        self.switch.packages["tls"].installed["doc/tls/odoc-pages/LICENSE.mld"] = b"{0 License}\n"
        self.assertIn("tls: doc/tls/odoc-pages/LICENSE.mld is a notice inside a subdirectory of doc/tls/",
                      self.refusal())

    def test_a_notice_directory_at_the_top_of_the_source_ships_whole(self) -> None:
        self.switch.packages["ssl"].source = {"LICENSES/LGPL-2.1.txt": SSL_COPYING, "LICENSES/MIT.txt": b"MIT\n"}
        self.assertNotIsInstance(self.produce(), notices.Refused)
        self.assertEqual(SSL_COPYING, (self.out / "ssl/LICENSES/LGPL-2.1.txt").read_bytes())
        self.assertEqual(["ssl/LICENSES/LGPL-2.1.txt", "ssl/LICENSES/MIT.txt"],
                         [notice["file"] for notice in cast(list[dict[str, str]], self.manifest()["ssl"]["notices"])])

    def test_a_notice_that_is_a_symbolic_link_stops_the_collection(self) -> None:
        self.switch.packages["ssl"].links = {"COPYING.LESSER": "COPYING"}
        self.assertIn("COPYING.LESSER is named like a notice but is not a regular file", self.refusal())

    def test_a_nested_notice_ships_or_is_excluded_as_its_entry_says(self) -> None:
        self.link_yaml()
        self.assertNotIsInstance(self.produce(nested=YAML_NESTED), notices.Refused)
        yaml = self.manifest()["yaml"]
        self.assertEqual(["yaml/LICENSE.md", "yaml/vendor/License"],
                         [notice["file"] for notice in cast(list[dict[str, str]], yaml["notices"])])
        self.assertEqual(LIBYAML_LICENSE, (self.out / "yaml/vendor/License").read_bytes())
        self.assertEqual([{"path": "tests/data/COPYING", "why": "test data"}], yaml["excluded"])
        self.assertFalse((self.out / "yaml/tests").exists())

    def test_a_nested_notice_no_entry_covers_stops_the_collection(self) -> None:
        self.link_yaml()
        reasons = self.refusal(nested={("yaml", "3.2.0"): {"tests": notices.Exclude("test data")}})
        self.assertIn("yaml.3.2.0: vendor/License is a notice below the top of the source; "
                      "give NESTED_NOTICES a path for this version", reasons)

    def test_another_version_of_a_package_with_nested_paths_needs_its_own(self) -> None:
        self.link_yaml()
        self.switch.packages["yaml"].version = "3.3.0"
        reasons = self.refusal(nested=YAML_NESTED)
        self.assertIn("yaml.3.3.0: vendor/License is a notice below the top", reasons)
        self.assertIn("yaml.3.3.0: tests/data/COPYING is a notice below the top", reasons)

    def test_an_entry_for_a_path_the_linked_version_lacks_stops_the_collection(self) -> None:
        self.link_yaml()
        nested = {("yaml", "3.2.0"): {**YAML_RULES, "bench": notices.Exclude("benchmarks")}}
        self.assertIn("NESTED_NOTICES for yaml.3.2.0 names bench, which holds no notice in that version",
                      self.refusal(nested=nested))

    def test_an_entry_over_a_notice_at_the_top_stops_the_collection(self) -> None:
        self.link_yaml()
        nested = {("yaml", "3.2.0"): {**YAML_RULES, "LICENSE.md": notices.Exclude("not ours")}}
        self.assertIn("NESTED_NOTICES for yaml.3.2.0 names LICENSE.md, but LICENSE.md is at the top of the source",
                      self.refusal(nested=nested))

    def test_two_entries_over_one_notice_stop_the_collection(self) -> None:
        self.link_yaml()
        nested = {("yaml", "3.2.0"): {**YAML_RULES, "tests/data": notices.Exclude("fixtures")}}
        self.assertIn("yaml.3.2.0: tests/data/COPYING is covered by several NESTED_NOTICES paths: tests, tests/data",
                      self.refusal(nested=nested))

    def test_an_existing_output_directory_is_left_alone(self) -> None:
        self.out.mkdir()
        (self.out / "kept").write_text("kept\n")
        result = self.produce()
        self.assertIsInstance(result, notices.Refused)
        self.assertEqual(["kept"], [path.name for path in self.out.iterdir()])
        self.assertEqual([], self.switch.commands)


class Main(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.switch = switch(self.root / "switch")
        self.switch.install()

    def main(self) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(notices, "run_command", self.switch), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = notices.main(["--out", str(self.root / "notices"), TARGET])
        return code, stdout.getvalue(), stderr.getvalue()

    def test_exits_zero_and_counts_what_it_wrote(self) -> None:
        code, stdout, stderr = self.main()
        self.assertEqual((0, ""), (code, stderr))
        self.assertIn("3 linked opam packages, 3 notice files, 0 without an upstream notice", stdout)
        self.assertTrue((self.root / "notices/packages.json").is_file())

    def test_exits_one_and_prints_every_reason(self) -> None:
        self.switch.packages["ssl"].source = {}
        self.switch.packages["tls"].source = {"LICENSE.md": b"another text\n"}
        code, stdout, stderr = self.main()
        self.assertEqual((1, ""), (code, stdout))
        self.assertIn("collect-ocaml-notices: ssl.0.7.0 is linked", stderr)
        self.assertIn("collect-ocaml-notices: tls: LICENSE.md differs", stderr)
        self.assertFalse((self.root / "notices").exists())


if __name__ == "__main__":
    unittest.main()
