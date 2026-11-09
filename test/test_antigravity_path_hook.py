"""Exercise the shipped hook command against real files, aliases and bad input."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

COMMAND = sys.argv[1:]
sys.argv[1:] = []


class NativeReadHook(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        self.inside = self.workspace / "inside.txt"
        self.inside.write_text("inside")
        self.outside = self.root / "outside.txt"
        self.outside.write_text("outside")
        self.secret = self.workspace / "secret"
        self.secret.mkdir()
        (self.secret / "token").write_text("secret")
        self.brain = self.root / "brain"
        self.output = self.brain / "current/.system_generated/steps/2/output.txt"
        self.output.parent.mkdir(parents=True)
        self.output.write_text("large tool result")
        self.command = COMMAND + ["--cwd", str(self.workspace), "--brain", str(self.brain),
            "--read-root", str(self.workspace), "--deny-root", str(self.secret)]

    def invoke(self, payload, command=None):
        result = subprocess.run(command or self.command, input=payload, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout)["decision"]

    def read(self, path, conversation="current"):
        return self.invoke(json.dumps({"toolCall": {"name": "read_file", "args": {"Path": str(path)}},
                                       "conversationId": conversation}))

    def test_workspace_and_relative_reads_delegate(self):
        self.assertEqual(self.read(self.inside), "allow")
        self.assertEqual(self.read("inside.txt"), "allow")

    def test_outside_and_sibling_prefix_are_denied(self):
        sibling = self.root / "workspace-other"
        sibling.mkdir()
        file = sibling / "file"
        file.write_text("outside")
        self.assertEqual(self.read(self.outside), "deny")
        self.assertEqual(self.read(file), "deny")

    def test_symlink_and_parent_escape_are_denied(self):
        alias = self.workspace / "alias"
        alias.symlink_to(self.outside)
        self.assertEqual(self.read(alias), "deny")
        self.assertEqual(self.read("../outside.txt"), "deny")

    def test_secret_deny_wins_even_inside_workspace(self):
        self.assertEqual(self.read(self.secret / "token"), "deny")

    def test_only_current_generated_output_delegates(self):
        self.assertEqual(self.read(self.output), "allow")
        self.assertEqual(self.read(self.output, "other"), "deny")
        unexpected = self.output.parent / "other.txt"
        unexpected.write_text("unrelated")
        self.assertEqual(self.read(unexpected), "deny")

    def test_generated_output_cannot_alias_a_secret(self):
        self.output.unlink()
        self.output.symlink_to(self.secret / "token")
        self.assertEqual(self.read(self.output), "deny")

    def test_malformed_missing_and_duplicate_input_denies_with_exit_zero(self):
        for payload in ["{", "{}", "null", '{"toolCall":{"name":"read_file","args":{}}}',
            '{"toolCall":{"name":"read_file","args":{"Path":false}}}',
            '{"toolCall":{"name":"read_file","args":{"Path":"\\u0000"}}}',
            '{"toolCall":{"name":"read_file","args":{"Path":"a","Path":"b"}}}', "{} {}"]:
            with self.subTest(payload=payload):
                self.assertEqual(self.invoke(payload), "deny")
        self.assertEqual(self.read(self.workspace / "absent"), "deny")

    def test_other_tool_permissions_are_delegated(self):
        self.assertEqual(self.invoke(json.dumps({"toolCall": {"name": "call_mcp_tool", "args": {}}})), "allow")


if __name__ == "__main__":
    if not COMMAND:
        raise SystemExit("supply the compiled hook or an OCaml interpreter command")
    unittest.main()
