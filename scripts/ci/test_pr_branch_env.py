"""Run the actual freshness step with valid branch names containing shell syntax."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any, cast

import yaml

ROOT = Path(__file__).resolve().parents[2]


class BranchLiteralTests(unittest.TestCase):
    def test_freshness_step_preserves_branch_literal(self) -> None:
        workflow = cast(
            dict[str, Any],
            yaml.safe_load((ROOT / ".github/workflows/pr-check.yml").read_text()),
        )
        step = next(
            s
            for s in workflow["jobs"]["lint"]["steps"]
            if s.get("name") == "PR run is not stale"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "scripts/check-pr-sync.sh"
            script.parent.mkdir(parents=True)
            script.write_text(
                "python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' \"$@\"\n"
            )
            for branch in ("review-normal", "review-$(true)", "review-`true`"):
                with self.subTest(branch=branch):
                    subprocess.run(
                        ["git", "check-ref-format", "--branch", branch],
                        check=True,
                        capture_output=True,
                    )
                    values = {
                        "github.event.pull_request.head.ref": branch,
                        "github.event.pull_request.head.sha": "a" * 40,
                        "github.event.pull_request.number": "42",
                    }

                    def render(source: str, bindings: dict[str, str]) -> str:
                        for key, value in bindings.items():
                            source = source.replace("${{ " + key + " }}", value)
                        return source

                    env = {
                        **os.environ,
                        **{
                            key: render(value, values)
                            for key, value in step.get("env", {}).items()
                        },
                    }
                    result = subprocess.run(
                        [
                            "bash",
                            "-e",
                            "-o",
                            "pipefail",
                            "-c",
                            render(step["run"], values),
                        ],
                        cwd=root,
                        env=env,
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(
                        json.loads(result.stdout),
                        [
                            "--head-branch",
                            branch,
                            "--expected-head-sha",
                            "a" * 40,
                            "--pr-number",
                            "42",
                        ],
                    )


if __name__ == "__main__":
    unittest.main()
