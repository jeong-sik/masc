"""Exercise release smoke's README/help contract with a temporary stub binary."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "release-binary-smoke.sh"


class ReleaseBinarySmokeTests(unittest.TestCase):
    def smoke(self, readme, commands):
        with tempfile.TemporaryDirectory(prefix="masc-release-smoke-") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "config").mkdir()
            shutil.copyfile(SCRIPT, root / "scripts" / SCRIPT.name)
            shutil.copyfile(ROOT / "scripts" / "readme-cli-subcommands.py",
                            root / "scripts" / "readme-cli-subcommands.py")
            (root / "config" / "runtime.toml").write_text("# fixture only\n")
            (root / "README.md").write_text(readme)
            binary = root / "stub-masc"
            help_text = "COMMANDS\n" + "".join(f"       {name}\n" for name in commands)
            binary.write_text(
                "#!/usr/bin/env python3\n"
                "import sys\n"
                f"help_text = {help_text!r}\n"
                "print(help_text if '--help=plain' in sys.argv "
                "else 'MASC MCP Server listening (fixture)')\n"
            )
            binary.chmod(0o755)
            return subprocess.run(
                ["bash", str(root / "scripts" / SCRIPT.name), str(binary)],
                env={**os.environ, "BOOT_WAIT_SEC": "2"},
                capture_output=True,
                text=True,
                timeout=10,
            )

    def test_build_and_link_operands_are_not_commands(self):
        result = self.smoke(
            "```bash\n"
            "dune build bin/main_eio.exe bin/masc_tui.exe\n"
            'ln -sf "$PWD/_build/default/bin/main_eio.exe" ~/.local/bin/masc\n'
            "ln -sf masc obsolete-command\n"
            "echo masc obsolete-command\n"
            'echo "&&" masc obsolete-command\n'
            'echo ARG="two; masc obsolete-command"\n'
            "echo escaped\\; masc obsolete-command\n"
            "dune build bin/main_eio.exe \\\n  bin/masc_tui.exe\n"
            "```\n",
            [],
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("release binary contract upheld", result.stdout)

    def test_direct_examples_match_help(self):
        result = self.smoke(
            "Inline `masc start --base-path /tmp/project` and `masc init`.\n"
            "```bash\n"
            "  _build/default/bin/main_eio.exe mcp-config\n"
            '"/opt/masc/bin/masc" token list\n'
            "'/opt/masc/main_eio.exe' login\n"
            "./masc sandbox-image\n"
            "```\n",
            ["start", "init", "mcp-config", "token", "login", "sandbox-image"],
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_real_bin_subcommand_is_rejected(self):
        for executable in ("masc", "./masc", "_build/default/bin/main_eio.exe", '"/opt/bin/masc"'):
            with self.subTest(executable=executable):
                result = self.smoke(f"`{executable} bin`\n", ["start", "init"])
                self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
                self.assertIn("README references 'bin' subcommand", result.stderr)
                self.assertIn("Binary subcommands actually present:", result.stderr)

    def test_command_separators_and_environment_preserve_drift_checks(self):
        for example in (
            "masc bin;",
            "masc bin; masc start",
            "env DEMO=1 masc bin",
            "DEMO=1 masc bin",
            "true && masc bin",
            "false || masc bin",
            "printf data | masc bin",
            "true; env -u DEMO OTHER=1 masc bin",
            'env DEMO="two words" "/opt/masc install/bin/masc" bin',
            'env DEMO="two; words" masc bin',
        ):
            with self.subTest(example=example):
                result = self.smoke(f"```sh\n{example}\n```\n", ["start"])
                self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
                self.assertIn("README references 'bin' subcommand", result.stderr)

    def test_current_readme_build_example_passes(self):
        result = self.smoke(
            (ROOT / "README.md").read_text(),
            ["start", "init", "setup", "mcp-config", "login", "token", "sandbox-image", "keeper-create"],
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
