"""Exercise an already-built bootstrap CLI with a local, fake SSH transport.

Usage: python3 test/test_exec_ssh_bootstrap.py /path/to/masc-exec-ssh-bootstrap
The actual CLI and its generated remote shell run. No SSH host or sudo is used.
Real transport and Keeper execution are separate integration proof stages.
"""
import getpass
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())


class BootstrapTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="masc-ssh-bootstrap-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.remote = self.root / "remote"
        self.remote.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.events = self.root / "events.jsonl"
        self.config = self.remote / "shim.conf"
        self.workspace = self.remote / "workspace with 'quote"
        self.key = self.root / "key"
        self.key.write_text("test private key")
        Path(str(self.key) + ".pub").write_text("test public key")
        config_dir = self.root / ".masc/config"
        config_dir.mkdir(parents=True)
        (config_dir / "runtime.toml").write_text(
            '[exec.ssh.endpoints.fixture]\n'
            'host = "fixture.invalid"\n'
            f'user = {json.dumps(getpass.getuser())}\n'
            f'remote_root = {json.dumps(str(self.workspace))}\n'
            f'identity_file = {json.dumps(str(self.key))}\n'
            'env_allowlist = ["LANG"]\n'
        )
        self.shim = self.root / "shim"
        self.shim.write_text('#!/bin/sh\nexit "${PROBE_EXIT:-0}"\n')
        self.make_command("ssh-keyscan", "printf '%s\\n' 'fixture ssh-ed25519 test'\n")
        self.make_command("ssh-keygen", "printf '%s\\n' '256 SHA256:fixture fixture'\n")
        self.make_command("ssh-copy-id", "exit 0\n")
        transport = self.root / "transport.py"
        transport.write_text('''import json, os, pathlib, subprocess, sys
root = pathlib.Path(os.environ["FAKE_REMOTE"])
with open(os.environ["FAKE_EVENTS"], "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\\n")
command = sys.argv[-1]
for old, new in [
    ("/etc/masc-exec-shim.conf", str(root / "shim.conf")),
    ("/usr/local/bin/masc-exec-shim", str(root / "masc-exec-shim")),
    ("/usr/local/share/masc", str(root / "share")),
    ("/tmp/masc-exec-shim.", str(root / "upload.")),
]:
    command = command.replace(old, new)
sys.exit(subprocess.run(["/bin/sh", "-c", command]).returncode)
''')
        self.make_command("ssh", "exec " + shlex.quote(sys.executable) + " "
                          + shlex.quote(str(transport)) + ' "$@"\n')
        self.make_command("sudo", 'shift\nif [ "$1" = chown ]; then exit 0; fi\nexec "$@"\n')
        self.env = dict(os.environ,
                        PATH=str(self.bin) + os.pathsep + str(self.remote)
                        + os.pathsep + os.environ.get("PATH", ""),
                        FAKE_REMOTE=str(self.remote), FAKE_EVENTS=str(self.events))
        # Resolve the explicitly supplied base instead of an operator override.
        self.env.pop("MASC_CONFIG_DIR", None)
        self.env.pop("MASC_BASE_PATH", None)

    def make_command(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def run_bootstrap(self, *args):
        return subprocess.run(
            [BINARY, "--base-path", str(self.root), "--endpoint", "fixture",
             "--shim", str(self.shim), *args],
            input="SHA256:fixture\n", text=True, capture_output=True, env=self.env)

    def test_workspace_needs_no_token_and_reinstall_preserves_files(self):
        for _ in range(2):
            result = self.run_bootstrap("--keeper", "keeper-a", "--keeper", "keeper-a")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("keepers=1", result.stdout)
            workspace = self.workspace / "keeper-a"
            self.assertTrue(workspace.is_dir())
            self.assertFalse((workspace / ".config/gh/hosts.yml").exists())
            receipt = workspace / "receipt.txt"
            if receipt.exists():
                self.assertEqual(receipt.read_text(), "retained work")
            receipt.write_text("retained work")

    def test_reinstall_keeps_host_tool_environment(self):
        self.config.write_text(
            "remote_root=/old-root\nenv_allowlist=OLD\n"
            "path=/opt/venv/bin:/usr/bin:/bin\n"
            "env_file=/etc/endpoint.env\nscratch_root=/var/tmp/boxes\n")
        result = self.run_bootstrap("--keeper", "keeper-a")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        config = dict(line.split("=", 1) for line in self.config.read_text().splitlines())
        self.assertEqual(config, {
            "remote_root": str(self.workspace), "env_allowlist": "LANG",
            "path": "/opt/venv/bin:/usr/bin:/bin",
            "env_file": "/etc/endpoint.env", "scratch_root": "/var/tmp/boxes"})
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o644)

    def test_invalid_keeper_does_not_contact_host(self):
        for keeper in ["../outside", ".", ".."]:
            with self.subTest(keeper=keeper):
                result = self.run_bootstrap("--keeper", keeper)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.events.exists())
                self.assertFalse(self.config.exists())

    def test_bad_existing_config_is_not_replaced(self):
        original = "remote_root=/old-root\nunknown=secret-value\n"
        self.config.write_text(original)
        result = self.run_bootstrap("--keeper", "keeper-a")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("secret-value", result.stderr)
        self.assertEqual(self.config.read_text(), original)
        self.assertFalse((self.remote / "masc-exec-shim").exists())

    def test_failed_probe_is_not_success(self):
        self.env["PROBE_EXIT"] = "19"
        result = self.run_bootstrap("--keeper", "keeper-a")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("provisioned.", result.stdout)

    def assert_directory_alias_refused(self, link):
        outside = self.root / "outside"
        outside.mkdir(mode=0o755)
        receipt = outside / "receipt.txt"
        receipt.write_text("untouched outside work")
        before = outside.stat()
        link.symlink_to(outside, target_is_directory=True)
        result = self.run_bootstrap("--keeper", "keeper-a")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("remote_ssh_directory_prepare_failed", result.stderr)
        self.assertNotIn("provisioned.", result.stdout)
        after = outside.stat()
        self.assertEqual(after.st_mode, before.st_mode)
        self.assertEqual(after.st_uid, before.st_uid)
        self.assertEqual(after.st_gid, before.st_gid)
        self.assertEqual(receipt.read_text(), "untouched outside work")
        self.assertEqual(sorted(p.name for p in outside.iterdir()), ["receipt.txt"])

    def test_existing_keeper_symlink_does_not_change_its_target(self):
        self.workspace.mkdir()
        self.assert_directory_alias_refused(self.workspace / "keeper-a")

    def test_endpoint_root_symlink_does_not_change_its_target(self):
        self.assert_directory_alias_refused(self.workspace)

    def test_endpoint_root_symlink_ancestor_does_not_change_its_target(self):
        original = self.workspace
        self.workspace = self.workspace / "nested"
        config = self.root / ".masc/config/runtime.toml"
        config.write_text(config.read_text().replace(str(original), str(self.workspace)))
        self.assert_directory_alias_refused(original)


if __name__ == "__main__":
    unittest.main()
