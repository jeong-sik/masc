#!/usr/bin/env python3
"""`masc config set`, run as a script runs it: the real executable.

test_runtime_setting_set.ml proves the writer. This runs the executable, so a
subcommand that is renamed, an argument that is not passed on, or a workspace
that is not seeded fails here. Every case works in a scratch workspace under a
scratch HOME.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

MASC = Path(sys.argv.pop(1)).resolve()

# A runtime.toml the server would load: [runtime].default is required.
RUNTIME_TOML = """# Operator notes: kept as they are.
[providers."deepseek"]
display-name = "Fixture HTTP (deepseek)"
protocol = "openai-compatible-http"
endpoint = "https://fixture.invalid/v1"
[providers."deepseek".credentials]
type = "inline"
value = "previous-fixture-key"
[models.chat]
api-name = "deepseek-v4-pro"
["deepseek".chat]
[runtime]
default = "deepseek.chat"
"""


def masc(root, *args):
    environment = {"HOME": str(root / "home"), "PATH": "/usr/bin:/bin"}
    return subprocess.run([str(MASC), "config", "set", *args], env=environment,
                          capture_output=True, text=True)


def runtime_toml(base):
    return base / ".masc/config/runtime.toml"


def workspace(root, name="workspace"):
    base = root / name
    runtime_toml(base).parent.mkdir(parents=True)
    runtime_toml(base).write_text(RUNTIME_TOML)
    return base


class ConfigSetCommand(unittest.TestCase):
    def scratch(self):
        temporary = tempfile.TemporaryDirectory(prefix="config set cli ' ")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        (root / "home").mkdir()
        return root

    # A script starts from a base path nothing has touched.
    def test_a_fresh_workspace_is_seeded_and_the_keys_are_written(self):
        root = self.scratch()
        base = root / "fresh workspace ' one"
        result = masc(root, "autonomous.enabled=false", "otel.enabled=false",
                      "--base-path", str(base))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(runtime_toml(base).is_file(), "the config root was not seeded")
        written = runtime_toml(base).read_text()
        self.assertIn("[autonomous]\nenabled = false", written)
        self.assertIn("[otel]\nenabled = false", written)
        self.assertIn("autonomous.enabled", result.stdout)

    def test_a_second_run_changes_nothing(self):
        root = self.scratch()
        base = workspace(root)
        arguments = ("autonomous.enabled=false", "--base-path", str(base))
        self.assertEqual(masc(root, *arguments).returncode, 0)
        first = runtime_toml(base).read_bytes()
        second = masc(root, *arguments)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("already as requested", second.stdout)
        self.assertEqual(runtime_toml(base).read_bytes(), first)

    def test_a_workspace_that_has_a_file_keeps_its_notes(self):
        root = self.scratch()
        base = workspace(root)
        result = masc(root, "heartbeat.interval_sec=30", "--base-path", str(base))
        self.assertEqual(result.returncode, 0, result.stderr)
        written = runtime_toml(base).read_text()
        self.assertTrue(written.startswith(RUNTIME_TOML), written)
        self.assertTrue(written.endswith("[heartbeat]\ninterval_sec = 30\n"), written)

    def test_an_unknown_key_is_refused_and_nothing_is_seeded(self):
        root = self.scratch()
        base = root / "fresh"
        result = masc(root, "bogus.key=1", "--base-path", str(base))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("bogus.key", result.stderr)
        self.assertFalse(runtime_toml(base).exists())

    def test_a_value_of_the_wrong_kind_is_refused(self):
        root = self.scratch()
        base = workspace(root)
        result = masc(root, "autonomous.enabled=maybe", "--base-path", str(base))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("autonomous.enabled", result.stderr)
        self.assertIn("true or false", result.stderr)
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    def test_several_assignments_are_all_or_none(self):
        root = self.scratch()
        base = workspace(root)
        # heartbeat.interval_sec is at least 1: the first assignment must not
        # land without the second.
        result = masc(root, "autonomous.enabled=false", "heartbeat.interval_sec=0",
                      "--base-path", str(base))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("heartbeat.interval_sec", result.stderr)
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    def test_an_argument_without_an_equals_sign_is_refused(self):
        root = self.scratch()
        base = workspace(root)
        result = masc(root, "autonomous.enabled", "--base-path", str(base))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("KEY=VALUE", result.stderr)
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)


if __name__ == "__main__":
    unittest.main()
