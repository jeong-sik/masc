"""The continuity harness declares its sandbox through the current Keeper-up API."""

import json
import os
from pathlib import Path
import subprocess
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[1]
HARNESS = ROOT / "scripts/harness/workload/keeper_continuity_validation.sh"
SCHEMA = tomllib.loads((ROOT / "config/tools/masc_keeper_up.toml").read_text())


def shell_function(name: str) -> str:
    source = HARNESS.read_text()
    start = source.index(name + "() {\n")
    end = source.index("\n}\n", start) + 3
    return source[start:end]


def run_function(
    name: str, declaration: dict[str, str]
) -> subprocess.CompletedProcess[str]:
    environment = {
        key: value for key, value in os.environ.items() if not key.startswith("KEEPER_")
    }
    environment.update(
        KEEPER_NAME="continuity-fixture", KEEPER_RUNTIME_NAME="fixture.runtime"
    )
    environment.update(
        KEEPER_SANDBOX_PROFILE="",
        KEEPER_SANDBOX_IMAGE="",
        KEEPER_MICROVM_BACKEND="",
        KEEPER_REMOTE_ENDPOINT="",
    )
    environment.update(declaration)
    script = (
        "set -euo pipefail\n"
        'call_mcp_tool() { printf "%s\\n" "$3"; }\n'
        + (
            shell_function("require_keeper_sandbox")
            if name != "require_keeper_sandbox"
            else ""
        )
        + "\n"
        + shell_function(name)
        + "\n"
        + name
        + "\n"
    )
    return subprocess.run(
        ["bash", "-c", script],
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )


class ContinuityAdmission(unittest.TestCase):
    def test_fresh_keeper_payload_matches_current_tool_and_selected_sandbox(self):
        declaration = {
            "KEEPER_SANDBOX_PROFILE": "microvm",
            "KEEPER_SANDBOX_IMAGE": "chosen-image",
            "KEEPER_MICROVM_BACKEND": "apple_container",
            "KEEPER_REMOTE_ENDPOINT": "",
        }
        result = run_function("create_keeper", declaration)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        allowed = {parameter["name"] for parameter in SCHEMA["params"]}
        self.assertEqual(set(payload) - allowed, set())
        self.assertEqual(payload["sandbox_profile"], "microvm")
        self.assertEqual(payload["sandbox_image"], "chosen-image")
        self.assertEqual(payload["microvm_backend"], "apple_container")
        self.assertNotIn("remote_endpoint", payload)
        self.assertIn(
            "Validate real keeper continuity under isolated load.",
            payload["instructions"],
        )

    def test_missing_declaration_stops_before_real_run_setup(self):
        result = run_function("real_run", {})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("KEEPER_SANDBOX_PROFILE", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_profile_requirements_do_not_select_a_default(self):
        cases = [
            ({"KEEPER_SANDBOX_PROFILE": "docker"}, "KEEPER_SANDBOX_IMAGE"),
            (
                {"KEEPER_SANDBOX_PROFILE": "microvm", "KEEPER_SANDBOX_IMAGE": "chosen"},
                "KEEPER_MICROVM_BACKEND",
            ),
            ({"KEEPER_SANDBOX_PROFILE": "remote_ssh"}, "KEEPER_REMOTE_ENDPOINT"),
        ]
        for declaration, missing in cases:
            with self.subTest(declaration=declaration):
                result = run_function("require_keeper_sandbox", declaration)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(missing, result.stderr)

    def test_docker_and_remote_declarations_reach_the_same_create_boundary(self):
        declarations = [
            {"KEEPER_SANDBOX_PROFILE": "docker", "KEEPER_SANDBOX_IMAGE": "chosen"},
            {
                "KEEPER_SANDBOX_PROFILE": "remote_ssh",
                "KEEPER_REMOTE_ENDPOINT": "chosen-host",
            },
        ]
        for declaration in declarations:
            with self.subTest(declaration=declaration):
                preflight = run_function("require_keeper_sandbox", declaration)
                self.assertEqual(preflight.returncode, 0, preflight.stderr)
                result = run_function("create_keeper", declaration)
                self.assertEqual(result.returncode, 0, result.stderr)
                payload = json.loads(result.stdout)
                self.assertEqual(
                    payload["sandbox_profile"], declaration["KEEPER_SANDBOX_PROFILE"]
                )
                self.assertNotIn("microvm_backend", payload)
                if payload["sandbox_profile"] == "remote_ssh":
                    self.assertEqual(payload["remote_endpoint"], "chosen-host")
                    self.assertNotIn("sandbox_image", payload)
                else:
                    self.assertEqual(payload["sandbox_image"], "chosen")
                    self.assertNotIn("remote_endpoint", payload)


if __name__ == "__main__":
    unittest.main()
