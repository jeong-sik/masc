#!/usr/bin/env python3
"""Staging tests never compile OCaml; --compile-fixtures adds CI-only link proof."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/run-standalone-suites.py"
spec = importlib.util.spec_from_file_location("standalone_suites", SCRIPT)
runner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runner
spec.loader.exec_module(runner)
COMPILE_FIXTURES = "--compile-fixtures" in sys.argv
if COMPILE_FIXTURES:
    sys.argv.remove("--compile-fixtures")


class NamespaceFixtures(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "checkout"
        self.work = Path(self.tmp.name) / "work"
        self.work.mkdir()
        files = {
            "lib/alpha/dune": "(library (name alpha) (public_name test.alpha) (modules alpha helper util))",
            "lib/alpha/alpha.ml": "let answer = Util.value + Helper.value\n",
            "lib/alpha/alpha.mli": "val answer : int\n",
            "lib/alpha/helper.ml": "let value = Util.value + 1\n",
            "lib/alpha/util.ml": "let value = 10\n",
            "lib/alpha/util.mli": "val value : int\n",
            "lib/beta/dune": "(library (name beta) (modules helper util) (libraries test.alpha))",
            "lib/beta/helper.ml": "let value = Util.value + Alpha.answer\n",
            "lib/beta/util.ml": "let value = 100\n",
            "test/test_namespace.ml": "let () = assert (Alpha.answer = 21); assert (Beta.Helper.value = 121)\n",
        }
        for name, body in files.items():
            self.write(name, body)
        libraries = runner.collect_libraries(str(self.root))
        self.resolver = runner.Resolver(libraries, str(self.root))
        self.plan, blocker = self.resolver.plan("test_namespace", ["beta", "test.alpha", "alpha"])
        self.assertIsNone(blocker)

    def write(self, name, body):
        target = self.root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body)

    def stage(self):
        return runner.stage_plan(self.plan, str(self.root), str(self.work))

    def read(self, name):
        return (self.work / name).read_text()

    def test_authored_entry_and_interfaces_are_preserved_byte_for_byte(self):
        staged = self.stage()
        alpha, beta, _ = staged.groups
        self.assertEqual(len(self.plan.libraries), 2)  # public/private name is one owner
        for name in ("alpha.ml", "alpha.mli", "util.ml", "util.mli"):
            unit = "Alpha" if name.startswith("alpha.") else "Alpha__Util"
            suffix = Path(name).suffix
            self.assertEqual((self.work / alpha.directory / (unit + suffix)).read_bytes(),
                             (self.root / "lib/alpha" / name).read_bytes())
        self.assertIn("module Util = Alpha__Util", self.read(alpha.alias))
        self.assertNotIn("module Alpha =", self.read(alpha.alias))
        self.assertEqual(Path(alpha.alias).name, "Alpha__.ml")
        self.assertEqual(Path(beta.alias).name, "Beta.ml")
        self.assertIn("module Util = Beta__Util", self.read(beta.alias))
        self.assertNotEqual(self.read(alpha.directory + "/Alpha__Util.ml"),
                            self.read(beta.directory + "/Beta__Util.ml"))
        self.assertFalse(list(self.work.rglob("Util.ml")))

    def test_each_library_has_its_own_open_and_dependency_map(self):
        staged = self.stage()
        probes = []

        def dependencies(command, **kwargs):
            self.assertEqual(command[:2], ["ocamlfind", "ocamldep"])
            sources = command[command.index("-sort") + 1:]
            # Simulate the analyser's interleaved interface/dependency order,
            # deliberately different from the authored stanza order.
            rank = {"Alpha__Util.mli": 0, "Alpha__Util.ml": 1,
                    "Alpha__Helper.ml": 2, "Alpha.mli": 3, "Alpha.ml": 4,
                    "Beta__Util.ml": 0, "Beta__Helper.ml": 1}
            ordered = sorted(sources, key=lambda name: rank.get(Path(name).name, 0))
            probes.append(command)
            return subprocess.CompletedProcess(command, 0, " ".join(ordered), "")

        with patch.object(runner.subprocess, "run", side_effect=dependencies):
            commands = runner.compile_commands(staged, str(self.work))
        alpha, beta, suite = staged.groups
        self.assertIn(alpha.alias, probes[0])
        self.assertIn(beta.alias, probes[1])
        self.assertNotIn("-open", probes[2])
        self.assertNotIn("-map", probes[2])
        compiled = [c for c in commands if "-c" in c]
        names = [Path(c[c.index("-c") + 1]).name for c in compiled]
        self.assertEqual(names[:6], ["Alpha__.ml", "Alpha__Util.mli", "Alpha__Util.ml",
                                   "Alpha__Helper.ml", "Alpha.mli", "Alpha.ml"])
        for command in compiled:
            source = command[command.index("-c") + 1]
            if source in (alpha.alias, beta.alias) or source in suite.sources:
                self.assertNotIn("-open", command)
            else:
                opened = command[command.index("-open") + 1]
                self.assertEqual(opened, "Alpha__" if Path(source).parent.name == "alpha" else "Beta")
        self.assertNotIn("-open", commands[-1])
        objects = [arg for arg in commands[-1] if arg.endswith(".cmx")]
        self.assertEqual(len(objects), len(set(objects)))
        self.assertEqual(Path(objects[-1]).name, "test_namespace.cmx")

    def test_dependency_error_never_falls_back_to_stanza_order(self):
        staged = self.stage()
        for code, output in ((2, ""), (0, staged.groups[0].sources[0])):
            with self.subTest(code=code), patch.object(runner.subprocess, "run",
                    return_value=subprocess.CompletedProcess([], code, output, "cycle")):
                with self.assertRaises(runner.StagingError):
                    runner.compile_commands(staged, str(self.work))

    def test_same_c_stub_basename_keeps_both_owners(self):
        from dataclasses import replace
        for name in ("alpha", "beta"):
            self.write(f"lib/{name}/binding.c", f"int {name}_binding = 1;\n")
        self.plan.libraries = [replace(lib, stubs=("binding",)) for lib in self.plan.libraries]
        staged = self.stage()
        stubs = [g.stubs[0] for g in staged.groups[:2]]
        self.assertNotEqual(stubs[0], stubs[1])
        self.assertIn("alpha_binding", self.read(stubs[0]))
        self.assertIn("beta_binding", self.read(stubs[1]))

    def test_partial_generated_library_is_not_silently_reduced(self):
        from dataclasses import replace
        lib = self.plan.libraries[0]
        self.resolver.libraries["alpha"] = replace(lib, modules=lib.modules + ("generated",))
        plan, blocker = self.resolver.plan("test_namespace", ["alpha"])
        self.assertIsNone(plan)
        self.assertIn("alpha.generated", blocker)

    def test_real_http_client_entry_is_not_replaced_with_an_alias(self):
        repo = SCRIPT.parent.parent
        library = runner.read_libraries(str(repo / "lib/masc_http_client/dune"),
                                        "lib/masc_http_client", str(repo))["masc_http_client"]
        plan = runner.Plan("test_tui_keys", libraries=[library])
        staged = runner.stage_plan(plan, str(repo), str(self.work))
        group = staged.groups[0]
        self.assertEqual((self.work / group.directory / "Masc_http_client.ml").read_bytes(),
                         (repo / "lib/masc_http_client/masc_http_client.ml").read_bytes())
        self.assertEqual(Path(group.alias).name, "Masc_http_client__.ml")

    def test_unsupported_source_transformations_have_specific_reasons(self):
        cases = {
            "(private_modules util)": "private_modules",
            "(flags (:standard -open Injected))": "compiler flags",
            "(flags (:standard (per_module (-open Injected) util)))": "compiler flags",
            "(foreign_stubs (language c) (names binding) (flags -DSPECIAL))": "foreign_stubs flags",
            "(foreign_stubs (language cxx) (names binding))": "foreign_stubs language",
        }
        for declaration, expected in cases.items():
            with self.subTest(declaration=declaration):
                form = f"(library (name alpha) {declaration})"
                self.assertIn(expected, runner.source_contract_reason(form, form))
        warning_only = "(library (name alpha) (flags (:standard -w +4 -warn-error +a)))"
        self.assertIsNone(runner.source_contract_reason(warning_only, warning_only))

    def test_reusing_keep_cannot_import_an_old_unit(self):
        first = self.stage()
        (self.work / first.groups[0].directory / "Ghost.cmi").write_bytes(b"stale")
        second = self.stage()
        self.assertNotEqual(first.groups[0].directory, second.groups[0].directory)
        self.assertFalse((self.work / second.groups[0].directory / "Ghost.cmi").exists())

    @unittest.skipUnless(COMPILE_FIXTURES, "remote CI compile/link fixture only")
    def test_real_link_preserves_authored_api_and_distinct_wrapped_units(self):
        result = runner.build_and_run(self.plan, str(self.root), str(self.root), str(self.work))
        self.assertIs(result.built, True, (result.summary, result.detail))
        # Alpha.mli intentionally exports only answer. Its internal alias must
        # not turn a hidden module into part of the authored public interface.
        self.write("test/test_namespace.ml", "let () = ignore Alpha.Util.value\n")
        result = runner.build_and_run(self.plan, str(self.root), str(self.root), str(self.work))
        self.assertIsNone(result.built, "hidden internal module unexpectedly compiled")
        self.assertIn("Unbound module Alpha.Util", result.summary + result.detail)


class GeneratedSourceFixtures(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "checkout"
        self.work = Path(self.tmp.name) / "work"
        self.work.mkdir()
        for name, body in {
            "config/example.toml": "enabled = true\n",
            "lib/embedded_config/dune": "(library (name embedded_config) (modules embedded_config) (wrapped false))",
            "lib/wrapper/dune": "(library (name wrapper) (modules embedded_config))",
            "lib/wrapper/embedded_config.ml": 'let owner = "wrapper"\n',
            "test/dune": "(test (name test_generated) (libraries embedded_config wrapper))",
            "test/test_generated.ml": "let () = ()\n",
        }.items():
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(body)
        self.libraries = runner.collect_libraries(str(self.root))
        self.generated = 'let read = function "example.toml" -> Some "enabled = true" | _ -> None\n'

    def resolver(self, enabled=True):
        return runner.Resolver(self.libraries, str(self.root), generate=enabled)

    def stage(self, plan):
        return runner.stage_plan(plan, str(self.root), str(self.work))

    def test_generation_is_explicit_opt_in_and_does_not_write_checkout(self):
        with patch.object(runner.subprocess, "run") as process:
            plan, blocker = self.resolver(enabled=False).plan("test_generated", ["embedded_config"])
        self.assertIsNone(plan)
        self.assertIn("--generate", blocker)
        process.assert_not_called()
        self.assertFalse((self.root / "lib/embedded_config/embedded_config.ml").exists())

    def test_generated_source_keeps_its_owner_next_to_same_basename(self):
        resolver = self.resolver()
        with patch.object(runner.subprocess, "run", return_value=
                          subprocess.CompletedProcess([], 0, self.generated, "")) as process:
            plan, blocker = resolver.plan("test_generated", ["embedded_config", "wrapper"])
            repeated, repeated_blocker = resolver.plan("test_generated", ["embedded_config"])
            unrelated, unrelated_blocker = resolver.plan("test_generated", ["wrapper"])
        self.assertIsNone(blocker)
        self.assertIsNone(repeated_blocker)
        self.assertIsNone(unrelated_blocker)
        process.assert_called_once_with(["ocaml-crunch", "-m", "plain", str(self.root / "config")],
                                        capture_output=True, text=True, check=False)
        self.assertEqual(plan.generated, {("embedded_config", "embedded_config"): self.generated})
        self.assertEqual(repeated.generated, plan.generated)
        self.assertEqual(unrelated.generated, {})
        generated, wrapper, _ = self.stage(plan).groups
        self.assertIsNone(generated.alias)
        self.assertIsNone(generated.opened)
        self.assertEqual((self.work / generated.directory / "Embedded_config.ml").read_text(), self.generated)
        self.assertEqual((self.work / wrapper.directory / "Wrapper__Embedded_config.ml").read_text(),
                         'let owner = "wrapper"\n')
        self.assertIn("module Embedded_config = Wrapper__Embedded_config", (self.work / wrapper.alias).read_text())
        self.assertFalse((self.root / "lib/embedded_config/embedded_config.ml").exists())

    def test_other_owner_cannot_borrow_cached_generated_module(self):
        resolver = self.resolver()
        with patch.object(runner.subprocess, "run", return_value=
                          subprocess.CompletedProcess([], 0, self.generated, "")) as process:
            resolver.plan("test_generated", ["embedded_config"])
            (self.root / "lib/wrapper/embedded_config.ml").unlink()
            plan, blocker = resolver.plan("test_generated", ["wrapper"])
        process.assert_called_once()
        self.assertIsNone(plan)
        self.assertIn("wrapper.embedded_config", blocker)
        self.assertIn("no supported generator", blocker)

    def test_generation_preserves_an_existing_interface(self):
        interface = self.root / "lib/embedded_config/embedded_config.mli"
        interface.write_text("val read : string -> string option\n")
        with patch.object(runner.subprocess, "run", return_value=
                          subprocess.CompletedProcess([], 0, self.generated, "")):
            plan, blocker = self.resolver().plan("test_generated", ["embedded_config"])
        self.assertIsNone(blocker)
        group = self.stage(plan).groups[0]
        self.assertEqual([Path(name).suffix for name in group.sources], [".mli", ".ml"])
        self.assertEqual((self.work / group.directory / "Embedded_config.mli").read_bytes(), interface.read_bytes())

    def test_authored_implementation_is_not_regenerated(self):
        source = self.root / "lib/embedded_config/embedded_config.ml"
        source.write_text('let read _ = Some "authored"\n')
        with patch.object(runner.subprocess, "run") as process:
            plan, blocker = self.resolver().plan("test_generated", ["embedded_config"])
        process.assert_not_called()
        self.assertIsNone(blocker)
        self.assertEqual(plan.generated, {})
        group = self.stage(plan).groups[0]
        self.assertEqual((self.work / group.directory / "Embedded_config.ml").read_bytes(), source.read_bytes())

    def test_generator_failure_keeps_exit_and_stderr_without_retries(self):
        for status in (17, -9):
            with self.subTest(status=status):
                resolver = self.resolver()
                with patch.object(runner.subprocess, "run", return_value=
                                  subprocess.CompletedProcess([], status, "partial source", "invalid config\ninput failed")) as process:
                    first = resolver.plan("test_generated", ["embedded_config"])
                    second = resolver.plan("test_generated", ["embedded_config"])
                process.assert_called_once()
                self.assertIsNone(first[0])
                self.assertEqual(first, second)
                self.assertIn(f"exited {status}", first[1])
                self.assertIn("invalid config\ninput failed", first[1])
                self.assertFalse(list(self.work.iterdir()))

    def test_missing_generator_and_empty_success_remain_distinct_failures(self):
        for outcome, expected in ((FileNotFoundError("ocaml-crunch absent"), "could not start"),
                                  (subprocess.CompletedProcess([], 0, "", ""), "produced no source")):
            with self.subTest(expected=expected):
                resolver = self.resolver()
                options = {"side_effect": outcome} if isinstance(outcome, Exception) else {"return_value": outcome}
                with patch.object(runner.subprocess, "run", **options) as process:
                    plan, blocker = resolver.plan("test_generated", ["embedded_config"])
                    self.assertEqual((plan, blocker), resolver.plan("test_generated", ["embedded_config"]))
                process.assert_called_once()
                self.assertIsNone(plan)
                self.assertIn(expected, blocker)

    def test_cli_generate_wires_only_the_supported_generator(self):
        import io
        def command_plan(command, **kwargs):
            if command == ["git", "rev-parse", "--show-toplevel"]:
                return subprocess.CompletedProcess(command, 0, str(self.root), "")
            self.assertEqual(command, ["ocaml-crunch", "-m", "plain", str(self.root / "config")])
            return subprocess.CompletedProcess(command, 0, self.generated, "")
        with patch.object(sys, "argv", [str(SCRIPT), "--list", "--generate", "test_generated"]), \
             patch.object(runner.subprocess, "run", side_effect=command_plan), \
             patch.object(sys, "stdout", new_callable=io.StringIO) as output:
            self.assertEqual(runner.main(), 0)
        self.assertIn("1 buildable, 0 blocked", output.getvalue())
        self.assertFalse((self.root / "lib/embedded_config/embedded_config.ml").exists())


class FindlibFixtures(unittest.TestCase):
    def setUp(self):
        self.resolver = runner.Resolver({}, "/unused")
        self.text = """
