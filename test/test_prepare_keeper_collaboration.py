"""Exercise the manual preparation CLI using local config and inert binary bytes."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/prepare-keeper-collaboration.py"
SOURCE = """
[runtime.exact_output_lanes.librarian_exact]
slots = ["fixture.model.with.dots"]
[providers.fixture]
protocol = "openai-compatible-http"
endpoint = "http://provider.invalid/v1"
[providers.fixture.credentials]
type = "env"
key = "PREP_FIXTURE_KEY"
[providers.other]
protocol = "openai-compatible-http"
endpoint = "http://other.invalid/v1"
[providers.other.credentials]
type = "env"
key = "PREP_OTHER_KEY"
[models."model.with.dots"]
api-name = "opaque/model.v2"
max-context = 32000
[models.second]
api-name = "second-model"
max-context = 64000
[fixture."model.with.dots"]
max-concurrent = 2
[fixture.second]
max-concurrent = 3
[other.second]
max-concurrent = 4
"""


class PrepareCollaboration(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.config = self.root / "config"
        self.config.mkdir()
        self.source = self.config / "runtime.toml"
        self.source.write_text(SOURCE)
        self.binary = self.root / "observed-binary"
        self.binary.write_bytes(b"inert fixture bytes; never executed")
        self.digest = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.health = self.root / "health.json"
        self.health.write_text(
            json.dumps(
                {
                    "build": {
                        "executable_sha256": self.digest,
                        "binary_commit": "fixture-commit",
                    }
                }
            )
        )
        self.base = self.root / "prepared"

    def prepare(
        self,
        primary="fixture.model.with.dots",
        secondary="fixture.second",
        *,
        credentials=True,
    ):
        env = {
            key: value
            for key, value in os.environ.items()
            if key not in ("PREP_FIXTURE_KEY", "PREP_OTHER_KEY")
        }
        if credentials:
            env["PREP_FIXTURE_KEY"] = "fixture-only"
        if secondary == "other.second":
            env["PREP_OTHER_KEY"] = "fixture-other"
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--base",
                str(self.base),
                "--source-config",
                str(self.config),
                "--binary",
                str(self.binary),
                "--health",
                str(self.health),
                "--port",
                "0",
                "--primary-runtime",
                primary,
                "--secondary-runtime",
                secondary,
            ],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_exact_dotted_ids_and_shared_provider_preserve_source_bindings(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        selected = tomllib.loads((self.base / ".masc/config/runtime.toml").read_text())
        source = tomllib.loads(SOURCE)
        self.assertEqual(selected["fixture"], source["fixture"])
        self.assertEqual(selected["models"], source["models"])
        self.assertEqual(
            selected["providers"], {"fixture": source["providers"]["fixture"]}
        )
        primary, secondary = "fixture.model.with.dots", "fixture.second"
        self.assertEqual(selected["runtime"]["default"], primary)
        self.assertEqual(
            selected["runtime"]["lanes"],
            {identity: {"candidates": [identity]} for identity in (primary, secondary)},
        )
        self.assertEqual(
            selected["runtime"]["exact_output_lanes"]["librarian_exact"]["slots"],
            [primary],
        )
        preset = selected["fusion"]["presets"]["collaboration"]
        self.assertEqual(preset["panel"], [primary, secondary])
        self.assertEqual(preset["judge"], primary)
        receipt = json.loads((self.base / "scenario-input.json").read_text())
        self.assertEqual(receipt["keeper_runtimes"], [primary, secondary])
        self.assertEqual(receipt["verifier_runtime"], primary)
        self.assertEqual(receipt["binary_sha256"], self.digest)
        self.assertEqual(
            (self.base / "masc-observed.exe").read_bytes(), self.binary.read_bytes()
        )
        self.assertEqual(self.source.read_text(), SOURCE)

    def test_distinct_selected_providers_are_copied_without_rewriting(self):
        result = self.prepare(secondary="other.second")
        self.assertEqual(result.returncode, 0, result.stderr)
        selected = tomllib.loads((self.base / ".masc/config/runtime.toml").read_text())
        source = tomllib.loads(SOURCE)
        self.assertEqual(selected["providers"], source["providers"])
        self.assertEqual(selected["other"], source["other"])
        self.assertEqual(set(selected["fixture"]), {"model.with.dots"})

    def test_unresolved_runtime_is_not_normalized_or_written(self):
        result = self.prepare(primary="fixture.model-with-dots")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture.model-with-dots", result.stderr)
        self.assertIn(str(self.source), result.stderr)
        self.assertFalse(self.base.exists())
        self.assertEqual(self.source.read_text(), SOURCE)

    def test_missing_model_declaration_is_rejected_before_preparation(self):
        self.source.write_text(SOURCE.replace("[models.second]", "[models.unselected]"))
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("has no model declaration", result.stderr)
        self.assertFalse(self.base.exists())

    def test_credentials_and_binary_identity_remain_required(self):
        result = self.prepare(credentials=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("selected credential unavailable", result.stderr)
        self.assertFalse(self.base.exists())
        self.health.write_text(
            json.dumps({"build": {"executable_sha256": "different"}})
        )
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("installed binary changed", result.stderr)
        self.assertFalse(self.base.exists())


if __name__ == "__main__":
    unittest.main()