(library (name crypto) (kind virtual) (default_implementation crypto.z_native))
(library (name crypto.a_pure) (kind normal) (implements crypto))
(library (name crypto.z_native) (kind normal) (implements crypto))
(library (name aggregate) (kind normal) (requires crypto))
"""

    def resolve(self, packages, closure):
        with patch.object(self.resolver, "package_metadata",
                          side_effect=lambda name: runner.read_package_metadata(self.text, name)), \
             patch.object(runner.subprocess, "run",
                          return_value=subprocess.CompletedProcess([], 0, "\n".join(closure), "")):
            return self.resolver.resolve_packages(packages)

    def test_declared_default_wins_over_lexical_implementation_order(self):
        result = self.resolve(["aggregate"], ["crypto", "aggregate"])
        self.assertEqual(result, ["crypto.z_native", "aggregate"])
        self.assertEqual(self.resolver.substitutions, {"crypto": "crypto.z_native"})

    def test_explicit_implementation_wins_over_default(self):
        result = self.resolve(["aggregate", "crypto.a_pure"],
                              ["crypto", "crypto.a_pure", "aggregate"])
        self.assertEqual(result, ["crypto.a_pure", "aggregate"])

    def test_conflicting_implementations_do_not_pick_a_winner(self):
        with self.assertRaises(runner.StagingError):
            self.resolve(["crypto.a_pure", "crypto.z_native"],
                         ["crypto", "crypto.a_pure", "crypto.z_native"])

    def test_no_metadata_does_not_guess_an_implementation(self):
        self.assertEqual(self.resolve(["thread_alias"], ["thread_alias"]), ["thread_alias"])
        self.assertEqual(self.resolver.substitutions, {})


if __name__ == "__main__":
    unittest.main()
